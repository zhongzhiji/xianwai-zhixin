// ---------------------------------------------------------------------------
// bt_uart_link.v —— 蓝牙串口透传模块 → MIDI 子集解析
//
// 板卡适配（Sipeed Tang Mega 138K Pro Dock，4071f3 底板，GW5AST-LV138FPG676）：
//   sys_clk = 50 MHz（P16 板载晶振） → CLK_PER_BIT = 50e6/115200 = 434
//   推荐模块：JDY-31 / HC-05 / DX-BT05 等 SPP 透明串口模块（3.3 V TTL）
//   推荐引脚：bt_rx ← M26（PMOD0/J22 物理12脚，文档已标注为 3.3 V UART 收）
//             供电取 PMOD 1/2 脚 +3.3V、3/4 脚 GND；模块 TXD 必须 3.3 V
//             （5 V TXD 直连 FPGA 会打坏 IO，必须先确认模块电平或用分压）
//
// 协议：标准 MIDI 1.0 串口子集（31250 之外的任意波特率亦可，此处 115200）
//   0x9n note vel  → Note On  （vel=0 视为 Note Off）
//   0x8n note vel  → Note Off
//   支持 Running Status（省略状态字节，连续数据字节沿用上一状态）
//   其余字节原样从 raw_data/raw_valid 透传，供上层做曲谱下载等自定义用途
//
// 输出均为 clk 域单拍脉冲，可直接驱动 fsr32_engine 的扩展声部 gate。
// ---------------------------------------------------------------------------
module bt_uart_link #(
    parameter integer CLK_PER_BIT = 434,     // 50 MHz / 115200
    parameter integer IDLE_TIMEOUT = 12500000 // 0.25 s @50MHz：链路心跳超时
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bt_rx,                // 空闲高，来自蓝牙模块 TXD

    output reg         note_on,              // 1 拍脉冲
    output reg         note_off,             // 1 拍脉冲
    output reg  [6:0]  midi_note,
    output reg  [6:0]  velocity,

    output reg  [7:0]  raw_data,             // 所有字节透传（含 MIDI 字节）
    output reg         raw_valid,

    output reg         link_alive,           // 1=0.25 s 内收到过字节
    output reg  [15:0] rx_count
);
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_rx(
        .clk(clk), .rst_n(rst_n), .rx(bt_rx),
        .data(rx_data), .valid(rx_valid));

    reg [7:0]  status;        // 最近一次状态字节（Running Status）
    reg [2:0]  dcount;        // 该状态已收到的数据字节数
    reg        status_valid;

    reg [31:0] idle_cnt;
    // Shared UART carries 55 L/W/C score frames. Suppress MIDI running-status
    // parsing for their complete payload, including BPM values >= 128.
    reg score_command;
    reg [2:0] score_remaining;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_on <= 1'b0; note_off <= 1'b0;
            midi_note <= 7'd0; velocity <= 7'd0;
            raw_data <= 8'd0; raw_valid <= 1'b0;
            link_alive <= 1'b0; rx_count <= 16'd0;
            status <= 8'd0; dcount <= 3'd0; status_valid <= 1'b0;
            idle_cnt <= 32'd0;
            score_command <= 0; score_remaining <= 0;
        end else begin
            note_on <= 1'b0; note_off <= 1'b0; raw_valid <= 1'b0;

            // 链路心跳：收到字节置起，静默 IDLE_TIMEOUT 后落下
            if (rx_valid) begin
                rx_count <= rx_count + 16'd1;
                link_alive <= 1'b1;
                idle_cnt <= 32'd0;
            end else if (idle_cnt < IDLE_TIMEOUT)
                idle_cnt <= idle_cnt + 32'd1;
            else begin
                idle_cnt <= idle_cnt;
                link_alive <= 1'b0;
            end

            if (rx_valid) begin
                raw_data  <= rx_data;
                raw_valid <= 1'b1;

                if (score_remaining != 0) begin
                    score_remaining <= score_remaining-1'b1;
                end else if (score_command) begin
                    score_command <= 0;
                    case(rx_data)
                        8'h4c: score_remaining <= 2;
                        8'h57: score_remaining <= 3;
                        default: score_remaining <= 0;
                    endcase
                end else if (rx_data == 8'h55 && dcount == 0) begin
                    score_command <= 1;
                    status_valid <= 0;
                    dcount <= 0;
                end else if (rx_data[7]) begin                      // 状态字节
                    // 只接受 Note Off / Note On，其余状态仅记录不产生音符
                    if (rx_data[7:4] == 4'h9 || rx_data[7:4] == 4'h8) begin
                        status <= rx_data;
                        status_valid <= 1'b1;
                        dcount <= 3'd0;
                    end else begin
                        status_valid <= 1'b0;
                        dcount <= 3'd0;
                    end
                end else if (status_valid) begin           // 数据字节
                    if (dcount == 3'd0) begin
                        midi_note <= rx_data[6:0];
                        dcount <= 3'd1;
                    end else if (dcount == 3'd1) begin
                        velocity <= rx_data[6:0];
                        dcount <= 3'd0;
                        if (status[7:4] == 4'h8 || rx_data[6:0] == 7'd0)
                            note_off <= 1'b1;              // Note Off / vel=0
                        else
                            note_on  <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
