// ============================================================================
//  clk_gen.v  —  用 50MHz 主时钟生成 I2S 位时钟 BCK
// ----------------------------------------------------------------------------
//  为什么要这个模块：PT8211 需要 BCK = Fs * 32。我们想要的 Fs 是精确 48.000kHz
//  →  BCK = 1.536 MHz。但 50MHz / 1.536MHz = 32.5520...，**不是整数**。
//  用整数分频只能得到 50/32 = 1.5625MHz（Fs=48.83kHz）或 50/33 = 1.515MHz
//  （Fs=47.35kHz），两者都有频偏，且会让板子上的音高对不上黄金模型。
//
//  做法：**小数分频累加器**（fractional / Bresenham 累加器）
//     acc 每拍加 ACC_STEP；一旦 acc >= ACC_MOD 就减去 ACC_MOD 并让 BCK 翻转一次。
//     平均翻转率 = ACC_STEP / ACC_MOD * CLK_HZ
//                = 3072 / 50000 * 50e6 = 3.072e6 次/秒
//     → BCK 周期率 = 3.072e6 / 2 = **1.536 MHz 精确**
//     → 32 个 BCK 一拍 → **Fs = 48.000 kHz 精确**（平均意义上精确）
//
//  抖动：单次半周期在 16 与 17 个 clk 之间交替（320ns / 340ns）。
//        BCK 本身有约 ±20ns 的 jitter，PT8211 对此完全不敏感（位周期 651ns，
//        内部是逐位锁存，不看绝对相位）。而**长期平均频率是精确的**，
//        这正是音高与「吞吐量=振荡器数×采样率」这两个指标需要的性质。
//
//  参数化：ACC_MOD / ACC_STEP 由 tb 或顶层按 CLK_HZ、FS_HZ 计算传入，
//          方便将来换主频或换采样率（例如 96kHz → ACC_STEP = 6144）。
//  校验：3072 = 2 * 32 * 48e3 / 1000 = 2 * BCK_HZ / 1000
//        50000 = CLK_HZ / 1000
// ============================================================================
`timescale 1ns / 1ps

module clk_gen #(
    parameter integer ACC_MOD  = 50000,   // = CLK_HZ / 1000                = 50000
    parameter integer ACC_STEP = 3072     // = 2 * FS_HZ * 32 / 1000        = 3072
)(
    input  wire clk,          // 50MHz 主时钟
    input  wire rst_n,        // 异步低有效复位

    output reg  bck,          // 1.536MHz，直接送 HP_BCK
    output reg  bck_rise,     // 一个 clk 周期宽：bck 由 0→1 时拉高
    output reg  bck_fall      // 一个 clk 周期宽：bck 由 1→0 时拉高
);

    reg [15:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc      <= 16'd0;
            bck      <= 1'b0;
            bck_rise <= 1'b0;
            bck_fall <= 1'b0;
        end else begin
            // 脉冲默认拉低，只在这一拍真正翻转时拉高
            bck_rise <= 1'b0;
            bck_fall <= 1'b0;

            if (acc >= ACC_MOD) begin
                // 先减再加：同拍完成「减模+推进」，acc 稳态恒 < ACC_MOD+ACC_STEP
                acc <= acc - ACC_MOD + ACC_STEP;
                bck <= ~bck;
                if (bck) bck_fall <= 1'b1;   // 当前是 1，即将变 0 → 下降沿
                else     bck_rise <= 1'b1;   // 当前是 0，即将变 1 → 上升沿
            end else begin
                acc <= acc + ACC_STEP;
            end
        end
    end

endmodule
