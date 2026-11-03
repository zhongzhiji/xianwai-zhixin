// ============================================================================
// audio_spectrum_goertzel.v -- 32 个半音频点的实时频谱（sys_clk 域）
// ----------------------------------------------------------------------------
// 48 kHz PCM -> 8 点平均并抽取到 6 kHz -> 4096 点 Goertzel。
// 频点为 MIDI 48..79（C3..G5），与 N 音测试的 32 个半音一一对应。
//
// 资源约束：
//   * 每来一个抽取样本，用 64 个 sys_clk 周期顺序更新 32 个频点
//     （每频点两拍：A 拍大 mux 取样并寄存，B 拍乘加写回；
//     帧末幅度折算再放第三级流水，关键路径不含 mux+乘法+msb 长链）；
//     只例化一个共享乘法器，不做 32 路并行 FFT。
//   * 状态与显示幅度使用寄存器平面，不声明 RAM/ROM 数组，不新增 BSRAM。
//   * 4096/6000 = 0.683 s 一帧，频率分辨率 1.465 Hz，能分开最低频点的
//     相邻半音；矩形窗不加乘法器，谱峰位置比绝对幅度精度更重要。
//
// 输出不是 256 bit 异步宽总线，而是 {toggle, bin, level} 慢速串行快照。
// 一帧算完后每 64 个 sys_clk 送一个频点，mailbox 有足够时间完成握手。
// level 是幅度的 log2 映射（0..63），适合 LCD 柱图，不声明为线性功率值。
// ============================================================================
`timescale 1ns / 1ps

module audio_spectrum_goertzel #(
    parameter integer FRAME_LOG2 = 12,       // 4096 个抽取样本
    parameter integer STREAM_GAP = 64
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_en,            // 48 kHz
    input  wire        enable,
    input  wire signed [15:0] pcm_in,
    output reg  [4:0]  spec_bin,
    output reg  [7:0]  spec_level,
    output reg         spec_toggle,
    output reg         frame_done
);
    localparam integer N_BINS = 32;
    localparam [12:0] FRAME_LAST = (1 << FRAME_LOG2) - 1;

    // 平面寄存器而非数组：避免综合器把状态推断成块 RAM。
    reg [32*N_BINS-1:0] state1_flat;
    reg [32*N_BINS-1:0] state2_flat;
    reg [8*N_BINS-1:0]  level_flat;

    reg signed [18:0] avg_acc;
    reg [2:0]         avg_count;
    reg signed [15:0] dec_sample;
    reg [FRAME_LOG2-1:0] frame_count;

    reg               bin_busy;
    reg               bin_phase;          // 0=取样拍A  1=写回拍B
    reg [4:0]         bin_index;
    reg signed [31:0] s1_r;
    reg signed [31:0] s2_r;
    reg signed [17:0] coef_r;
    reg               lvl_pending;        // 帧末幅度折算流水级
    reg signed [31:0] lvl_a;
    reg signed [31:0] lvl_b;
    reg [4:0]         lvl_bin;
    reg               stream_busy;
    reg [4:0]         stream_index;
    reg [15:0]        stream_wait;

    function signed [17:0] coeff_for_bin;
        input [4:0] index;
        begin
            case (index)
                5'd0:  coeff_for_bin = 18'sd129844; // C3  130.813 Hz
                5'd1:  coeff_for_bin = 18'sd129694;
                5'd2:  coeff_for_bin = 18'sd129526;
                5'd3:  coeff_for_bin = 18'sd129337;
                5'd4:  coeff_for_bin = 18'sd129125;
                5'd5:  coeff_for_bin = 18'sd128887;
                5'd6:  coeff_for_bin = 18'sd128620;
                5'd7:  coeff_for_bin = 18'sd128321;
                5'd8:  coeff_for_bin = 18'sd127985;
                5'd9:  coeff_for_bin = 18'sd127609; // A3  220 Hz
                5'd10: coeff_for_bin = 18'sd127187;
                5'd11: coeff_for_bin = 18'sd126714;
                5'd12: coeff_for_bin = 18'sd126183; // C4  261.626 Hz
                5'd13: coeff_for_bin = 18'sd125589;
                5'd14: coeff_for_bin = 18'sd124923;
                5'd15: coeff_for_bin = 18'sd124176;
                5'd16: coeff_for_bin = 18'sd123340;
                5'd17: coeff_for_bin = 18'sd122404;
                5'd18: coeff_for_bin = 18'sd121356;
                5'd19: coeff_for_bin = 18'sd120183;
                5'd20: coeff_for_bin = 18'sd118870;
                5'd21: coeff_for_bin = 18'sd117403; // A4  440 Hz
                5'd22: coeff_for_bin = 18'sd115762;
                5'd23: coeff_for_bin = 18'sd113929;
                5'd24: coeff_for_bin = 18'sd111882;
                5'd25: coeff_for_bin = 18'sd109599;
                5'd26: coeff_for_bin = 18'sd107052;
                5'd27: coeff_for_bin = 18'sd104215;
                5'd28: coeff_for_bin = 18'sd101058;
                5'd29: coeff_for_bin = 18'sd97547;
                5'd30: coeff_for_bin = 18'sd93648;
                5'd31: coeff_for_bin = 18'sd89325;  // G5  783.991 Hz
                default: coeff_for_bin = 18'sd0;
            endcase
        end
    endfunction

    // 幅度只用于显示：log2(|s1|+|s2|) 映射到 0..63。
    // 用最高有效位代替平方和/开方，避免额外 32x32 乘法与 DSP。
    function automatic [7:0] state_to_level;
        input signed [31:0] a;
        input signed [31:0] b;
        reg [31:0] aa;
        reg [31:0] bb;
        reg [32:0] sum;
        integer k;
        integer msb;
        begin
            aa = a[31] ? (~a + 32'd1) : a;
            bb = b[31] ? (~b + 32'd1) : b;
            sum = {1'b0, aa} + {1'b0, bb};
            msb = 0;
            for (k = 0; k < 33; k = k + 1)
                if (sum[k]) msb = k;
            if (msb < 8)       state_to_level = 8'd0;
            else if (msb > 22) state_to_level = 8'd63;
            else               state_to_level = (msb - 7) << 2;
        end
    endfunction

    // A 拍：纯取样（大 mux 输出进寄存器）；B 拍以下全部以寄存器为源。
    wire signed [31:0] cur_s1 = state1_flat[bin_index*32 +: 32];
    wire signed [31:0] cur_s2 = state2_flat[bin_index*32 +: 32];
    wire signed [17:0] cur_coeff = coeff_for_bin(bin_index);
    wire signed [49:0] coeff_product = coef_r * s1_r;
    wire signed [31:0] coeff_term = coeff_product >>> 16;
    wire signed [31:0] dec_extended = {{16{dec_sample[15]}}, dec_sample};
    wire signed [31:0] next_state = dec_extended + coeff_term - s2_r;
    wire signed [18:0] avg_with_new = avg_acc + {{3{pcm_in[15]}}, pcm_in};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state1_flat <= {32*N_BINS{1'b0}};
            state2_flat <= {32*N_BINS{1'b0}};
            level_flat  <= {8*N_BINS{1'b0}};
            avg_acc     <= 19'sd0;
            avg_count   <= 3'd0;
            dec_sample  <= 16'sd0;
            frame_count <= {FRAME_LOG2{1'b0}};
            bin_busy    <= 1'b0;
            bin_phase   <= 1'b0;
            bin_index   <= 5'd0;
            s1_r        <= 32'sd0;
            s2_r        <= 32'sd0;
            coef_r      <= 18'sd0;
            lvl_pending <= 1'b0;
            lvl_a       <= 32'sd0;
            lvl_b       <= 32'sd0;
            lvl_bin     <= 5'd0;
            stream_busy <= 1'b0;
            stream_index<= 5'd0;
            stream_wait <= 16'd0;
            spec_bin    <= 5'd0;
            spec_level  <= 8'd0;
            spec_toggle <= 1'b0;
            frame_done  <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            if (!enable) begin
                // 静音时从头开始，避免旧帧幅度一直留在屏幕上。
                state1_flat <= {32*N_BINS{1'b0}};
                state2_flat <= {32*N_BINS{1'b0}};
                level_flat  <= {8*N_BINS{1'b0}};
                avg_acc     <= 19'sd0;
                avg_count   <= 3'd0;
                frame_count <= {FRAME_LOG2{1'b0}};
                bin_busy    <= 1'b0;
                bin_phase   <= 1'b0;
                lvl_pending <= 1'b0;
                stream_busy <= 1'b0;
            end else begin
                // ---- 帧末幅度折算独立流水级：寄存器 -> msb 折算 -> 定址写 ----
                if (lvl_pending) begin
                    level_flat[lvl_bin*8 +: 8] <= state_to_level(lvl_a, lvl_b);
                    lvl_pending <= 1'b0;
                end
                // ---- 8 点滑动块平均 + 抽取，兼有简单抗混叠低通 ----
                if (sample_en && !bin_busy) begin
                    if (avg_count == 3'd7) begin
                        avg_acc    <= 19'sd0;
                        avg_count  <= 3'd0;
                        dec_sample <= avg_with_new >>> 3;
                        bin_busy   <= 1'b1;
                        bin_index  <= 5'd0;
                    end else begin
                        avg_acc   <= avg_with_new;
                        avg_count <= avg_count + 3'd1;
                    end
                end

                // ---- 每个抽取样本顺序更新 32 个 Goertzel 频点（每点两拍） ----
                if (bin_busy) begin
                    if (!bin_phase) begin
                        // A 拍：只跑 32:1 大 mux，结果寄存
                        s1_r      <= cur_s1;
                        s2_r      <= cur_s2;
                        coef_r    <= cur_coeff;
                        bin_phase <= 1'b1;
                    end else begin
                        // B 拍：乘法 + 累减 + 定址写回，源全是寄存器
                        if (frame_count == FRAME_LAST) begin
                            lvl_a       <= next_state;
                            lvl_b       <= s1_r;
                            lvl_bin     <= bin_index;
                            lvl_pending <= 1'b1;
                            state1_flat[bin_index*32 +: 32] <= 32'sd0;
                            state2_flat[bin_index*32 +: 32] <= 32'sd0;
                        end else begin
                            state1_flat[bin_index*32 +: 32] <= next_state;
                            state2_flat[bin_index*32 +: 32] <= s1_r;
                        end
                        bin_phase <= 1'b0;

                        if (bin_index == 5'd31) begin
                            bin_busy <= 1'b0;
                            if (frame_count == FRAME_LAST) begin
                                frame_count <= {FRAME_LOG2{1'b0}};
                                frame_done  <= 1'b1;
                                stream_busy <= 1'b1;
                                stream_index<= 5'd0;
                                stream_wait <= 16'd0;
                            end else begin
                                frame_count <= frame_count + 1'b1;
                            end
                        end else begin
                            bin_index <= bin_index + 5'd1;
                        end
                    end
                end

                // ---- 窄串行输出：32 帧间隔远小于下一帧到来的 0.683 s ----
                if (stream_busy) begin
                    if (stream_wait != 16'd0) begin
                        stream_wait <= stream_wait - 16'd1;
                    end else begin
                        spec_bin    <= stream_index;
                        spec_level  <= level_flat[stream_index*8 +: 8];
                        spec_toggle <= ~spec_toggle;
                        stream_wait <= STREAM_GAP - 1;
                        if (stream_index == 5'd31) begin
                            stream_busy <= 1'b0;
                        end else begin
                            stream_index <= stream_index + 5'd1;
                        end
                    end
                end
            end
        end
    end
endmodule
