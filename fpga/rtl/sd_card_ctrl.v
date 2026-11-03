// ---------------------------------------------------------------------------
// sd_card_ctrl.v —— SD 卡（SPI 模式）初始化 + 单块读取
//
//  支持：SDHC / SDXC（按块地址寻址，CMD17 的参数是 LBA 不是字节地址）。
//  流程：
//    1) CS 无效 + MOSI=1，发 >= 74 个空时钟（这里发 80 个 = 10 字节）让卡进入 SPI 模式
//    2) CMD0  (CRC 0x95) → R1 = 0x01
//    3) CMD8  (CRC 0x87, arg 0x1AA) → R1 = 0x01 + 4 字节回显（判 2.0 卡）
//    4) 循环 CMD55 + ACMD41(arg 0x40000000=HCS) → R1 = 0x00 表示就绪
//    5) CMD58 读 OCR，bit30 = CCS：1=SDHC/SDXC（块地址）0=SDSC（字节地址）
//    6) CMD16 把块长度设为 512（SDHC 下是 no-op，无害）
//    7) 就绪，等 rd_req
//  读块：CMD17(LBA) → R1=0 → 等 0xFE 令牌 → 512 字节 → 2 字节 CRC
//
//  缓冲区：512×8，用块 RAM 实现，写完可被上层按地址随机读。
// ---------------------------------------------------------------------------
module sd_card_ctrl #(
    parameter integer SPI_DIV_INIT = 400,
    parameter integer SPI_DIV_FAST = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 块读取请求 ----
    input  wire        rd_req,               // 单拍脉冲
    input  wire [31:0] rd_lba,
    output reg         rd_busy,
    output reg         rd_done,              // 单拍脉冲，缓冲区已更新
    output reg         rd_err,               // 单拍脉冲，读失败

    // ---- 缓冲区随机读口 ----
    input  wire [8:0]  buf_addr,
    output wire [7:0]  buf_data,

    // ---- 状态 ----
    output reg         card_ready,
    output reg         card_hc,              // 1=SDHC/SDXC（块寻址）
    output reg  [3:0]  err_code,             // 1=CMD0 2=CMD8 3=ACMD41超时 4=CMD17 5=令牌超时

    // ---- SPI 引脚 ----
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_csn
);

    // ------------------------------------------------------------------
    // SPI 字节主机
    // ------------------------------------------------------------------
    reg [7:0]  spi_tx;
    reg        spi_start, spi_fast, spi_cs_off, spi_cs_hold;
    wire [7:0] spi_rx;
    wire       spi_busy, spi_done;

    spi_master #(.SPI_DIV_INIT(SPI_DIV_INIT), .SPI_DIV_FAST(SPI_DIV_FAST)) u_spi(
        .clk(clk), .rst_n(rst_n),
        .tx_byte(spi_tx), .start(spi_start), .fast(spi_fast),
        .csn_override(spi_cs_off), .csn_hold(spi_cs_hold),
        .rx_byte(spi_rx), .busy(spi_busy), .done(spi_done),
        .sclk(sd_sclk), .mosi(sd_mosi), .miso(sd_miso), .csn(sd_csn));

    // ------------------------------------------------------------------
    // 512 字节块缓冲（块 RAM）
    // ------------------------------------------------------------------
    // 同步读出：buf_addr 改后的第 2 拍数据才有效，这样能真实推断成块 RAM
    // 而不是把 512 字节摊到 LUT 上。调用方按 2 拍延迟取值。
    (* syn_ramstyle="block_ram" *) reg [7:0] block [0:511];
    reg [8:0] waddr;
    reg [8:0] waddr_r;     // 写地址必须跟 spi_rx 同拍锁存，见下
    reg       we;
    reg [7:0] buf_q;
    always @(posedge clk) begin
        // 写地址要跟数据同拍：spi_done 那一拍 spi_rx 才是刚收到的字节，
        // 而 waddr 在下一拍就已经自增了。直接用 waddr 会把整块数据
        // 错位一个字节（实测 MBR 的分区起始 LBA 读成 0x100 而不是 1）。
        if (we) block[waddr_r] <= spi_rx;
        buf_q <= block[buf_addr];
    end
    assign buf_data = buf_q;

    // ------------------------------------------------------------------
    // 命令字节打包：6 字节 = 01 cmd[5:0] + arg[31:0] + crc7<<1 | 1
    // ------------------------------------------------------------------
    reg [5:0]  cmd_idx;
    reg [31:0] cmd_arg;
    reg [7:0]  cmd_crc;
    reg [2:0]  cmd_byte_i;

    function [7:0] cmd_byte;
        input [5:0] idx; input [31:0] arg; input [7:0] crc; input [2:0] n;
        begin
            case (n)
                3'd0: cmd_byte = {2'b01, idx};
                3'd1: cmd_byte = arg[31:24];
                3'd2: cmd_byte = arg[23:16];
                3'd3: cmd_byte = arg[15:8];
                3'd4: cmd_byte = arg[7:0];
                default: cmd_byte = crc;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------------
    localparam S_BOOT=0, S_DUMMY=1, S_CMD0=2, S_CMD0_R=3,
               S_CMD8=4, S_CMD8_R=5, S_CMD8_ECHO=6,
               S_CMD55=7, S_CMD55_R=8, S_ACMD41=9, S_ACMD41_R=10, S_ACMD41_GAP=11,
               S_CMD58=12, S_CMD58_R=13, S_CMD58_OCR=14,
               S_CMD16=15, S_CMD16_R=16,
               S_READY=17,
               S_RD_CMD=18, S_RD_R1=19, S_RD_TOKEN=20, S_RD_DATA=21, S_RD_CRC=22,
               S_ERR=23;
    reg [4:0] state;

    reg [9:0]  delay;          // 通用延时/计数
    reg [15:0] retry;          // ACMD41 重试计数
    reg [7:0]  r1;
    reg [31:0] lba_hold;
    reg        pending;        // 有读请求待处理
    reg        r1_poll;        // 1=当前字节是"等响应"的空字节（见下）

    localparam [9:0] DUMMY_BYTES = 10;         // 80 个空时钟
    localparam [15:0] ACMD41_MAX = 16'd2000;   // 约 0.5s 量级（125kHz 时更长）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_BOOT; delay <= 0; retry <= 0; r1 <= 8'hFF;
            waddr <= 0; waddr_r <= 0; we <= 0; cmd_idx <= 0; cmd_arg <= 0; cmd_crc <= 8'hFF;
            cmd_byte_i <= 0; spi_tx <= 8'hFF; spi_start <= 0; spi_fast <= 0;
            spi_cs_off <= 1; spi_cs_hold <= 0; card_ready <= 0; card_hc <= 0; err_code <= 0;
            rd_busy <= 0; rd_done <= 0; rd_err <= 0; lba_hold <= 0; pending <= 0;
            r1_poll <= 0;
        end else begin
            spi_start <= 1'b0;
            we        <= 1'b0;
            rd_done   <= 1'b0;
            rd_err    <= 1'b0;

            if (rd_req) pending <= 1'b1;

            case (state)
                // ---------------- 上电延时 ----------------
                S_BOOT: begin
                    spi_cs_off <= 1'b1; spi_fast <= 1'b0;
                    if (delay != 10'd1000) delay <= delay + 1'b1;
                    else begin delay <= 0; state <= S_DUMMY; end
                end

                // CS 无效期间发空字节 = 给卡 80 个时钟进入 SPI 模式
                S_DUMMY: begin
                    // 发 DUMMY_BYTES 个 0xFF（每字节 8 个时钟），且必须等最后一个
                    // 字节真正传完才能拉低 CS，否则卡还在半字节状态里。
                    if (delay != DUMMY_BYTES) begin
                        if (!spi_busy && !spi_start) begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                        end
                        if (spi_done) delay <= delay + 1'b1;
                    end else begin
                        delay <= 0; state <= S_CMD0;
                    end
                end

                // ---------------- CMD0 ----------------
                S_CMD0: begin
                    r1_poll <= 1'b0;
                    spi_cs_off  <= 1'b0;
                    spi_cs_hold <= 1'b1;      // 从这里起 CS 一直保持有效
                    cmd_idx <= 6'd0; cmd_arg <= 32'd0; cmd_crc <= 8'h95;
                    cmd_byte_i <= 3'd0; delay <= 0; state <= S_CMD0_R;
                end
                S_CMD0_R: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            // 等待 R1：发 0xFF 直到 MISO != 0xFF
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll) begin
                                if (spi_rx != 8'hFF) begin
                                    r1 <= spi_rx; delay <= 0;
                                    if (spi_rx == 8'h01) begin state <= S_CMD8; end
                                    else begin err_code <= 4'd1; state <= S_ERR; end
                                end else if (delay == 10'd100) begin
                                    err_code <= 4'd1; state <= S_ERR;
                                end else delay <= delay + 1'b1;
                            end
                        end
                    end
                end

                // ---------------- CMD8 ----------------
                S_CMD8: begin
                    r1_poll <= 1'b0;
                    cmd_idx <= 6'd8; cmd_arg <= 32'h000001AA; cmd_crc <= 8'h87;
                    cmd_byte_i <= 3'd0; delay <= 0; state <= S_CMD8_R;
                end
                S_CMD8_R: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll) begin
                                if (spi_rx != 8'hFF) begin
                                    r1 <= spi_rx; delay <= 0;
                                    if (spi_rx == 8'h01 || spi_rx == 8'h05) begin
                                        delay <= 0; state <= S_CMD8_ECHO;
                                    end else begin
                                        err_code <= 4'd2; state <= S_ERR;
                                    end
                                end else if (delay == 10'd100) begin
                                    err_code <= 4'd2; state <= S_ERR;
                                end else delay <= delay + 1'b1;
                            end
                        end
                    end
                end
                // 吞掉 CMD8 的 4 字节回显
                S_CMD8_ECHO: begin
                    if (!spi_busy && !spi_start) begin
                        spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                        if (spi_done) begin
                            if (delay == 2'd3) begin delay <= 0; retry <= 0; state <= S_CMD55; end
                            else delay <= delay + 1'b1;
                        end
                    end
                end

                // ---------------- CMD55 + ACMD41 ----------------
                S_CMD55: begin
                    r1_poll <= 1'b0;
                    cmd_idx <= 6'd55; cmd_arg <= 32'd0; cmd_crc <= 8'hFF;
                    cmd_byte_i <= 3'd0; delay <= 0; state <= S_CMD55_R;
                end
                S_CMD55_R: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll && spi_rx != 8'hFF) begin
                                r1 <= spi_rx; delay <= 0; state <= S_ACMD41;
                            end
                        end
                    end
                end
                S_ACMD41: begin
                    r1_poll <= 1'b0;
                    cmd_idx <= 6'd41; cmd_arg <= 32'h40000000; cmd_crc <= 8'hFF;
                    cmd_byte_i <= 3'd0; delay <= 0; state <= S_ACMD41_R;
                end
                S_ACMD41_R: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll) begin
                                // 卡在 R1 之前会先回 1..8 个 NCR 空字节(0xFF)，
                                // 必须继续发空时钟把它走完，不能一见 0xFF 就当失败。
                                if (spi_rx == 8'h00) begin
                                    delay <= 0; state <= S_CMD58;
                                end else if (spi_rx != 8'hFF || delay == 10'd100) begin
                                    // 真的回了"忙"(R1=0x01) 或轮询超时 → 重试一轮
                                    if (retry == ACMD41_MAX) begin
                                        err_code <= 4'd3; state <= S_ERR;
                                    end else begin
                                        retry <= retry + 1'b1;
                                        delay  <= 0;
                                        state  <= S_ACMD41_GAP;
                                    end
                                end else delay <= delay + 1'b1;
                            end
                        end
                    end
                end
                S_ACMD41_GAP: begin
                    // 两次 ACMD41 之间给卡一点时间（发几个空字节）
                    if (!spi_busy && !spi_start) begin
                        spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                        if (spi_done) begin
                            if (delay == 10'd8) begin delay <= 0; state <= S_CMD55; end
                            else delay <= delay + 1'b1;
                        end
                    end
                end

                // ---------------- CMD58 读 OCR ----------------
                S_CMD58: begin
                    r1_poll <= 1'b0;
                    cmd_idx <= 6'd58; cmd_arg <= 32'd0; cmd_crc <= 8'hFF;
                    cmd_byte_i <= 3'd0; delay <= 0; state <= S_CMD58_R;
                end
                S_CMD58_R: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll && spi_rx != 8'hFF) begin
                                r1 <= spi_rx; delay <= 0; state <= S_CMD58_OCR;
                            end
                        end
                    end
                end
                S_CMD58_OCR: begin
                    if (!spi_busy && !spi_start) begin
                        spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                        if (spi_done) begin
                            // 第 1 个字节的 bit6（0x40）就是 OCR 的 CCS 位
                            if (delay == 10'd0) card_hc <= spi_rx[6];
                            if (delay == 10'd3) begin
                                delay <= 0; spi_fast <= 1'b1; state <= S_CMD16;
                            end else delay <= delay + 1'b1;
                        end
                    end
                end

                // ---------------- CMD16 设块长 512 ----------------
                S_CMD16: begin
                    r1_poll <= 1'b0;
                    cmd_idx <= 6'd16; cmd_arg <= 32'd512; cmd_crc <= 8'hFF;
                    cmd_byte_i <= 3'd0; delay <= 0; state <= S_CMD16_R;
                end
                S_CMD16_R: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll && spi_rx != 8'hFF) begin
                                r1 <= spi_rx; delay <= 0;
                                card_ready <= 1'b1; state <= S_READY;
                            end
                        end
                    end
                end

                // ---------------- 就绪，等读请求 ----------------
                S_READY: begin
                    if (pending && !spi_busy && !spi_start) begin
                        pending     <= 1'b0;
                        lba_hold    <= rd_lba;
                        rd_busy     <= 1'b1;
                        cmd_idx     <= 6'd17;
                        // SDHC 用块号，SDSC 用字节地址
                        cmd_arg     <= card_hc ? rd_lba : (rd_lba << 9);
                        cmd_crc     <= 8'hFF;
                        cmd_byte_i  <= 3'd0;
                        delay       <= 0;
                        r1_poll     <= 1'b0;
                        state       <= S_RD_CMD;
                    end
                end

                // ---------------- CMD17 读单块 ----------------
                S_RD_CMD: begin
                    if (!spi_busy && !spi_start) begin
                        if (cmd_byte_i != 3'd6) begin
                            spi_tx <= cmd_byte(cmd_idx, cmd_arg, cmd_crc, cmd_byte_i);
                            spi_start <= 1'b1;
                            cmd_byte_i <= cmd_byte_i + 1'b1;
                        end else begin
                            spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                            if (spi_done && r1_poll) begin
                                if (spi_rx == 8'h00) begin
                                    delay <= 0; state <= S_RD_TOKEN;
                                end else if (spi_rx != 8'hFF) begin
                                    err_code <= 4'd4; rd_busy <= 1'b0; rd_err <= 1'b1;
                                    state <= S_READY;
                                end else if (delay == 10'd200) begin
                                    err_code <= 4'd4; rd_busy <= 1'b0; rd_err <= 1'b1;
                                    state <= S_READY;
                                end else delay <= delay + 1'b1;
                            end
                        end
                    end
                end
                S_RD_TOKEN: begin
                    if (!spi_busy && !spi_start) begin
                        spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                        if (spi_done && r1_poll) begin
                            if (spi_rx == 8'hFE) begin
                                waddr <= 9'd0; state <= S_RD_DATA;
                            end else if (delay == 10'd1000) begin
                                err_code <= 4'd5; rd_busy <= 1'b0; rd_err <= 1'b1;
                                state <= S_READY;
                            end else delay <= delay + 1'b1;
                        end
                    end
                end
                S_RD_DATA: begin
                    if (!spi_busy && !spi_start) begin
                        spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                    end
                    if (spi_done) begin
                        waddr_r <= waddr;            // 与 spi_rx 同拍锁存
                        we      <= 1'b1;
                        if (waddr == 9'd511) begin
                            state <= S_RD_CRC; delay <= 0;
                        end else begin
                            waddr <= waddr + 1'b1;
                        end
                    end
                end
                S_RD_CRC: begin
                    if (!spi_busy && !spi_start) begin
                        spi_tx <= 8'hFF; spi_start <= 1'b1; r1_poll <= 1'b1;
                        if (spi_done) begin
                            if (delay == 10'd1) begin
                                rd_busy <= 1'b0; rd_done <= 1'b1; state <= S_READY;
                            end else delay <= delay + 1'b1;
                        end
                    end
                end

                // ---------------- 致命错误：停在这里等复位 ----------------
                S_ERR: begin
                    card_ready <= 1'b0;
                end

                default: state <= S_BOOT;
            endcase
        end
    end

endmodule
