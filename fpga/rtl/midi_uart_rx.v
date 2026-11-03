// ---------------------------------------------------------------------------
// midi_uart_rx.v —— MIDI 1.0（5 针 DIN，31250 bps，8N1）接收与解析
//
//  硬件前提：MIDI 电流环必须经 6N138 光耦转成 3.3V 电平（见
//  docs/03_钢琴键盘与蓝牙模块方案与采购清单.md 第 2.2 节）。
//  6N138 第 7 脚（BASE）必须 1kΩ 下拉到 GND，否则达林顿关断慢会丢码。
//
//  空闲态：MIDI 无电流 → 光耦截止 → 上拉为高。故 UART idle = 1，与标准一致。
//
//  特性：
//   - 8 倍过采样，抗时钟偏差与光耦边沿缓慢
//   - 支持 Running Status（连续同状态报文省略状态字节，MIDI 键盘几乎都用）
//   - Note On velocity==0 视作 Note Off（MIDI 规范）
//   - CC64 延音踏板、CC1 调制轮、弯音轮 14-bit
//   - System Real-time（0xF8/0xFA/0xFB/0xFC/0xFE）单字节，不破坏 Running Status
//   - SysEx（0xF0 ... 0xF7）整段丢弃
//
//  事件输出都是**单拍脉冲**，便于直接接到复音引擎的 note_on/note_off。
// ---------------------------------------------------------------------------
module midi_uart_rx #(
    parameter CLK_HZ = 50000000,
    parameter BAUD   = 31250,
    parameter OVER   = 8                       // 过采样倍数
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       midi_rx,                 // 来自光耦输出，空闲为高

    // ---- 音符事件（单拍脉冲）----
    output reg        note_on,
    output reg  [6:0] note_on_num,
    output reg  [6:0] note_on_vel,             // 1..127
    output reg        note_off,
    output reg  [6:0] note_off_num,

    // ---- 电平型控制 ----
    output reg        sustain,                 // 1 = 延音踏板踩下 (CC64 >= 64)
    output reg  [6:0] mod_wheel,               // CC1
    output reg  [6:0] channel_volume,          // CC7
    output reg signed [13:0] pitch_bend,       // -8192 .. +8191

    // ---- 状态/诊断 ----
    output reg  [7:0] msg_count,               // 已解析出的报文数
    output reg  [7:0] err_count,               // 帧错误（停止位不为 1）
    output reg        activity                 // 收到任何字节时翻转，可接 LED
);

    // ========================================================================
    //  1. 输入同步（异步信号 → 两级同步器）
    // ========================================================================
    reg rx_s0, rx_s1, rx_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; rx_s2 <= 1'b1; end
        else begin rx_s0 <= midi_rx; rx_s1 <= rx_s0; rx_s2 <= rx_s1; end
    end
    wire rx_i = rx_s2;

    // ========================================================================
    //  2. 波特率发生器（OVER 倍）
    // ========================================================================
    localparam integer ACC_W             = 16;
    localparam [ACC_W-1:0] TICKS_PER_BIT = CLK_HZ / (BAUD * OVER);

    reg [ACC_W-1:0] acc;
    wire            tick = (acc >= TICKS_PER_BIT - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc <= 16'd0;
        else if (tick) acc <= 16'd0;
        else           acc <= acc + 16'd1;
    end

    // ========================================================================
    //  3. UART 接收状态机
    // ========================================================================
    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg [1:0] uart_st;
    reg [2:0] tick_cnt;
    reg [2:0] bit_idx;
    reg [7:0] shifter;
    reg       byte_valid;
    reg [7:0] byte_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_st <= S_IDLE; tick_cnt <= 3'd0; bit_idx <= 3'd0;
            shifter <= 8'd0; byte_valid <= 1'b0; byte_data <= 8'd0;
            err_count <= 8'd0; activity <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            if (tick) begin
                case (uart_st)
                    S_IDLE: begin
                        if (!rx_i) begin                 // 起始位（低）
                            uart_st  <= S_START;
                            tick_cnt <= 3'd0;
                        end
                    end
                    S_START: begin
                        if (tick_cnt == OVER/2 - 1) begin
                            // 中点采样起始位，确认仍为低（抑制毛刺）
                            if (!rx_i) begin
                                uart_st  <= S_DATA;
                                tick_cnt <= 3'd0;
                                bit_idx  <= 3'd0;
                            end else begin
                                uart_st <= S_IDLE;       // 毛刺，丢弃
                            end
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end
                    S_DATA: begin
                        if (tick_cnt == OVER - 1) begin
                            shifter  <= {rx_i, shifter[7:1]};   // LSB first
                            tick_cnt <= 3'd0;
                            if (bit_idx == 3'd7) begin
                                uart_st <= S_STOP;
                            end else bit_idx <= bit_idx + 1'b1;
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end
                    S_STOP: begin
                        if (tick_cnt == OVER - 1) begin
                            byte_data  <= shifter;
                            byte_valid <= 1'b1;
                            activity   <= ~activity;
                            if (!rx_i && err_count != 8'hFF) err_count <= err_count + 1'b1;
                            uart_st  <= S_IDLE;
                            tick_cnt <= 3'd0;
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end
                    default: uart_st <= S_IDLE;
                endcase
            end
        end
    end

    // ========================================================================
    //  4. MIDI 报文解析
    // ========================================================================
    localparam ST_NONE = 8'h00;

    reg [7:0] status;
    reg [7:0] d1;
    reg [1:0] need;              // 当前状态还需要的数据字节数
    reg       in_sysex;

    // 状态字节 → 数据字节数
    function [1:0] ndata;
        input [7:0] b;
        begin
            case (b[7:4])
                4'hC, 4'hD: ndata = 2'd1;      // Program Change / Channel Pressure
                4'h8, 4'h9, 4'hA, 4'hB, 4'hE: ndata = 2'd2;
                default:    ndata = 2'd0;
            endcase
        end
    endfunction

    wire is_realtime = (byte_data >= 8'hF8);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status <= ST_NONE; d1 <= 8'd0; need <= 2'd0; in_sysex <= 1'b0;
            note_on <= 1'b0; note_off <= 1'b0;
            note_on_num <= 7'd0; note_on_vel <= 7'd0; note_off_num <= 7'd0;
            sustain <= 1'b0; mod_wheel <= 7'd0; channel_volume <= 7'd100;
            pitch_bend <= 14'sd0; msg_count <= 8'd0;
        end else begin
            note_on  <= 1'b0;
            note_off <= 1'b0;

            if (byte_valid) begin
                if (is_realtime) begin
                    // System Real-time：单字节，不改变 Running Status，直接忽略
                    ;
                end else if (byte_data[7]) begin
                    // ---- 状态字节 ----
                    in_sysex <= 1'b0;
                    if (byte_data == 8'hF7) begin
                        // SysEx 结束
                        need <= 2'd0;
                    end else if (byte_data == 8'hF0) begin
                        in_sysex <= 1'b1; status <= byte_data; need <= 2'd0;
                    end else if (byte_data >= 8'hF1) begin
                        // 系统公共（0xF1 时间码 1 字节 / 0xF2 2 字节 / 0xF3 1 字节）
                        status <= byte_data;
                        need   <= (byte_data == 8'hF2) ? 2'd2 : 2'd1;
                    end else begin
                        status <= byte_data;
                        need   <= ndata(byte_data);
                    end
                end else begin
                    // ---- 数据字节 ----
                    if (in_sysex) begin
                        ;                                   // SysEx 负载，丢弃
                    end else if (need == 2'd2) begin
                        d1   <= byte_data;
                        need <= 2'd1;
                    end else if (need == 2'd1) begin
                        // 报文完整，执行
                        need <= ndata(status);              // Running Status：等待下一组
                        if (msg_count != 8'hFF) msg_count <= msg_count + 1'b1;
                        case (status[7:4])
                            4'h9: begin                      // Note On
                                if (byte_data == 8'd0) begin // vel==0 视作 Note Off
                                    note_off     <= 1'b1;
                                    note_off_num <= d1[6:0];
                                end else begin
                                    note_on      <= 1'b1;
                                    note_on_num  <= d1[6:0];
                                    note_on_vel  <= byte_data[6:0];
                                end
                            end
                            4'h8: begin                      // Note Off
                                note_off     <= 1'b1;
                                note_off_num <= d1[6:0];
                            end
                            4'hB: begin                      // Control Change
                                case (d1)
                                    8'd1:  mod_wheel      <= byte_data[6:0];
                                    8'd7:  channel_volume <= byte_data[6:0];
                                    8'd64: sustain        <= (byte_data >= 8'd64);
                                    default: ;
                                endcase
                            end
                            4'hE: begin                      // Pitch Bend
                                pitch_bend <= $signed({1'b0, byte_data[6:0], d1[6:0]}) - 14'sd8192;
                            end
                            default: ;
                        endcase
                    end else begin
                        ;                                   // 无状态，孤立数据字节，丢弃
                    end
                end
            end
        end
    end

endmodule
