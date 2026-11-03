// ---------------------------------------------------------------------------
// score_loader_core.v —— 曲谱装载协议的**字节流**核心
//
//  原来这段状态机是写在 score_loader_uart.v 里、直接吃 uart_rx 的字节。
//  现在把它抽出来做成独立模块，于是"曲谱字节流"有多条来源：
//    · 蓝牙 / USB-UART   → score_loader_uart.v（uart_rx + 本核心）
//    · SD 卡 FAT32 文件  → sd_score_loader.v （SD 块流 + 本核心）
//  两条通道共用**同一套**协议与**同一份**校验，不会出现"蓝牙能用、SD 卡
//  行为不一致"的情况。
//
// 装载协议（大端、每帧以 0x55 起始）：
//   0x55 0x4C 'L'  <count> <bpm>       装载头：音符数 1..64，速度 40..240
//   0x55 0x57 'W'  <addr> <note> <len> 写一个事件 addr 0..63
//   0x55 0x43 'C'                      提交
//   0x55 0x41 'A'                      放弃
//   note：0=休止，否则必须 MIDI 60..83
//   len ：四分音符为 1 的 4bit 量，len=(ticks+1)/3，不能为 0
//
// 与 score_transport 的握手约束：load_we 与 load_commit 不能同拍。
// 本核心保证两者均为单拍脉冲且互斥。
// ---------------------------------------------------------------------------
module score_loader_core #(
    // 单曲事件容量上限，必须与 score_transport 的 MAX_EVENTS 一致
    parameter integer MAX_EVENTS = 255
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] byte_data,
    input  wire       byte_valid,          // 单拍脉冲，每拍最多一个字节

    output reg        load_we,             // 单拍脉冲
    output reg  [7:0] load_addr,
    output reg  [6:0] load_note,
    output reg  [3:0] load_length,
    output reg        load_commit,         // 单拍脉冲
    output reg  [7:0] load_count,
    output reg  [7:0] load_bpm,

    output reg        frame_done,          // 收到一条完整命令
    output reg        commit_accept,       // 校验通过并已提交
    output reg  [2:0] err_code,            // 1 同步错 2 未知命令 3 参数越界
    output reg  [7:0] err_count,
    output reg  [7:0] recv_count
);

    localparam S_IDLE = 3'd0, S_SYNC = 3'd1, S_CMD = 3'd2, S_ARG = 3'd3,
               S_EXEC = 3'd4;
    reg [2:0] state;
    reg [7:0] cmd;
    reg [2:0] arg_idx;
    reg [2:0] need;
    reg [7:0] a0, a1, a2;
    integer   n_args;

    // Gowin V1.9.12 -verilog_std 最高 v2001，不用 SystemVerilog 的 automatic。
    // 该函数无递归、无静态需求，v2001 语义完全等价。
    function integer need_args;
        input [7:0] c;
        begin
            case (c)
                8'h4C: need_args = 2;        // 'L'
                8'h57: need_args = 3;        // 'W'
                8'h43: need_args = 0;        // 'C'
                8'h41: need_args = 0;        // 'A'
                default: need_args = -1;
            endcase
        end
    endfunction

    wire note_ok = (a1 == 8'd0) || ((a1 >= 8'd60) && (a1 <= 8'd83));
    wire len_ok  = (a2[3:0] != 4'd0);
    // 与 32 位 integer 参数比较，8 位操作数自动零扩展，语义明确、不依赖位选择
    wire cnt_ok  = (a0 >= 8'd1) && (a0 <= MAX_EVENTS);
    wire bpm_ok  = (a1 >= 8'd40) && (a1 <= 8'd240);
    wire addr_ok = (a0 < MAX_EVENTS);
    // 提交时以已锁存的装载头为准，而不是参数暂存区的残留值
    wire cnt_latched_ok = (load_count >= 8'd1) && (load_count <= MAX_EVENTS);
    wire bpm_latched_ok = (load_bpm >= 8'd40) && (load_bpm <= 8'd240);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; cmd <= 8'd0; arg_idx <= 3'd0; need <= 3'd0;
            a0 <= 8'd0; a1 <= 8'd0; a2 <= 8'd0;
            load_we <= 1'b0; load_commit <= 1'b0;
            load_addr <= 8'd0; load_note <= 7'd0; load_length <= 4'd0;
            load_count <= 8'd0; load_bpm <= 8'd120;
            frame_done <= 1'b0; commit_accept <= 1'b0;
            err_code <= 3'd0; err_count <= 8'd0; recv_count <= 8'd0;
        end else begin
            load_we <= 1'b0; load_commit <= 1'b0;
            frame_done <= 1'b0; commit_accept <= 1'b0;

            // S_EXEC 单独一级：参数用非阻塞赋值写入 a0/a1/a2，必须等下一拍
            // 才能读到新值。若在同一拍判断越界，读到的是上一个字节的旧值
            // （这是实测踩过的 bug，不要合并回 S_ARG）。
            if (state == S_EXEC) begin
                state <= S_IDLE; frame_done <= 1'b1;
                case (cmd)
                    8'h4C: begin             // 'L' 装载头
                        if (cnt_ok && bpm_ok) begin
                            load_count <= a0;
                            load_bpm   <= a1;
                        end else begin
                            err_code <= 3'd3;
                            err_count <= err_count + 8'd1;
                        end
                    end
                    8'h57: begin             // 'W' 写事件
                        if (addr_ok && note_ok && len_ok) begin
                            load_we     <= 1'b1;
                            load_addr   <= a0;
                            load_note   <= a1[6:0];
                            load_length <= a2[3:0];
                        end else begin
                            err_code <= 3'd3;
                            err_count <= err_count + 8'd1;
                        end
                    end
                    default: ;
                endcase
            end else if (byte_valid) begin
                recv_count <= recv_count + 8'd1;
                case (state)
                    S_IDLE: begin
                        if (byte_data == 8'h55) state <= S_SYNC;
                        else begin err_code <= 3'd1; err_count <= err_count + 8'd1; end
                    end
                    S_SYNC: begin
                        cmd <= byte_data;
                        n_args = need_args(byte_data);
                        need <= n_args[2:0];
                        if (n_args < 0) begin
                            err_code <= 3'd2; err_count <= err_count + 8'd1;
                            state <= S_IDLE;
                        end else if (n_args == 0) begin
                            state <= S_IDLE; frame_done <= 1'b1;
                            if (byte_data == 8'h43 && cnt_latched_ok && bpm_latched_ok) begin
                                load_commit <= 1'b1;
                                commit_accept <= 1'b1;
                            end else if (byte_data == 8'h43) begin
                                err_code <= 3'd3; err_count <= err_count + 8'd1;
                            end
                        end else begin
                            arg_idx <= 3'd0; state <= S_ARG;
                        end
                    end
                    S_ARG: begin
                        case (arg_idx)
                            3'd0: a0 <= byte_data;
                            3'd1: a1 <= byte_data;
                            default: a2 <= byte_data;
                        endcase
                        if (arg_idx + 3'd1 == need) state <= S_EXEC;
                        else                        arg_idx <= arg_idx + 3'd1;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
