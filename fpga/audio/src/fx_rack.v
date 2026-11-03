`timescale 1ns/1ps
// ============================================================================
//  fx_rack.v — 硬件效果器机架：回声 Echo / 合唱 Chorus / 混响 Reverb（拓展E2）
// ----------------------------------------------------------------------------
//  三种效果均为逐样本 HDL 实时运算（赛题"内部效果器"要求），可整体旁路。
//
//  ▶ 结构参考（经典公开算法，思路非私货）：
//    - Reverb：Schroeder 1962「Natural Sounding Artificial Reverberation」
//      的并联梳状滤波器 + 串联全通结构（Freeverb 等开源实现的通用骨架）。
//      梳状延迟取 1426/1781/1973/2098 采样（≈29.7/37.1/41.1/43.7ms @48k，
//      即原论文延迟值按 48k 换算），全通 240/82 采样（≈5/1.7ms）。
//    - Chorus：双抽头调制延迟线（DAFX 教材的标准合唱结构），
//      基础延迟 20ms ± 4ms，LFO 0.8Hz，两抽头反相调制。
//    - Echo：固定延迟反馈延迟线（250ms，反馈 0.45，湿度 0.30）。
//
//  ▶ 资源与位宽（避免溢出的关键决策）：
//    - 回声/梳状/全通缓存用 18bit 字宽（Gowin BSRAM 原生 18Kb/位宽可配，
//      18bit 不额外耗块）：回声稳态幅度 ≤ dry/(1-fb)=1.82×dry，16bit 会绕回。
//    - 混响入口衰减 0.5、梳状反馈 0.72 → 稳态 ≤ 0.5/(1-0.72)=1.79×dry×0.5
//      ≤ 0.9×dry，18bit 缓存内无饱和失真；输出端统一饱和限幅（极端满幅
//      干信号+湿信号才会触发，与整机 clip 口径一致）。
//    - 合唱为前馈抽头（无反馈），16bit 缓存即安全。
//
//  ▶ 时序（确定性，无抖动）：
//    - en[k] = sample_en 延迟 k 拍的选通脉冲。输入在 en[10] 锁存
//      （上游引擎流水线在 frame_en 后 ≤9 拍已稳定）。
//    - 回声/合唱：en[10..13] 四拍完成 读→乘→写→出；
//      混响链：梳状 en[10..13] → 求和 en[14] → 全通0 en[14..17] →
//      全通1 en[18..21] → 输出 en[22]。全部 ≪ 1042 拍/采样。
//    - 旁路模式 pcm_out 直通寄存一拍（20ns），零算法延迟。
//    - 每采样只推进一次指针/状态 → 长期行为与 48kHz 采样节拍严格对齐。
//
//  ▶ 建议接入点：fsr16_audio_wrapper 里 combined_pcm（干混音）之后、
//    audio_master_volume 之前；fx_mode=00 时与原链路仅差 1 拍寄存器。
// ============================================================================
module fx_rack #(
    parameter integer ECHO_DEPTH   = 16384,   // 环形缓冲长度（2^14，0.34s）
    parameter integer ECHO_DELAY   = 12000,   // 250ms @48k
    parameter integer ECHO_FB_Q15  = 14746,   // 反馈 0.45
    parameter integer ECHO_WET_Q15 = 9830,    // 湿度 0.30
    parameter integer CHORUS_BASE  = 960,     // 20ms
    parameter integer CHORUS_SWING = 192,     // ±4ms
    parameter integer CHORUS_BUF   = 2048,    // 2^11
    parameter integer CHORUS_LFO_STEP = 280,  // 0.8Hz @48k
    parameter integer COMB0 = 1426, COMB1 = 1781, COMB2 = 1973, COMB3 = 2098,
    parameter integer AP0   = 240,  AP1   = 82,
    parameter integer COMB_FB_Q15 = 23633,    // 0.72
    parameter integer AP_G_Q15    = 22938,    // 0.70
    parameter integer REV_WET_Q15 = 9830,     // 0.30
    parameter SINE_ROM_FILE = "audio/rom/sine_lfo_256.mem"
)(
    input  wire        clk, reset_n, sample_en, enable,
    input  wire [1:0]  fx_mode,        // 00旁路 01回声 10合唱 11混响
    input  wire signed [15:0] pcm_in,
    output reg  signed [15:0] pcm_out,
    output wire        fx_active
);
    localparam [1:0] FX_BYPASS = 2'd0, FX_ECHO = 2'd1, FX_CHORUS = 2'd2, FX_REVERB = 2'd3;

    assign fx_active = enable && (fx_mode != FX_BYPASS);

    // ---- 选通脉冲流水：en[k] = sample_en 延迟 k 拍 ----
    reg [22:0] en;
    always @(posedge clk or negedge reset_n)
        if (!reset_n) en <= 23'd0;
        else          en <= {en[21:0], sample_en};

    // ---- 干信号锁存（en[10]：上游引擎流水已稳定） ----
    reg signed [15:0] dry;
    always @(posedge clk or negedge reset_n)
        if (!reset_n)      dry <= 16'sd0;
        else if (en[10] && enable) dry <= pcm_in;

    // 16bit 饱和限幅
    function signed [15:0] sat16;
        input signed [17:0] v;
        begin
            if (v > 18'sd32767)       sat16 = 16'sd32767;
            else if (v < -18'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    // ==================================================================
    // 效果一：回声（18bit 环形缓冲 + 反馈延迟线）
    // ==================================================================
    wire echo_on = enable && (fx_mode == FX_ECHO);
    (* syn_ramstyle="block_ram" *) reg signed [17:0] echo_mem [0:ECHO_DEPTH-1];
    reg [13:0] echo_wr, echo_rd_a;
    reg signed [17:0] echo_rd_d;
    reg signed [17:0] echo_wr_val;
    reg signed [16:0] echo_sum;

    // 不写初值循环：Gowin 综合的循环展开上限是 2000 次（实测 EX3934），
    // 16K 延迟线无法用 initial 清零；且 FPGA 上电 BRAM 内容本就不保证。
    // 改用"预填充"计数：缓冲被完整写过一遍前，读数据一律门控为 0，
    // 既消除上电噪声，又不触碰工具链上限。
    reg echo_primed;
    reg [13:0] echo_fill;
    integer i;
    initial begin
        echo_wr = 14'd0; echo_rd_a = 14'd0; echo_rd_d = 18'sd0;
        echo_wr_val = 18'sd0; echo_sum = 17'sd0;
        echo_primed = 1'b0; echo_fill = 14'd0;
    end

    // 乘积（显式宽中间量，18×16 → 34bit 有符号）
    wire signed [33:0] echo_fb_prod  = echo_rd_d * $signed(ECHO_FB_Q15);
    wire signed [33:0] echo_fb_term  = echo_fb_prod >>> 15;   // ≤0.45×缓冲值
    wire signed [33:0] echo_wet_prod = echo_rd_d * $signed(ECHO_WET_Q15);
    wire signed [33:0] echo_wet_term = echo_wet_prod >>> 15;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            echo_wr <= 14'd0; echo_rd_a <= 14'd0; echo_rd_d <= 18'sd0;
            echo_wr_val <= 18'sd0; echo_sum <= 17'sd0;
            echo_primed <= 1'b0; echo_fill <= 14'd0;
        end else begin
            // 读地址 = 写指针 - 延迟。本采样读 mem[n-DELAY]、写 mem[n]，
            // 故延迟恰为 ECHO_DELAY 个采样（250.0ms @48k），无 off-by-one。
            if (en[10] && echo_on)
                echo_rd_a <= echo_wr - ECHO_DELAY[13:0];
            if (en[11] && echo_on)
                echo_rd_d <= echo_primed ? echo_mem[echo_rd_a] : 18'sd0;
            if (en[12] && echo_on) begin
                // 符号口径：拼接 {,} 与位选 [17:0] 的结果一律是无符号数，
                // 更宽上下文里会被零扩展——负样本直接变巨正数（仿真已抓到
                // 该 bug）。所有参与加减的拼接/位选必须显式 $signed()。
                echo_wr_val <= $signed({dry[15], dry}) + $signed(echo_fb_term[17:0]);
                echo_sum   <= dry + $signed(echo_wet_term[15:0]);
            end
            if (en[13] && echo_on) begin
                echo_mem[echo_wr] <= echo_wr_val;
                echo_wr <= echo_wr + 14'd1;
                if (!echo_primed) begin
                    if (echo_fill == ECHO_DEPTH[13:0] - 14'd1) echo_primed <= 1'b1;
                    else echo_fill <= echo_fill + 14'd1;
                end
            end
        end
    end

    // ==================================================================
    // 效果二：合唱（双抽头调制延迟，前馈，16bit）
    // ==================================================================
    wire chorus_on = enable && (fx_mode == FX_CHORUS);
    (* syn_ramstyle="block_ram" *) reg [15:0] cho_buf1 [0:CHORUS_BUF-1];
    (* syn_ramstyle="block_ram" *) reg [15:0] cho_buf2 [0:CHORUS_BUF-1];
    reg [10:0] cho_wr, cho_rd_a1, cho_rd_a2;
    reg signed [15:0] cho_d1, cho_d2;
    reg signed [15:0] cho_t1, cho_t2, cho_dterm;

    wire signed [15:0] cho_lfo;
    vib_lfo #(.LFO_STEP(CHORUS_LFO_STEP), .ROM_FILE(SINE_ROM_FILE)) u_cho_lfo(
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en), .lfo_sine(cho_lfo));

    // 抽头偏移：960 ± (lfo×192>>>15)，范围 768..1152 < 2048
    wire signed [31:0] cho_mod_full = cho_lfo * $signed(CHORUS_SWING);
    wire signed [15:0] cho_mod = cho_mod_full >>> 15;

    // 同上：2048 项超出 Gowin 2000 次循环上限，改用预填充门控
    reg cho_primed;
    reg [10:0] cho_fill;
    initial begin
        cho_wr = 11'd0; cho_rd_a1 = 11'd0; cho_rd_a2 = 11'd0;
        cho_d1 = 16'sd0; cho_d2 = 16'sd0; cho_t1 = 16'sd0;
        cho_t2 = 16'sd0; cho_dterm = 16'sd0;
        cho_primed = 1'b0; cho_fill = 11'd0;
    end

    wire signed [31:0] cho_t1_prod = cho_d1 * $signed(16'd8192);   // 0.25
    wire signed [31:0] cho_t2_prod = cho_d2 * $signed(16'd8192);
    wire signed [31:0] cho_dt_prod = dry  * $signed(16'd16384);    // 0.50

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cho_wr <= 11'd0; cho_rd_a1 <= 11'd0; cho_rd_a2 <= 11'd0;
            cho_d1 <= 16'sd0; cho_d2 <= 16'sd0; cho_t1 <= 16'sd0;
            cho_t2 <= 16'sd0; cho_dterm <= 16'sd0;
            cho_primed <= 1'b0; cho_fill <= 11'd0;
        end else begin
            if (en[10] && chorus_on) begin
                cho_rd_a1 <= cho_wr - (CHORUS_BASE + cho_mod);
                cho_rd_a2 <= cho_wr - (CHORUS_BASE - cho_mod);
            end
            if (en[11] && chorus_on) begin
                cho_d1 <= cho_primed ? cho_buf1[cho_rd_a1] : 16'sd0;
                cho_d2 <= cho_primed ? cho_buf2[cho_rd_a2] : 16'sd0;
            end
            if (en[12] && chorus_on) begin
                cho_t1    <= cho_t1_prod >>> 15;
                cho_t2    <= cho_t2_prod >>> 15;
                cho_dterm <= cho_dt_prod >>> 15;
            end
            if (en[13] && chorus_on) begin
                cho_buf1[cho_wr] <= dry;
                cho_buf2[cho_wr] <= dry;
                cho_wr <= cho_wr + 11'd1;
                if (!cho_primed) begin
                    if (cho_fill == CHORUS_BUF[10:0] - 11'd1) cho_primed <= 1'b1;
                    else cho_fill <= cho_fill + 11'd1;
                end
            end
        end
    end
    // 合唱输出（en[13] 时 cho_t* 已是本拍寄存值，用组合和）
    // 注意：三个拼接必须 $signed()，否则负样本零扩展成巨正数（老坑 6.2）
    wire signed [17:0] cho_mix = $signed({dry[15], dry})
                               + $signed({cho_t1[15], cho_t1})
                               + $signed({cho_t2[15], cho_t2});

    // ==================================================================
    // 效果三：混响（Schroeder：4 并联梳状 + 2 串联全通，18bit）
    // ==================================================================
    wire rev_on = enable && (fx_mode == FX_REVERB);
    // $signed 必须：无符号拼接上的 >>> 会退化成逻辑移位（负数符号位被清 0）
    wire signed [17:0] rev_in = $signed({dry[15], dry}) >>> 1;   // 入口 -6dB 裕量

    wire signed [17:0] comb_y0, comb_y1, comb_y2, comb_y3;
    comb_filter #(.DELAY(COMB0), .FB_Q15(COMB_FB_Q15)) u_comb0(
        .clk(clk), .reset_n(reset_n), .enable(rev_on), .run(en[10]),
        .x(rev_in), .y(comb_y0));
    comb_filter #(.DELAY(COMB1), .FB_Q15(COMB_FB_Q15)) u_comb1(
        .clk(clk), .reset_n(reset_n), .enable(rev_on), .run(en[10]),
        .x(rev_in), .y(comb_y1));
    comb_filter #(.DELAY(COMB2), .FB_Q15(COMB_FB_Q15)) u_comb2(
        .clk(clk), .reset_n(reset_n), .enable(rev_on), .run(en[10]),
        .x(rev_in), .y(comb_y2));
    comb_filter #(.DELAY(COMB3), .FB_Q15(COMB_FB_Q15)) u_comb3(
        .clk(clk), .reset_n(reset_n), .enable(rev_on), .run(en[10]),
        .x(rev_in), .y(comb_y3));

    reg signed [17:0] rev_sum;
    always @(posedge clk or negedge reset_n)
        if (!reset_n) rev_sum <= 18'sd0;
        else if (en[14] && rev_on)
            rev_sum <= (comb_y0 + comb_y1 + comb_y2 + comb_y3) >>> 2;

    wire signed [17:0] ap0_y, ap1_y;
    allpass_filter #(.DELAY(AP0), .G_Q15(AP_G_Q15)) u_ap0(
        .clk(clk), .reset_n(reset_n), .enable(rev_on), .run(en[14]),
        .x(rev_sum), .y(ap0_y));
    allpass_filter #(.DELAY(AP1), .G_Q15(AP_G_Q15)) u_ap1(
        .clk(clk), .reset_n(reset_n), .enable(rev_on), .run(en[18]),
        .x(ap0_y), .y(ap1_y));

    wire signed [33:0] rev_wet_prod = ap1_y * $signed(REV_WET_Q15);
    wire signed [33:0] rev_wet_term = rev_wet_prod >>> 15;
    wire signed [17:0] rev_mix = $signed({dry[15], dry}) + $signed(rev_wet_term[17:0]);

    // ==================================================================
    // 输出选择（确定性时序：各效果在各自选通拍更新一次）
    // ==================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)     pcm_out <= 16'sd0;
        else if (!enable) pcm_out <= 16'sd0;
        else begin
            if (fx_mode == FX_BYPASS) pcm_out <= pcm_in;
            else if (fx_mode == FX_ECHO && en[13])   pcm_out <= sat16({echo_sum[16], echo_sum});
            else if (fx_mode == FX_CHORUS && en[13]) pcm_out <= sat16(cho_mix);
            else if (fx_mode == FX_REVERB && en[22]) pcm_out <= sat16(rev_mix);
        end
    end
endmodule

// ============================================================================
// comb_filter — 梳状滤波器（反馈延迟线，18bit）
//   y[n] = mem[最旧]；写 mem = x + fb×y；四拍流水：run→读→乘→写
// ============================================================================
module comb_filter #(
    parameter integer DELAY = 1426,
    parameter integer FB_Q15 = 23633
)(
    input  wire clk, reset_n, enable, run,
    input  wire signed [17:0] x,
    output reg  signed [17:0] y
);
    (* syn_ramstyle="block_ram" *) reg signed [17:0] mem [0:DELAY-1];
    reg [11:0] wr, rd_a;
    reg signed [17:0] rd_d, wr_val;
    reg s1, s2, s3;
    // 延迟线最长 2098 > Gowin 2000 次循环上限，故不使用 initial 清零，
    // 改用预填充门控：完整写满一遍前读出 0。
    reg primed;
    reg [11:0] fill;
    initial begin
        wr = 12'd0; rd_a = 12'd0; rd_d = 18'sd0; wr_val = 18'sd0; y = 18'sd0;
        s1 = 1'b0; s2 = 1'b0; s3 = 1'b0;
        primed = 1'b0; fill = 12'd0;
    end
    wire signed [33:0] fb_term = (rd_d * $signed(FB_Q15)) >>> 15;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr <= 12'd0; rd_a <= 12'd0; rd_d <= 18'sd0; wr_val <= 18'sd0;
            y <= 18'sd0; s1 <= 1'b0; s2 <= 1'b0; s3 <= 1'b0;
            primed <= 1'b0; fill <= 12'd0;
        end else begin
            s1 <= run && enable; s2 <= s1; s3 <= s2;
            if (run && enable)
                rd_a <= (wr == DELAY - 1) ? 12'd0 : wr + 12'd1;
            if (s1) rd_d <= primed ? mem[rd_a] : 18'sd0;
            if (s2) wr_val <= x + $signed(fb_term[17:0]);
            if (s3) begin
                mem[wr] <= wr_val;
                y <= rd_d;
                wr <= (wr == DELAY - 1) ? 12'd0 : wr + 12'd1;
                if (!primed) begin
                    if (fill == DELAY[11:0] - 12'd1) primed <= 1'b1;
                    else fill <= fill + 12'd1;
                end
            end
        end
    end
endmodule

// ============================================================================
// allpass_filter — 全通滤波器（18bit）
//   v = x + g×d；y = d - g×v；写 mem = v
// ============================================================================
module allpass_filter #(
    parameter integer DELAY = 240,
    parameter integer G_Q15 = 22938
)(
    input  wire clk, reset_n, enable, run,
    input  wire signed [17:0] x,
    output reg  signed [17:0] y
);
    (* syn_ramstyle="block_ram" *) reg signed [17:0] mem [0:DELAY-1];
    reg [11:0] wr, rd_a;
    reg signed [17:0] rd_d;
    reg signed [17:0] v_reg, y_reg;
    reg s1, s2, s3;
    // 同梳状滤波器：不做 initial 清零，用预填充门控避免读到未初始化内容
    reg primed;
    reg [11:0] fill;
    initial begin
        wr = 12'd0; rd_a = 12'd0; rd_d = 18'sd0; v_reg = 18'sd0; y_reg = 18'sd0;
        s1 = 1'b0; s2 = 1'b0; s3 = 1'b0;
        primed = 1'b0; fill = 12'd0;
    end
    wire signed [33:0] gd_term = (rd_d * $signed(G_Q15)) >>> 15;   // g×d
    wire signed [33:0] gv_term = (v_reg * $signed(G_Q15)) >>> 15;  // g×v
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr <= 12'd0; rd_a <= 12'd0; rd_d <= 18'sd0; v_reg <= 18'sd0;
            y <= 18'sd0; s1 <= 1'b0; s2 <= 1'b0; s3 <= 1'b0;
            primed <= 1'b0; fill <= 12'd0;
        end else begin
            s1 <= run && enable; s2 <= s1; s3 <= s2;
            if (run && enable)
                rd_a <= (wr == DELAY - 1) ? 12'd0 : wr + 12'd1;
            if (s1) rd_d <= primed ? mem[rd_a] : 18'sd0;
            if (s2) v_reg <= x + $signed(gd_term[17:0]);
            if (s3) begin
                mem[wr] <= v_reg;
                y <= rd_d - $signed(gv_term[17:0]);
                wr <= (wr == DELAY - 1) ? 12'd0 : wr + 12'd1;
                if (!primed) begin
                    if (fill == DELAY[11:0] - 12'd1) primed <= 1'b1;
                    else fill <= fill + 12'd1;
                end
            end
        end
    end
endmodule
