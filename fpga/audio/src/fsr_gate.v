// ============================================================================
//  fsr_gate.v  —  16 点压力值 → 16 个门（v3：24bit 原码域 + 自动基线 + 自适应阈值）
// ----------------------------------------------------------------------------
//  为什么会有 v3：
//    v1（固定阈值 ON_TH=200）上板"一个点都不响"。
//    v2（16bit 域的自动基线 + |偏差|>16）上板仍然不响，且 LED 量级条恒为 0 档。
//    根因是**量纲**：v2 之前对 AA55 只取 24bit 的高 16 位（≈原值 ÷256），
//    而模块输出的是小整数（手册例：78 / 701 / 8）⇒ 高 16 位恒 0，
//    在 16bit 域里怎么看都是"全 0、不变"。
//    ⇒ v3 改成在**完整 24bit 原码域**判决（见 wax_frame.v v3），不做任何归一化。
//
//  v3 判决规则（不依赖量纲，只依赖"变化"）：
//    · 上电后第一帧 = 该点静息基线 base（上电时别压着薄膜）
//    · 触发：|val − base| > thr，thr = max(DELTA_MIN, 噪声估计 × 2^NOISE_GAIN)
//        —— 取绝对值 ⇒ "压下变大"和"压下变小"两种极性都能用
//        —— 噪声估计 = 只在**松开且未越阈**时对 |偏差| 做 EMA
//           ⇒ 静息抖动会自动抬高阈值（不会自己乱响），干净信号则保持高灵敏
//    · 释放：|val − base| < DELTA_OFF（迟滞，防阈值附近抖动出咔咔声）
//    · 松开时慢速跟踪基线（每帧走偏差的 1/2^EMA_SHIFT）⇒ 自动跟温漂
//    · 掉线保护：连续 2^TO_BITS 拍没有新帧 ⇒ 全部松开
//
//  dev_max 输出：16 点里最大的 |偏差|（24bit）。top 用它点 LED 量级条，
//  是"到底有没有信号、信号多大"的唯一现场仪表。
//
//  ★ 变量名不能叫 buf（门级原语关键字）；gate 只在收到新帧时变化。
//  ★ 组合求最大值必须走多周期串行（v2 教训：`function+for` 组合链 47.9ns，
//    50MHz 下 Fmax 只剩 20.9MHz、14 条 endpoint 违例）。
// ============================================================================
`timescale 1ns / 1ps

module fsr_gate #(
    parameter integer N           = 16,
    parameter integer DELTA_MIN   = 32,     // 最小触发偏差（24bit 原码域）
    parameter integer DELTA_OFF   = 16,     // 释放迟滞
    parameter integer EMA_SHIFT   = 6,      // 基线跟踪速度 = 1/2^EMA_SHIFT 每帧
    parameter integer NOISE_SHIFT = 6,      // 噪声估计 EMA 系数 = 1/2^NOISE_SHIFT
    parameter integer NOISE_GAIN  = 3,      // 阈值 = 噪声估计 × 2^NOISE_GAIN（=8×）
    parameter integer TO_BITS     = 25      // 无帧超时 = 2^TO_BITS 拍（2^25/50MHz ≈ 0.67s）
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            new_frame,       // 1 拍脉冲：vals 已是新一帧
    input  wire [24*N-1:0] vals,            // 点 i 在 vals[24*i +: 24]
    output reg  [N-1:0]    gate,
    output reg  [23:0]     dev_max          // 16 点最大 |偏差|（供 LED 量级条）
);

    localparam [23:0] DMIN = DELTA_MIN;
    localparam [23:0] DOFF = DELTA_OFF;

    // ── 首帧标志 + 掉线看门狗 ─────────────────────────────────────────────
    reg               init_done = 1'b0;
    reg [TO_BITS-1:0] to_cnt    = {TO_BITS{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_done <= 1'b0;
            to_cnt    <= {TO_BITS{1'b0}};
        end else if (new_frame) begin
            init_done <= 1'b1;
            to_cnt    <= {TO_BITS{1'b0}};
        end else if (to_cnt != {TO_BITS{1'b1}}) begin
            to_cnt    <= to_cnt + 1'b1;
        end
    end

    wire lost = (to_cnt == {TO_BITS{1'b1}});   // 长时间没帧 ⇒ 当作全部松手

    // ── 判决流水线：把「减 → 取绝对值 → 比阈值」拆成两级 ──────────────────
    //   为什么要拆：这三步全组合时，从 vals 到 16 路 gate/base/noise 的 CE 端
    //   是一条 24bit 减法器 + 24bit 取反选择器 + 24bit 比较器的长链，
    //   实测在 50MHz 下数据延迟 20.7~21.0ns（周期只有 20ns），
    //   单独 fsr_gate 就炸出 246 个 setup 违例端点、TNS -141.5ns。
    //   第一级在 new_frame 拍锁 dev / thr / v / dv，第二级用新帧的下一拍 nf_d
    //   做判决。压力膜一帧几十毫秒，晚一拍（20ns）完全无感。
    reg nf_d;                                  // new_frame 延时一拍 = 第二级使能
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) nf_d <= 1'b0;
        else        nf_d <= new_frame;
    end

    // ── 16 路：基线 + 噪声估计 + 偏差判决 ─────────────────────────────────
    wire [24*N-1:0] dev_bus;                   // 各点 |偏差| 拼成总线，供串行求最大值

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : G_CH
            wire [23:0] v_in = vals[24*i +: 24];

            reg  [23:0]        base_q  = 24'd0;
            reg  [23:0]        noise_q = 24'd0;
            wire signed [24:0] dv      = $signed({1'b0, v_in}) - $signed({1'b0, base_q});
            wire        [24:0] dv_abs  = (dv < 0) ? -dv : dv;
            wire        [23:0] dev     = dv_abs[23:0];
            wire signed [24:0] step    = dv >>> EMA_SHIFT;      // 慢跟踪步长

            // 自适应阈值（★ 用局部量算，避免参数位选在不同工具上的差异）
            wire [26:0] thrx    = {3'b000, noise_q} << NOISE_GAIN;
            wire [23:0] thr_raw = (thrx > 27'hFFFFFF) ? 24'hFFFFFF : thrx[23:0];
            wire [23:0] thr     = (thr_raw < DMIN) ? DMIN : thr_raw;

            // ---- 第一级：新帧拍锁存中间量，切断组合长链 ----
            reg        [23:0] v_q;
            reg        [23:0] dev_q;
            reg        [23:0] thr_q;
            reg signed [24:0] dv_q;
            reg               first_q;          // 该帧是不是首帧（首帧用来定基线）
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    v_q <= 24'd0; dev_q <= 24'd0; thr_q <= 24'd0;
                    dv_q <= 25'sd0; first_q <= 1'b0;
                end else if (new_frame) begin
                    v_q     <= v_in;
                    dev_q   <= dev;
                    thr_q   <= thr;
                    dv_q    <= dv;
                    first_q <= !init_done;      // init_done 在本拍末才置 1，故此处读到 0
                end
            end

            // dev_bus 用锁存值：串行求最大值那条路径也不再吃组合减法器
            assign dev_bus[24*i +: 24] = dev_q;

            // ---- 第二级：用 nf_d 拍做判决 ----
            wire [23:0] step24 = (dv_q >>> EMA_SHIFT);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    base_q  <= 24'd0;
                    noise_q <= 24'd0;
                    gate[i] <= 1'b0;
                end else if (lost) begin
                    gate[i] <= 1'b0;                        // 掉线 → 松开
                end else if (nf_d && first_q) begin
                    // 第一帧：把当前值当静息基线
                    base_q <= v_q;
                end else if (nf_d) begin
                    if (!gate[i]) begin
                        if (dev_q > thr_q) begin
                            gate[i] <= 1'b1;                // 起音
                        end else begin
                            base_q  <= base_q + step24;     // 校准态才跟踪基线
                            // 噪声估计：只在"松开且没越阈"时更新
                            noise_q <= noise_q - (noise_q >> NOISE_SHIFT)
                                               + (dev_q   >> NOISE_SHIFT);
                        end
                    end else begin
                        if (dev_q < DOFF) gate[i] <= 1'b0;  // 释音
                    end
                end
            end
        end
    endgenerate

    // ── 16 点最大 |偏差|（LED 量级条）——★ 多周期串行，不能写成组合链 ──────
    reg [4:0]  dx_idx = 5'd0;
    reg [23:0] dx_acc = 24'd0;
    reg        dx_run = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dx_idx  <= 5'd0;
            dx_acc  <= 24'd0;
            dx_run  <= 1'b0;
            dev_max <= 24'd0;
        end else if (new_frame) begin
            dx_idx  <= 5'd0;                            // 新帧 → 重新扫描 16 个点
            dx_acc  <= 24'd0;
            dx_run  <= 1'b1;
        end else if (dx_run) begin
            if (dx_idx == 5'd15) begin
                dev_max <= (dev_bus[24*15 +: 24] > dx_acc) ? dev_bus[24*15 +: 24] : dx_acc;
                dx_run  <= 1'b0;
            end else begin
                dx_acc <= (dev_bus[24*dx_idx +: 24] > dx_acc) ? dev_bus[24*dx_idx +: 24] : dx_acc;
                dx_idx <= dx_idx + 5'd1;
            end
        end
    end

endmodule
