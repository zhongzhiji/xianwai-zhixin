`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// sd_card_model.v —— microSD 卡 SPI 模式行为模型（仅仿真用，禁止综合）
//
//  Mode 0：sclk 空闲为低；从机在上升沿锁存 MOSI，并在**下降沿**更新 MISO，
//  这样主机在上升沿采样到的是稳定值。
//
//  支持的命令：CMD0 / CMD8 / CMD55 / ACMD41 / CMD58 / CMD16 / CMD17
//  卡内容由 TB 用 write_mem 任务按字节预填（TB 自己拼 FAT32 映像）。
//  响应走一个字节队列：命令收完后把 R1/R7/数据块压进队列，
//  之后主机每发一个 0xFF 就弹出一个字节。
// ---------------------------------------------------------------------------
module sd_card_model #(
    parameter integer NBLK = 64                 // 仿真容量（块）
)(
    input  wire       sclk,
    input  wire       mosi,
    output reg        miso,
    input  wire       csn
);

    localparam integer MSZ = NBLK * 512;

    reg [7:0] mem [0:MSZ-1];

    integer i;
    initial begin
        for (i = 0; i < MSZ; i = i + 1) mem[i] = 8'h00;
        miso = 1'b1;
    end

    // ---------------- TB 预填接口 ----------------
    task write_mem;
        input [31:0] addr;
        input [7:0]  data;
        begin
            if (addr[31] == 1'b0 && addr < MSZ) mem[addr] = data;
        end
    endtask

    // ---------------- 响应队列（环形）----------------
    // 注意：rhead/rtail 是**单调递增**的计数器，不是数组下标。
    // 早期版本直接拿 rtail 当下标且满了就丢字节，于是读到第 4~5 个块时
    // 队列溢出、CMD17 得不到 R1，主机侧报 ILLEGAL_COMMAND（err=4）。
    // 单块读最多在飞 1+2+1+512+2=518 字节，2048 深度配 & 2047 取模足够。
    reg [7:0] rbuf [0:2047];
    integer   rhead, rtail;

    task push;
        input [7:0] d;
        begin
            rbuf[rtail & 2047] = d;
            rtail             = rtail + 1;
        end
    endtask

    reg [7:0]  txshift, rxshift;
    reg [2:0]  bitcnt;
    reg [2:0]  byteidx;
    reg [5:0]  cur_cmd;
    reg [31:0] cur_arg;
    reg        in_cmd;

    initial begin
        txshift = 8'hFF; rxshift = 8'hFF;
        bitcnt  = 3'd0;  byteidx = 3'd0;
        cur_cmd = 6'd0;  cur_arg = 32'd0;
        in_cmd  = 1'b0;
        rhead   = 0;     rtail   = 0;
    end

    // ---------------- 命令执行 ----------------
    task exec_cmd;
        input [5:0]  c;
        input [31:0] arg;
        integer k, base;
        begin
            case (c)
                6'd0: begin                       // CMD0  GO_IDLE_STATE
                    push(8'h01);
                end
                6'd8: begin                       // CMD8  SEND_IF_COND → R7
                    push(8'h01);
                    push(arg[31:24]); push(arg[23:16]);
                    push(arg[15:8]);  push(arg[7:0]);
                end
                6'd55: begin                      // CMD55 APP_CMD
                    push(8'h01);
                end
                6'd41: begin                      // ACMD41 SD_SEND_OP_COND → 就绪
                    push(8'h00);
                end
                6'd58: begin                      // CMD58 READ_OCR → CCS=1(SDHC)
                    push(8'h00);
                    push(8'hC0); push(8'hFF); push(8'h80); push(8'h00);
                end
                6'd16: begin                      // CMD16 SET_BLOCKLEN
                    push(8'h00);
                end
                6'd17: begin                      // CMD17 READ_SINGLE_BLOCK
                    push(8'h00);                  // R1
                    push(8'hFF); push(8'hFF);     // NCR（主机轮询时吞掉）
                    push(8'hFE);                  // 数据令牌
                    base = arg * 512;
                    for (k = 0; k < 512; k = k + 1)
                        push((base + k < MSZ) ? mem[base + k] : 8'h00);
                    push(8'h00); push(8'h00);     // CRC16（RTL 不校验）
                end
                default: begin
                    push(8'h04);                  // ILLEGAL_COMMAND
                end
            endcase
        end
    endtask

    // ---------------- 收满一个字节后决定回什么 ----------------
    task do_byte;
        input [7:0] rx;
        begin
            if (rhead < rtail) begin
                txshift <= rbuf[rhead & 2047];   // 环形：见 push 处说明
                rhead   <= rhead + 1;
            end else if (in_cmd) begin
                if (byteidx == 3'd5) begin
                    exec_cmd(cur_cmd, cur_arg);
                    in_cmd  <= 1'b0;
                    byteidx <= 3'd0;
                end else begin
                    case (byteidx)
                        3'd1: cur_arg[31:24] <= rx;
                        3'd2: cur_arg[23:16] <= rx;
                        3'd3: cur_arg[15:8]  <= rx;
                        3'd4: cur_arg[7:0]   <= rx;
                        default: ;
                    endcase
                    byteidx <= byteidx + 3'd1;
                end
                txshift <= 8'hFF;
            end else if (rx[7:6] == 2'b01) begin
                cur_cmd <= rx[5:0];
                in_cmd  <= 1'b1;
                byteidx <= 3'd1;
                txshift <= 8'hFF;
            end else begin
                txshift <= 8'hFF;
            end
        end
    endtask

    // ---------------- CS 无效：复位协议状态 ----------------
    always @(posedge csn) begin
        txshift = 8'hFF; rxshift = 8'hFF;
        bitcnt  = 3'd0;  byteidx = 3'd0;
        in_cmd  = 1'b0;
        rhead   = 0;     rtail   = 0;
        miso    = 1'b1;
    end

    // ---------------- 上升沿：锁存 MOSI，满 8 位处理一字节 ----------------
    always @(posedge sclk) begin
        if (!csn) begin
            rxshift <= {rxshift[6:0], mosi};
            if (bitcnt == 3'd7) begin
                bitcnt <= 3'd0;
                do_byte({rxshift[6:0], mosi});
            end else begin
                bitcnt  <= bitcnt + 3'd1;
                txshift <= {txshift[6:0], 1'b1};
            end
        end
    end

    // ---------------- 下降沿：更新 MISO（主机在上升沿采样） ----------------
    always @(negedge sclk) begin
        if (!csn) miso <= txshift[7];
        else      miso <= 1'b1;
    end

endmodule
