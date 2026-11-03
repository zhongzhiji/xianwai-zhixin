`timescale 1ns/1ps
// ============================================================================
//  fsr32_engine.v — 32 独立复音合成引擎（拓展 E1 / E2 / 现场验证测试模式）
// ----------------------------------------------------------------------------
//  在 music_final_20261010 的 fsr16_engine 架构上做**纯增量**扩展，全部沿用
//  已上板验证过的设计决策（独立相位累加器+独立频率+独立ADSR、寄存器化平衡
//  加法树、显式位宽乘法、寄存器显式初值）：
//
//  ▶ 拓展E1（复音≥32）：
//    - 声部 0..15 ：16 路压力演奏自然音（与 fsr16_engine 完全同口径）
//    - 声部 16..31：16 路"自动声部垫"（ensemble），由 ext_freq_word 根音按
//      固定音程派生（低八度/同度/大三度/纯五度/八度/十度/十二度/双八度，
//      B 组带 +0.39%≈7 音分失谐做合奏感），逐声部独立 gate
//    - N 音测试模式：test_mode=1 时全部 32 声部接内部半音频率表
//      （MIDI 48..79 = C3..G5），test_count 选择同时发声数 1..32，
//      供赛题"现场频谱验证：测试模式 + 可数谱峰"直接使用
//    - 32 声部 = 32 份独立 ROM 实例（资源核算：现工程 BSRAM 168/340，
//      +16 声部 ≈ +96 块、效果器 ≈ +25 块后仍在 340 内；若布线失败，
//      回退方案见 README_EXT 的"时分复用"一节，与 gowin-2026-synth §6.4
//      的教训一致）
//
//  ▶ 拓展E2（三维表情）：力度(expression)已有；本文件新增
//    - 颤音 vibrato：5.5Hz 正弦 LFO → 相位增量调制，深度 vib_depth 0..15
//      （0=关；15 ≈ ±12.7 音分）。偏移量 = fw × depth × LFO >>> VIB_SHIFT，
//      用**单个时分复用乘法器**串行服务 32 声部（每采样周期 1042 拍只花
//      32 拍）——刻意避免"32 个共享操作数乘法器"被串成 DSP 级联链的老坑
//    - 滑音 portamento：声部 0（旋律声部）的目标频率字指数式滑向新目标，
//      glide_rate 0..7 → 2^(9+rate) 采样时间常数（10ms..1.4s）
//
//  ▶ 兼容性：端口是 fsr16_engine 的超集。把 fsr16_audio_wrapper 里的
//    fsr16_engine 换成 fsr32_engine、新增端口按需接 0，原有 16 键演奏
//    行为不变（LAYOUT/VOL_SHIFT/CHROMATIC_AUDITION 参数口径一致）。
//
//  频率字口径不变：fw = round(f/48000 × 2^32)，与 note_freq.vh 同源。
// ============================================================================
`include "note_freq.vh"

module fsr32_engine #(
    parameter integer LAYOUT = 1,
    parameter integer VOL_SHIFT = 4,
    parameter integer CHROMATIC_AUDITION = 0,
    parameter ROM_FILE = "audio/rom/wavetable_showcase.mem",
    // 颤音：偏移 = (fw × depth × LFO) >>> VIB_SHIFT；depth=15 时 ≈ ±0.73%（±12.7音分）
    parameter integer VIB_SHIFT = 26,
    parameter integer VIB_RATE_STEP = 1928,     // 5.5Hz @48k（24bit 相位步进）
    parameter integer GLIDE_SHIFT_BASE = 9      // glide_rate 0..7 → 移位 9..16
)(
    input  wire        clk50, reset_n, sample_en, enable,
    // 声部 0..15：压力演奏 gate（与 fsr16_engine 相同语义）
    input  wire [15:0] note_gate,
    // 声部 16..31：自动声部垫 gate 与根音频率字（root=0 时整体静音）
    input  wire [15:0] ext_gate,
    input  wire [31:0] ext_freq_word,
    input  wire [1:0]  family, preset, octave,
    input  wire [6:0]  expression,
    // 声部 0 试听频率覆盖（沿用 fsr16_engine 的口径）
    input  wire        freq_override,
    input  wire [31:0] freq_override_word,
    // E1 现场验证测试模式
    input  wire        test_mode,
    input  wire [5:0]  test_count,      // 1..32；0 或 >32 按 32 处理
    // E2 表情控制
    input  wire [3:0]  vib_depth,       // 0=关
    input  wire        glide_en,
    input  wire [2:0]  glide_rate,

    output reg  signed [15:0] pcm,
    output wire [31:0] voices_active,
    output reg  [15:0] note_on, note_off,
    output reg  [15:0] expression_smoothed,
    output wire        clipped
);

    // ------------------------------------------------------------------
    // 0. 频率来源：自然音表 / 试听覆盖 / 测试半音表 / 自动声部垫音程
    // ------------------------------------------------------------------
    // 自然音表（与 freq_map.v 同一份数据，参数化函数便于常量折叠）
    function [31:0] natural_fw_of;
        input integer layout, idx;
        begin
            if (layout == 1) begin
                case (idx)
                    0:  natural_fw_of = NOTE_FW_60;   // C4
                    1:  natural_fw_of = NOTE_FW_62;   // D4
                    2:  natural_fw_of = NOTE_FW_64;   // E4
                    3:  natural_fw_of = NOTE_FW_65;   // F4
                    4:  natural_fw_of = NOTE_FW_67;   // G4
                    5:  natural_fw_of = NOTE_FW_69;   // A4
                    6:  natural_fw_of = NOTE_FW_71;   // B4
                    7:  natural_fw_of = NOTE_FW_72;   // C5
                    8:  natural_fw_of = NOTE_FW_74;   // D5
                    9:  natural_fw_of = NOTE_FW_76;   // E5
                    10: natural_fw_of = NOTE_FW_77;   // F5
                    11: natural_fw_of = NOTE_FW_79;   // G5
                    12: natural_fw_of = NOTE_FW_81;   // A5
                    13: natural_fw_of = NOTE_FW_83;   // B5
                    14: natural_fw_of = NOTE_FW_84;   // C6
                    15: natural_fw_of = NOTE_FW_86;   // D6
                    default: natural_fw_of = 32'd0;
                endcase
            end else begin
                case (idx)
                    0:  natural_fw_of = NOTE_FW_60;   // C4
                    1:  natural_fw_of = NOTE_FW_61;
                    2:  natural_fw_of = NOTE_FW_62;
                    3:  natural_fw_of = NOTE_FW_63;
                    4:  natural_fw_of = NOTE_FW_64;
                    5:  natural_fw_of = NOTE_FW_65;
                    6:  natural_fw_of = NOTE_FW_66;
                    7:  natural_fw_of = NOTE_FW_67;
                    8:  natural_fw_of = NOTE_FW_68;
                    9:  natural_fw_of = NOTE_FW_69;
                    10: natural_fw_of = NOTE_FW_70;
                    11: natural_fw_of = NOTE_FW_71;
                    12: natural_fw_of = NOTE_FW_72;
                    13: natural_fw_of = NOTE_FW_73;
                    14: natural_fw_of = NOTE_FW_74;
                    15: natural_fw_of = NOTE_FW_75;
                    default: natural_fw_of = 32'd0;
                endcase
            end
        end
    endfunction

    // 测试模式半音表：MIDI 48..79（C3..G5），32 个连续半音
    function [31:0] test_fw_of;
        input integer idx;
        begin
            case (idx)
                0:  test_fw_of = NOTE_FW_48;   1:  test_fw_of = NOTE_FW_49;
                2:  test_fw_of = NOTE_FW_50;   3:  test_fw_of = NOTE_FW_51;
                4:  test_fw_of = NOTE_FW_52;   5:  test_fw_of = NOTE_FW_53;
                6:  test_fw_of = NOTE_FW_54;   7:  test_fw_of = NOTE_FW_55;
                8:  test_fw_of = NOTE_FW_56;   9:  test_fw_of = NOTE_FW_57;
                10: test_fw_of = NOTE_FW_58;   11: test_fw_of = NOTE_FW_59;
                12: test_fw_of = NOTE_FW_60;   13: test_fw_of = NOTE_FW_61;
                14: test_fw_of = NOTE_FW_62;   15: test_fw_of = NOTE_FW_63;
                16: test_fw_of = NOTE_FW_64;   17: test_fw_of = NOTE_FW_65;
                18: test_fw_of = NOTE_FW_66;   19: test_fw_of = NOTE_FW_67;
                20: test_fw_of = NOTE_FW_68;   21: test_fw_of = NOTE_FW_69;
                22: test_fw_of = NOTE_FW_70;   23: test_fw_of = NOTE_FW_71;
                24: test_fw_of = NOTE_FW_72;   25: test_fw_of = NOTE_FW_73;
                26: test_fw_of = NOTE_FW_74;   27: test_fw_of = NOTE_FW_75;
                28: test_fw_of = NOTE_FW_76;   29: test_fw_of = NOTE_FW_77;
                30: test_fw_of = NOTE_FW_78;   default: test_fw_of = NOTE_FW_79;
            endcase
        end
    endfunction

    // 自动声部垫：根音 r → 16 个固定音程（B 组 +r>>8 ≈ +0.39% 失谐）
    // 根音请勿超过 C6（r<<2 溢出 32bit 会绕回）
    function [31:0] ensemble_fw_of;
        input integer e;
        reg [31:0] r;
        begin
            r = ext_freq_word;
            case (e)
                0:  ensemble_fw_of = r >> 1;                 // 低八度
                1:  ensemble_fw_of = r;                      // 同度
                2:  ensemble_fw_of = r + (r >> 2);           // ×1.25 大三度
                3:  ensemble_fw_of = r + (r >> 1);           // ×1.5  纯五度
                4:  ensemble_fw_of = r << 1;                 // 八度
                5:  ensemble_fw_of = (r << 1) + (r >> 2);    // ×2.25 十度
                6:  ensemble_fw_of = (r << 1) + r;           // ×3    十二度
                7:  ensemble_fw_of = r << 2;                 // 双八度
                8:  ensemble_fw_of = (r >> 1) + (r >> 8);    // B组同音程+失谐
                9:  ensemble_fw_of = r + (r >> 8);
                10: ensemble_fw_of = r + (r >> 2) + (r >> 8);
                11: ensemble_fw_of = r + (r >> 1) + (r >> 8);
                12: ensemble_fw_of = (r << 1) + (r >> 8);
                13: ensemble_fw_of = (r << 1) + (r >> 2) + (r >> 8);
                14: ensemble_fw_of = (r << 1) + r + (r >> 8);
                default: ensemble_fw_of = (r << 2) + (r >> 8);
            endcase
        end
    endfunction

    // 32 个频率源（组合逻辑，输入为准静态 UART/UI 信号）
    //
    // 【11/01 仿真修复】必须用 generate + 连续赋值，不能用 always @*：
    // ensemble_fw_of 的函数体里引用了模块输入 ext_freq_word，而 iverilog
    // 的 @* 不把"函数体内引用的信号"放进敏感度列表 —— t=0 时输入端口还是
    // x，块按 x 求值把 fw_src 全部算成 x，之后 ext_freq_word 稳定下来也
    // 不再触发重算，32 路频率字永远是 x（tb_latency 实测：vib 扫描把 x
    // 写满 fw_eff → 全部声部 phase=x → 混音树 x → pcm=x）。
    // 连续赋值没有敏感度列表概念，RHS 任何操作数变化都重算，两个仿真器
    // 行为一致；对综合器而言两者本来就是同一棵组合锥，网表不变。
    wire [31:0] fw_src [0:31];
    genvar fv;
    generate for (fv = 0; fv < 32; fv = fv + 1) begin : FW_SRC
        if (fv < 16) begin : NAT
            wire [31:0] nat_fw = (octave == 2'd0) ? (natural_fw_of(LAYOUT, fv) >> 1) :
                                 (octave == 2'd1) ? natural_fw_of(LAYOUT, fv)   :
                                 (octave == 2'd2) ? (natural_fw_of(LAYOUT, fv) << 1) :
                                                    (natural_fw_of(LAYOUT, fv) << 2);
            assign fw_src[fv] = test_mode ? test_fw_of(fv) :
                     ((fv == 0 && CHROMATIC_AUDITION != 0 && freq_override) ?
                      freq_override_word : nat_fw);
        end else begin : ENS
            assign fw_src[fv] = test_mode ? test_fw_of(fv) : ensemble_fw_of(fv - 16);
        end
    end endgenerate

    // ------------------------------------------------------------------
    // 1. 滑音（声部0）：目标频率字 → glide_reg 指数式逼近
    // ------------------------------------------------------------------
    wire [31:0] target0 = test_mode ? test_fw_of(0) :
                 ((CHROMATIC_AUDITION != 0 && freq_override) ? freq_override_word :
                 ((octave == 2'd0) ? (natural_fw_of(LAYOUT, 0) >> 1) :
                  (octave == 2'd1) ? natural_fw_of(LAYOUT, 0)   :
                  (octave == 2'd2) ? (natural_fw_of(LAYOUT, 0) << 1) :
                                     (natural_fw_of(LAYOUT, 0) << 2)));
    reg [31:0] glide_reg = 32'd0;
    wire [31:0] glide_hi  = (glide_reg > target0) ? glide_reg : target0;
    wire [31:0] glide_lo  = (glide_reg > target0) ? target0   : glide_reg;
    wire [31:0] glide_raw = glide_hi >>> (GLIDE_SHIFT_BASE + glide_rate);
    wire [31:0] glide_step = (glide_raw < 32'd1) ? 32'd1 : glide_raw;

    // ------------------------------------------------------------------
    // 2. 颤音：共享 LFO + 单乘法器串行服务 32 声部
    // ------------------------------------------------------------------
    wire signed [15:0] lfo_sine;
    vib_lfo #(.LFO_STEP(VIB_RATE_STEP)) u_lfo(
        .clk(clk50), .reset_n(reset_n), .sample_en(sample_en),
        .lfo_sine(lfo_sine));

    // depth(4bit) × lfo(16bit signed)：显式符号化，避免无符号传染（老坑 6.2）
    wire signed [20:0] dl = $signed({1'b0, vib_depth}) * lfo_sine;

    reg [31:0] fw_eff [0:31];
    reg [5:0]  vib_idx;
    reg        vib_busy;

    // 声部0 用滑音后的频率作颤音基；33×21 显式 54 位中间量
    wire [31:0] vib_base = (vib_idx == 6'd0) ? glide_reg : fw_src[vib_idx];

    // ------------------------------------------------------------------
    // 颤音三级流水（时序修复，非功能改动）
    //
    // 原来从"跨时钟邮箱 dst_data → MIDI 频率 ROM → 音程移位 → 32×21 乘法
    // → 54 位移位 → 32 位加法 → fw_eff 的 D 端"是一整条组合锥，
    // 50MHz(20ns) 下实测数据延时 22.4 ns，炸出 1113 个 setup 违例端点、
    // TNS −1647 ns。这里把锥在乘法器前后各插一级寄存器切开：
    //   第 1 拍：锁 vib_base / dl
    //   第 2 拍：乘 + 移位 + 加，锁成 vib_sum_r
    //   第 3 拍：写回 fw_eff
    // 颤音扫描本来就是每个采样点串行走 32 拍（48kHz 采样下 50MHz 有
    // 1000+ 拍预算），多 2 拍延迟完全听不出来。
    // ------------------------------------------------------------------
    reg [31:0]        vib_base_r;
    reg signed [20:0] dl_r;
    reg [5:0]         vib_idx_p1, vib_idx_p2;
    reg               vib_busy_p1, vib_busy_p2;
    reg [31:0]        vib_sum_r;

    wire signed [53:0] vib_prod    = $signed({1'b0, vib_base_r}) * dl_r;
    wire signed [53:0] vib_shifted = vib_prod >>> VIB_SHIFT;
    wire [31:0]        vib_off     = (vib_depth == 4'd0) ? 32'd0 : vib_shifted[31:0];

    always @(posedge clk50 or negedge reset_n) begin : VIB_SCAN
        integer i;
        if (!reset_n) begin
            vib_idx <= 6'd0; vib_busy <= 1'b0;
            vib_base_r <= 32'd0; dl_r <= 21'd0;
            vib_idx_p1 <= 6'd0;  vib_idx_p2 <= 6'd0;
            vib_busy_p1 <= 1'b0; vib_busy_p2 <= 1'b0;
            vib_sum_r <= 32'd0;
            for (i = 0; i < 32; i = i + 1) fw_eff[i] <= 32'd0;
        end else begin
            vib_base_r  <= vib_base;
            dl_r        <= dl;
            vib_idx_p1  <= vib_idx;
            vib_idx_p2  <= vib_idx_p1;
            vib_busy_p1 <= vib_busy;
            vib_busy_p2 <= vib_busy_p1;
            vib_sum_r   <= vib_base_r + vib_off;

            if (vib_busy_p2) fw_eff[vib_idx_p2] <= vib_sum_r;

            if (sample_en) begin
                vib_idx  <= 6'd0;
                vib_busy <= 1'b1;
            end else if (vib_busy) begin
                if (vib_idx == 6'd31) vib_busy <= 1'b0;
                vib_idx <= vib_idx + 6'd1;
            end
        end
    end
    // 仿真口径：显式初值（真实 FPGA 上电 FF=0，老坑 6.3）
    initial begin : FW_EFF_INIT
        integer i;
        for (i = 0; i < 32; i = i + 1) fw_eff[i] = 32'd0;
    end

    // ------------------------------------------------------------------
    // 3. 32 个独立声部
    // ------------------------------------------------------------------
    wire [15:0] effective_gate = enable ? note_gate : 16'd0;
    wire [15:0] effective_ext   = enable ? (ext_gate & {16{ext_freq_word != 32'd0}}) : 16'd0;
    wire [5:0]  test_cnt = (test_count == 6'd0 || test_count > 6'd32) ? 6'd32 : test_count;
    // 32 路 gate 拼成一个向量后按位选：低 16 = 压力演奏声部，高 16 = 自动声部垫。
    // （坑：写成 v<16 ? gate[v] : ext[v-16] 时，v=0..15 会生成 ext[-16] 越界位选，
    //   仿真器补 X、综合器报 warning —— 拼接取位可完全避免。）
    wire [31:0] gate_all = {effective_ext, effective_gate};

    // 必须是 wire（net）：模块输出端口不能连到 reg。
    // iverilog 对此宽容、Gowin 直接报 EX3805，这里以 Gowin 为准。
    // 后续使用处已用 $signed 取符号，故此处不再声明 signed memory。
    wire [15:0] voice_sample [0:31];
    wire        voice_active  [0:31];

    genvar v;
    generate for (v = 0; v < 32; v = v + 1) begin: VOICE
        wire gate_v = test_mode ? (test_cnt > v) : gate_all[v];
        timbre_voice #(.VOL_SHIFT(VOL_SHIFT), .ROM_FILE(ROM_FILE)) u_voice(
            .clk(clk50), .reset_n(reset_n), .sample_en(sample_en), .enable(enable),
            .gate(gate_v), .freq_word(fw_eff[v]), .family(family), .preset(preset),
            .sample(voice_sample[v]), .active(voice_active[v]));
    end endgenerate

    generate for (v = 0; v < 32; v = v + 1) begin: ACTMAP
        assign voices_active[v] = voice_active[v];
    end endgenerate

    // ------------------------------------------------------------------
    // 4. 混音：寄存器化平衡加法树（50MHz 流水，32 声部 5 级）
    // ------------------------------------------------------------------
    reg signed [16:0] level1 [0:15];
    reg signed [17:0] level2 [0:7];
    reg signed [18:0] level3 [0:3];
    reg signed [19:0] level4 [0:1];
    reg signed [20:0] level5;

    generate
        for (v = 0; v < 16; v = v + 1) begin: MIX1
            wire signed [15:0] a = voice_sample[2*v];
            wire signed [15:0] b = voice_sample[2*v + 1];
            always @(posedge clk50 or negedge reset_n)
                if (!reset_n)      level1[v] <= 17'sd0;
                else if (!enable)  level1[v] <= 17'sd0;
                else level1[v] <= $signed({a[15], a}) + $signed({b[15], b});
        end
        for (v = 0; v < 8; v = v + 1) begin: MIX2
            always @(posedge clk50 or negedge reset_n)
                if (!reset_n)      level2[v] <= 18'sd0;
                else if (!enable)  level2[v] <= 18'sd0;
                else level2[v] <= $signed({level1[2*v][16], level1[2*v]}) +
                                  $signed({level1[2*v+1][16], level1[2*v+1]});
        end
        for (v = 0; v < 4; v = v + 1) begin: MIX3
            always @(posedge clk50 or negedge reset_n)
                if (!reset_n)      level3[v] <= 19'sd0;
                else if (!enable)  level3[v] <= 19'sd0;
                else level3[v] <= $signed({level2[2*v][17], level2[2*v]}) +
                                  $signed({level2[2*v+1][17], level2[2*v+1]});
        end
        for (v = 0; v < 2; v = v + 1) begin: MIX4
            always @(posedge clk50 or negedge reset_n)
                if (!reset_n)      level4[v] <= 20'sd0;
                else if (!enable)  level4[v] <= 20'sd0;
                else level4[v] <= $signed({level3[2*v][18], level3[2*v]}) +
                                  $signed({level3[2*v+1][18], level3[2*v+1]});
        end
    endgenerate

    // 32 声部满编峰值 ≈ 32×±1750：加法树输出再统一衰减 6dB，回到 ±16bit 内
    // 位宽口径：mix_atten(21bit signed) × expression(17bit signed) = 38bit。
    // 显式给足 38 位（老坑 6.2：a*b 位宽不是 max 而是和，少了就静默截断）。
    reg signed [20:0] mix_atten;
    reg signed [37:0] gain_product;
    always @(posedge clk50 or negedge reset_n)
        if (!reset_n) begin
            level5 <= 21'sd0; mix_atten <= 21'sd0; gain_product <= 38'sd0;
        end else if (!enable) begin
            level5 <= 21'sd0; mix_atten <= 21'sd0; gain_product <= 38'sd0;
        end else begin
            level5 <= $signed({level4[0][19], level4[0]}) +
                      $signed({level4[1][19], level4[1]});
            mix_atten   <= level5 >>> 1;
            gain_product <= mix_atten * $signed({1'b0, expression_smoothed});
        end
    wire signed [37:0] gain_scaled = gain_product >>> 15;
    assign clipped = enable && (gain_scaled > 37'sd32767 || gain_scaled < -37'sd32768);

    // ------------------------------------------------------------------
    // 5. 包络平滑 / note 事件 / 输出限幅（与 fsr16_engine 相同）
    // ------------------------------------------------------------------
    wire [15:0] gain_target = {1'b0, expression, 8'd0};
    reg [15:0] previous_gate;

    always @(posedge clk50 or negedge reset_n) begin
        if (!reset_n) begin
            pcm <= 16'sd0; expression_smoothed <= 16'd0;
            previous_gate <= 16'd0; note_on <= 16'd0; note_off <= 16'd0;
            glide_reg <= 32'd0;
        end else begin
            previous_gate <= effective_gate;
            note_on  <= effective_gate & ~previous_gate;
            note_off <= previous_gate & ~effective_gate;
            if (!enable) begin
                pcm <= 16'sd0; expression_smoothed <= 16'd0; glide_reg <= 32'd0;
            end else begin
                if (sample_en) begin
                    // 力度（表情第一维）平滑：满量程行程 <5.4ms@48k，无帧间跳变
                    if (expression_smoothed + 17'd128 < {1'b0, gain_target})
                        expression_smoothed <= expression_smoothed + 16'd128;
                    else if ({1'b0, expression_smoothed} > gain_target + 17'd128)
                        expression_smoothed <= expression_smoothed - 16'd128;
                    else expression_smoothed <= gain_target;
                    // 滑音（表情第二维）：指数逼近
                    if (!glide_en) glide_reg <= target0;
                    else if (glide_hi - glide_lo <= glide_step) glide_reg <= target0;
                    else if (glide_reg < target0) glide_reg <= glide_reg + glide_step;
                    else glide_reg <= glide_reg - glide_step;
                end
                if (gain_scaled > 37'sd32767)       pcm <= 16'sd32767;
                else if (gain_scaled < -37'sd32768) pcm <= -16'sd32768;
                else pcm <= gain_scaled[15:0];
            end
        end
    end
endmodule
