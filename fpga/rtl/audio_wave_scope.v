// ============================================================================
//  audio_wave_scope.v —— 实时波形示波器的「音频侧」采样前端（sys_clk 域）
// ----------------------------------------------------------------------------
//  职责单一：把 48 kHz 的 PCM 流抽稀成示波器能看清的一串 8 bit 有符号样本，
//  顺带算出峰值保持与平滑电平，打包成一个 25 bit 载荷交给 mailbox 跨时钟域。
//
//  为什么抽稀（DECIMATE）：
//    48 kHz 直接画，一个 440 Hz 的音在屏幕上只有 100 个像素宽的周期、
//    一屏 180 列连半个周期都放不下，看过去就是一坨高频乱线。
//    DECIMATE=16 → 3 kHz，一屏 180 列 = 60 ms，440 Hz 能画出 ~11 个周期，
//    既有"波形"的形状，又能看出音头和衰减，是示波器最好看的一档。
//
//  为什么载荷里要塞一个 toggle 位：
//    下游用的是 bus_snapshot_cdc 的 bundled-data 握手，靠
//    "src_data != previous" 判定有新数据。波形是连续流，相邻样本经常相等
//    （尤其是静音或长 sustain），不带 toggle 就会被当成"没变化"直接丢掉，
//    波形上会出现被压缩的平直段——这正是队友那版不好看的原因之一。
//    toggle 每来一个样本翻一次，保证 payload 恒不等于 previous，一个不漏。
//
//  速率安全边界（必须满足，否则会丢样本）：
//    源侧样本率 = 48000/DECIMATE = 3 kHz（周期 333 µs）；
//    mailbox 一次握手 ≈ 2 个 src 周期 + 2 个 dst 周期 ≈ 100 ns。
//    333 µs >> 100 ns，余量 3000 倍以上，不会丢。
// ============================================================================
`timescale 1ns / 1ps

module audio_wave_scope #(
    parameter integer DECIMATE   = 16,    // 48kHz/16 = 3 kHz 示波器采样率
    parameter integer PEAK_HOLD  = 512,   // 峰值保持衰减间隔（≈10.7 ms）
    parameter integer LEVEL_SHIFT = 3     // 电平平滑系数（1/8）
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_en,          // 48 kHz 采样节拍（frame_en）
    input  wire        enable,             // 静音时把波形拉回 0
    input  wire signed [15:0] pcm_in,
    output reg  [7:0]  scope_sample,       // 8 bit 有符号波形样本
    output reg  [7:0]  scope_peak,         // 峰值保持（0..127，128 = 满刻度）
    output reg  [7:0]  scope_level,        // 平滑电平（0..127）
    output reg         scope_valid,        // 1 拍脉冲：样本已更新
    output reg         scope_toggle        // 每样本翻转，强制 mailbox 传输
);

    // 抽稀计数器：宽到能容纳任意 DECIMATE
    reg [7:0] dec_cnt;
    // 峰值保持衰减计时
    reg [9:0] hold_cnt;

    // 参数先落到 localparam 再做位选：直接对 parameter integer 做 [7:0] 位选
    // 在部分综合器上会被判成非常量，这里显式截断一次。
    localparam [7:0]  DEC_MAX   = DECIMATE - 1;
    localparam [9:0]  HOLD_MAX  = PEAK_HOLD;

    // |pcm| 的饱和幅度。pcm = -32768 时取反会溢出 16 bit，必须先扩到 17 bit
    // 再饱和，否则 -32768 会变成 0，波形底部出现假的"回抽"。
    wire signed [16:0] pcm_ext = pcm_in;
    wire [16:0] pcm_mag = pcm_ext[16] ? (-pcm_ext) : pcm_ext;
    wire [15:0] mag_sat = (pcm_mag > 17'd32767) ? 16'd32767 : pcm_mag[15:0];
    // 满刻度折到 0..127（127 = 0 dBFS），与 8 bit 样本用的是同一把尺子：
    // 样本取 pcm[15:8]（= pcm/256），这里也必须 /256 而不是 /512，
    // 否则峰值只有样本幅度的一半，峰值包络线会永远画在波形里面。
    wire [7:0]  mag7   = mag_sat[15:8];

    wire [7:0] pcm_s8  = enable ? pcm_in[15:8] : 8'd0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dec_cnt      <= 8'd0;
            hold_cnt     <= 10'd0;
            scope_sample <= 8'd0;
            scope_peak   <= 8'd0;
            scope_level  <= 8'd0;
            scope_valid  <= 1'b0;
            scope_toggle <= 1'b0;
        end else begin
            scope_valid <= 1'b0;

            // ---- 电平：一阶低通，只做移位加减，不用乘法器 ----
            // level += (mag7 - level) / 8。两个分支都保证被减数为正，
            // 不会在无符号运算里绕回；末尾 ±1 是为了差值 < 8 时仍能收敛。
            if (sample_en) begin
                if (mag7 > scope_level)
                    scope_level <= scope_level + ((mag7 - scope_level) >> LEVEL_SHIFT) + 8'd1;
                else if (scope_level != 8'd0)
                    scope_level <= scope_level - ((scope_level - mag7) >> LEVEL_SHIFT)
                                   - (((scope_level - mag7) >> LEVEL_SHIFT) == 8'd0 ? 8'd1 : 8'd0);
            end

            // ---- 抽稀取样 ----
            if (sample_en) begin
                if (dec_cnt == 8'd0) begin
                    scope_sample <= pcm_s8;
                    scope_valid  <= 1'b1;
                    scope_toggle <= ~scope_toggle;
                end
                dec_cnt <= (dec_cnt >= DEC_MAX) ? 8'd0 : dec_cnt + 8'd1;

                // ---- 峰值保持：立即上升、缓慢回落 ----
                if (mag7 > scope_peak) begin
                    scope_peak <= mag7;
                    hold_cnt   <= 10'd0;
                end else if (hold_cnt == HOLD_MAX) begin
                    hold_cnt <= 10'd0;
                    if (scope_peak != 8'd0) scope_peak <= scope_peak - 8'd1;
                end else
                    hold_cnt <= hold_cnt + 10'd1;
            end

            // 整机静音时把峰值也放掉，避免屏幕上留一条不掉的横线
            if (!enable) begin
                scope_peak  <= 8'd0;
                scope_level <= 8'd0;
                hold_cnt    <= 10'd0;
            end
        end
    end
endmodule
