// ============================================================================
// pitch_bend_apply.v —— MIDI 弯音轮（Pitch Bend）→ 频率字微调
//
// 目的：rtl/midi_uart_rx.v 早就解出了 14 位 pitch_bend，但顶层一直空接，
//       弯音轮推了没反应（README「已知限制」最后一条）。本模块把它接进引擎。
//
// 原理：
//   1. pitch_bend 是 14 位补码（-8192 .. +8191），取高 7 位当索引
//      （每档 128 LSB = 2/64 半音 ≈ 3.1 音分，人耳听不出台阶感）。
//   2. 查 128 项 Q15 倍率表 → ratio（0x8000 = 1.0 倍，表由
//      tools/gen_bend_lut.py 生成，默认 ±2 半音音域）。
//   3. fw_out = (fw_in × ratio) >> 15。
//
// 时序（重要，别改成纯组合）：
//   查表一拍 → 乘法一拍，两级流水。乘法被夹在两个寄存器之间，
//   32×16 乘法不会形成长组合链。本工程曾因「20.79 ns 组合链」炸出
//   上千个 setup 违例，这里的流水是刻意保留的。
//   代价：从 fw_in 到 fw_out 共 2 个 sys_clk 周期（40 ns @50 MHz），
//   对演奏完全无感。
//
// 溢出保护：
//   48 bit 乘积右移 15 位后仍有 33 bit。若高 17 位非零说明 fw 本身就很大
//   （本工程最高音 MIDI84 的 fw ≈ 1.1e8，×1.122 后 ≈ 1.25e8，远不到 2^31），
//   钳到 32'hFFFFFFFF —— 宁可封顶也不要绕回成低频噪音。
//
// 旁路：BEND_EN=0 时 fw_out 直接等于 fw_in 打一拍，不例化乘法器。
// ============================================================================
module pitch_bend_apply #(
    parameter       BEND_EN   = 1,
    parameter       LUT_FILE  = "audio/rom/bend_lut.mem"
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire signed [13:0] bend,     // -8192 .. +8191（来自 midi_uart_rx）
    input  wire [31:0]      fw_in,      // 根音频率字（midi_fw_rom 读出）
    output wire [31:0]      fw_out      // 弯音后的频率字（滞后 2 拍）
);

    // ------------------------------------------------------------------
    // 倍率表：128 × 16 bit，Q15 定点
    // ------------------------------------------------------------------
    reg [15:0] bend_lut [0:127];
    initial $readmemh(LUT_FILE, bend_lut);

    // index = bend[13:7]
    //   0..63   → bend = 0 .. +8191   （零弯 → 最大正弯）
    //   64..127 → bend = -8192 .. -1  （最大负弯 → 零弯）
    wire [6:0] bend_idx = bend[13:7];

    reg [15:0] ratio_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ratio_r <= 16'h8000;         // 复位 = 1.0 倍
        else        ratio_r <= bend_lut[bend_idx];
    end

    wire [47:0] fw_mul  = fw_in * ratio_r;

    // 48 bit 乘积右移 15 位（Q15）后是 33 位，取 [46:15] 作为 32 位结果。
    // 判据只用 bit47：fw_mul[47]=1 → 结果 ≥ 2^32，32 位装不下；
    // fw_mul[47]=0 → 结果 ≤ 2^32-1，安全。
    // （注意别写成 |fw_mul[47:31]：那样正常音高也会被误判成溢出，
    //   实测 MIDI69 的 fw 乘 1.0 后最高位在 bit40，会被 [47:31] 命中）
    wire [31:0] fw_bent = fw_mul[47] ? 32'hFFFFFFFF : fw_mul[46:15];

    reg [31:0] fw_out_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fw_out_r <= 32'd0;
        else        fw_out_r <= BEND_EN ? fw_bent : fw_in;
    end

    assign fw_out = fw_out_r;

endmodule
