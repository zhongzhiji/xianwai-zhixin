// Original warm-paper staff layout restored in isolated V3.
// All real-font text uses one synchronous 2-bit coverage ROM, with exactly one
// Four pixel clocks of matched glyph/base RGB/DE latency. No scaled 5x7 text.
// REGISTER_FONT retained for source compatibility; both values are synchronous.
module score_ui_renderer #(
    parameter REGISTER_FONT=1,
    parameter integer LISS_CLEAR_CYCLES=17500 // 0.5ms per column @35MHz; 48ms persistence
) (
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [31:0] pressed,
    input  wire [23:0] guide,
    input  wire [55:0] score_notes,
    input  wire [31:0] score_lengths,
    input  wire [2:0]  active_slot,
    input  wire [7:0]  page_index,
    input  wire [6:0]  progress,
    input  wire        playing,
    input  wire [1:0]  timbre,
    input  wire [7:0]  bpm,
    input  wire [6:0]  expression,
    input  wire [4:0]  volume_step,
    input  wire        volume_edit,
    input  wire [1:0]  practice_mode,
    input  wire        backing_enabled,
    input  wire [6:0]  target_note,
    input  wire [7:0]  guide_hits,guide_errors,
    input  wire        guide_completed,guide_unsupported,guide_wrong,
    input  wire [1:0]  upper_guide,
    input  wire        demo_mode,
    input  wire [2:0]  ui_mode,
    input  wire [1:0]  instrument,
    input  wire        imported_score,
    input  wire [2:0]  song_id,
    input  wire [2:0]  input_online,
    // ---- 音游 HUD（B3）：由 rhythm_judge 经顶层直接送入，均为 pixel_clk 域 ----
    input  wire        game_enable,        // 1=音游模式开，HUD 才画
    input  wire [1:0]  game_judge,         // 1=PERFECT 2=GOOD 3=MISS（0=无）
    input  wire [5:0]  game_judge_hold,    // >0 时判定弹窗 + 命中闪光可见
    input  wire [7:0]  game_combo,
    input  wire [7:0]  game_best_combo,
    input  wire [31:0] game_score_bcd,     // bin2bcd 输出，bcd[3:0]=个位
    input  wire [7:0]  game_pf,            // PERFECT 计数（饱和到 255）
    input  wire [7:0]  game_gd,            // GOOD 计数
    input  wire [7:0]  game_ms,            // MISS 计数
    // 下落式音游：当前音符到判定线还剩几个 tick（来自 score_transport）
    input  wire [7:0]  ticks_left,
    // 实时波形示波器：audio_wave_scope 经 bus_snapshot_cdc 送来的 25 bit 载荷
    //   [24]    toggle  每来一个样本翻一次（逼 mailbox 判"有变化"）
    //   [23:16] level   平滑电平 0..127
    //   [15:8]  peak    峰值保持 0..127
    //   [7:0]   sample  8 bit 有符号波形样本
    input  wire [24:0] wave_mail,
    // 实时频谱（ui_mode==5）：audio_spectrum_goertzel 经 u_spec_mailbox 的
    //   14 bit 载荷 {toggle[13], bin[12:8], level[7:0]}。level 是 log2 幅度 0..63。
    input  wire [13:0] spec_mail,
    // 双通道李萨如（ui_mode==6）：audio_lissajous_scope 经 u_liss_mailbox 的
    //   16 bit 载荷 {toggle[15], quiet[14], x[13:7], y[6:0]}。
    input  wire [15:0] liss_mail,
    // 现场验证状态：与按键同在 pixel_clk 域，直接显示，无需跨域。
    input wire showcase_active,showcase_hold,
    input wire [4:0] showcase_stage,
    input  wire [1:0]  fx_mode,
    input  wire [2:0]  test_sel,
    input  wire        pixel_clk,
    input  wire        reset_n,
    output wire        display_de,
    output reg  [17:0] rgb666
);
    // Each channel occupies six bits: {R[5:0], G[5:0], B[5:0]}.
    localparam [17:0] C_BG         = {6'd7,  6'd8,  6'd9};
    localparam [17:0] C_PANEL      = {6'd10, 6'd11, 6'd12};
    localparam [17:0] C_EDGE       = {6'd18, 6'd19, 6'd20};
    localparam [17:0] C_PAPER      = {6'd59, 6'd58, 6'd54};
    localparam [17:0] C_INK        = {6'd8,  6'd9,  6'd10};
    localparam [17:0] C_STAFF      = {6'd32, 6'd32, 6'd30};
    localparam [17:0] C_MUTED      = {6'd35, 6'd35, 6'd32};
    localparam [17:0] C_TEAL       = {6'd22, 6'd39, 6'd36};
    localparam [17:0] C_TEAL_PALE  = {6'd48, 6'd53, 6'd48};
    // Historical constant names retained for test readers. CORAL is now a
    // single functional warm orange; GOLD is its lighter matching-input tint.
    localparam [17:0] C_CORAL      = {6'd61, 6'd36, 6'd16};
    localparam [17:0] C_GOLD       = {6'd61, 6'd43, 6'd25};
    localparam [17:0] C_GUIDE_PALE = {6'd61, 6'd52, 6'd42};
    localparam [17:0] C_WHITE      = {6'd59, 6'd58, 6'd54};
    localparam [17:0] C_BLACK      = {6'd7,  6'd8,  6'd9};
    // 音游 MISS 专用红。中国股市习惯红涨绿跌，但这里是"失误"语义，
    // 用低饱和暖红，和 C_CORAL(橙) 拉开层次，不至于误读成"上涨"。
    localparam [17:0] C_RED        = {6'd55, 6'd16, 6'd16};
    // ---- 实时波形示波器（ui_mode==4）专用配色：深色底 + 亮色波形 ----
    // 深色示波底是为了和纸色主面板拉开层次，拍视频时对比度足够。
    localparam [17:0] C_SCOPE_BG   = {6'd5,  6'd7,  6'd11};
    localparam [17:0] C_SCOPE_GRID = {6'd14, 6'd18, 6'd26};
    localparam [17:0] C_SCOPE_MID  = {6'd24, 6'd30, 6'd40};
    // 三档幅度配色：低幅青 / 中幅金 / 高幅橙红，和"过载"语义对上
    localparam [17:0] C_W1         = {6'd18, 6'd54, 6'd50};
    localparam [17:0] C_W1F        = {6'd8,  6'd20, 6'd20};
    localparam [17:0] C_W2         = {6'd58, 6'd46, 6'd16};
    localparam [17:0] C_W2F        = {6'd24, 6'd19, 6'd9};
    localparam [17:0] C_W3         = {6'd61, 6'd22, 6'd13};
    localparam [17:0] C_W3F        = {6'd26, 6'd10, 6'd7};
    // 判定色：PERFECT 金 / GOOD 青 / MISS 红。做成 wire 避免在
    // always @* 里因分支不全而推断出锁存器。
    wire [17:0] C_JUDGE = (game_judge == 2'd1) ? C_GOLD :
                          (game_judge == 2'd2) ? C_TEAL : C_RED;

    integer i;
    integer j;
    integer nx;
    integer ny;
    integer dx;
    integer dy;
    integer key_left;
    integer key_bit;
    integer black_left;
    integer fill_width;
    integer pad_col;
    integer pad_top;
    integer midi_number;
    wire [7:0] volume_percent={3'd0,volume_step}*8'd5;
    reg [255:0] showcase_label;
    always @* begin
        case(showcase_stage)
            5'd0: showcase_label="TEST INPUT 01 WELCOME           ";
            5'd1: showcase_label="TEST INPUT 02 EXPRESSION        ";
            5'd2: showcase_label="TEST INPUT 03 NOTE SELECT       ";
            5'd3: showcase_label="TEST INPUT 04 FOUR VOICES       ";
            5'd4: showcase_label="TEST INPUT 05 KEYS              ";
            5'd5: showcase_label="TEST INPUT 06 PLUCK             ";
            5'd6: showcase_label="TEST INPUT 07 WIND              ";
            5'd7: showcase_label="TEST INPUT 08 SYNTH             ";
            5'd8: showcase_label="TEST INPUT 09 FX BYPASS         ";
            5'd9: showcase_label="TEST INPUT 10 FX ECHO           ";
            5'd10: showcase_label="TEST INPUT 11 FX CHORUS         ";
            5'd11: showcase_label="TEST INPUT 12 FX REVERB         ";
            5'd12: showcase_label="TEST INPUT 13 GLIDE             ";
            5'd13: showcase_label="TEST INPUT 14 VIBRATO           ";
            5'd14: showcase_label="TEST INPUT 15 TEST 04           ";
            5'd15: showcase_label="TEST INPUT 16 TEST 08           ";
            5'd16: showcase_label="TEST INPUT 17 TEST 16           ";
            5'd17: showcase_label="TEST INPUT 18 TEST 32           ";
            5'd18: showcase_label="TEST INPUT 19 WAVE              ";
            5'd19: showcase_label="TEST INPUT 20 SPECTRUM          ";
            5'd20: showcase_label="TEST INPUT 21 LISSAJOUS         ";
            5'd21: showcase_label="TEST INPUT 22 SCORE GUIDE       ";
            5'd22: showcase_label="TEST INPUT 23 SONG LIBRARY      ";
            5'd23: showcase_label="TEST INPUT 24 UART LOOPBACK     ";
            5'd24: showcase_label="TEST INPUT 25 IMPORTED SCORE    ";
            5'd25: showcase_label="TEST INPUT 26 PHONE UART        ";
            default: showcase_label="TEST INPUT                      ";
        endcase
    end

    wire [255:0] fx_status_text = (fx_mode==2'd0) ? "FX:OFF " :
                                  (fx_mode==2'd1) ? "FX:ECHO" :
                                  (fx_mode==2'd2) ? "FX:CHOR" : "FX:VERB";
    wire [255:0] test_status_text = (test_sel==3'd0) ? "TEST:OFF" :
                                    (test_sel==3'd1) ? "TEST:04 " :
                                    (test_sel==3'd2) ? "TEST:08 " :
                                    (test_sel==3'd3) ? "TEST:16 " : "TEST:32 ";
    wire practice_active=(practice_mode!=0 && !demo_mode);
    wire practice_stage=(ui_mode==1 && practice_active);
    wire [2:0] next_slot=active_slot+3'd1;
    wire [6:0] next_note=score_notes[next_slot*7 +:7];
    reg [6:0] note;
    reg [3:0] duration;
    reg [17:0] key_color;
    reg is_current;
    reg is_rest;
    reg pad_layout;
    reg [7:0] pressed_count;
    reg [6:0] lowest_note;
    reg note_found;
    reg grid_v;

    // ===================================================================
    //  实时波形示波器（ui_mode==4）—— 内部状态与流水级
    // -------------------------------------------------------------------
    //  设计要点（队友那版踩过的坑，这里逐条避开）：
    //   1) 波形缓冲放在 **pixel_clk 域**，只让 25 bit 的窄载荷跨时钟。
    //      队友直接把 520 bit 的快照总线一次跨过去，实测炸出 768 个
    //      setup / 345 个 hold 违例。这里跨的是 25 bit，而且走的是工程里
    //      已经有 SDC 约束的 bus_snapshot_cdc 同构握手。
    //   2) 存储器读只用一个变量索引，且放在**时序**块里（FF→FF），
    //      绝不进逐像素组合路径——逐像素路径一旦挂上 180:1 的 mux，
    //      之前做下落音符时 Fmax 就从 35.5 掉到 35.179 MHz，只剩 0.5% 余量。
    //   3) 列宽取 4px → 列号 = (x-40)>>2，纯移位，不需要除法器。
    // ===================================================================
    localparam [7:0]  WAVE_N    = 8'd180;   // 列数（180 × 4px = 720px）
    localparam [11:0] WAVE_L    = 12'd40;   // 波形区左边界
    localparam [11:0] WAVE_R    = 12'd760;  // 波形区右边界
    localparam [8:0]  WAVE_MID  = 9'd200;   // 中线 y

    reg [7:0] scope_buf [0:179];
    reg       wave_toggle_q;
    reg [7:0] view_peak_q, view_level_q;
    reg [7:0] peak_pct_q, level_pct_q;
    integer   wv_i;

    // 列坐标提前两拍算：wx1 = (x+2) - 40；读样本和坐标各一拍，右移 2 得列号
    wire [11:0] wx1    = x - 12'd38;
    wire [7:0]  wcol   = (wx1[11:2] >= WAVE_N) ? (WAVE_N - 8'd1) : wx1[11:2];
    wire [7:0]  wcol_n = (wcol >= WAVE_N - 8'd1) ? (WAVE_N - 8'd1) : (wcol + 8'd1);

    reg [7:0]  sa_q, sb_q;                 // 当前列 / 下一列样本
    reg [8:0]  ya_q, yb_q;                 // 对应 y 坐标
    reg [17:0] wfill_q, wline_q;           // 填充色 / 描边色

    // Display-only zoom: raw peak/level readouts and audio output are unchanged.
    wire [2:0] wave_zoom = view_peak_q<8 ? 3'd4 : view_peak_q<16 ? 3'd3 :
                           view_peak_q<32 ? 3'd2 : view_peak_q<64 ? 3'd1 : 3'd0;
    wire [255:0] wave_zoom_text = wave_zoom==4 ? "VIEW X16" : wave_zoom==3 ? "VIEW X08" :
                                  wave_zoom==2 ? "VIEW X04" : wave_zoom==1 ? "VIEW X02" : "VIEW X01";
    function automatic [7:0] zoom_wave;
        input [7:0] value;
        input [2:0] gain_shift;
        reg signed [12:0] scaled;
        begin
            scaled=$signed({{5{value[7]}},value}) <<< gain_shift;
            zoom_wave=scaled>127 ? 8'd127 : scaled < -128 ? 8'h80 : scaled[7:0];
        end
    endfunction

    // 8 bit 有符号样本 → y 坐标。缩放系数 0.75（128 → 96px），
    // 中心 200，满刻度落在 y 104..296，正好卡在面板 88..312 内。
    // 全程只有移位加减，没有乘法器。
    function automatic [8:0] wave_y_of;
        input [7:0] s;
        integer v, yv;
        begin
            v = (s < 128) ? s : (s - 256);          // -128..127
            if (v >= 0) v = (v >> 1) + (v >> 2);    // ×0.75
            else        v = -((((-v) >> 1) + ((-v) >> 2)));
            yv = 200 - v;
            if (yv < 0)   yv = 0;
            if (yv > 479) yv = 479;
            wave_y_of = yv[8:0];
        end
    endfunction
    // 幅度分档：>96 橙红（接近满刻度）/ >64 金 / 其余青
    function automatic [17:0] wave_line_of;
        input [7:0] s;
        reg [7:0] amp;
        begin
            amp = s[7] ? ((~s) + 8'd1) : s;
            if (amp > 7'd96)      wave_line_of = C_W3;
            else if (amp > 7'd64) wave_line_of = C_W2;
            else                  wave_line_of = C_W1;
        end
    endfunction
    function automatic [17:0] wave_fill_of;
        input [7:0] s;
        reg [7:0] amp;
        begin
            amp = s[7] ? ((~s) + 8'd1) : s;
            if (amp > 7'd96)      wave_fill_of = C_W3F;
            else if (amp > 7'd64) wave_fill_of = C_W2F;
            else                  wave_fill_of = C_W1F;
        end
    endfunction

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            wave_toggle_q <= 1'b0;
            view_peak_q   <= 8'd0;
            view_level_q  <= 8'd0;
            peak_pct_q    <= 8'd0;
            level_pct_q   <= 8'd0;
            sa_q <= 8'd0; sb_q <= 8'd0;
            ya_q <= WAVE_MID; yb_q <= WAVE_MID;
            wfill_q <= C_W1F; wline_q <= C_W1;
            for (wv_i = 0; wv_i < 180; wv_i = wv_i + 1) scope_buf[wv_i] <= 8'd0;
        end else begin
            // mailbox 载荷变化 → 收到一个新样本：整体左移一格，新样本进最右
            if (wave_mail[24] != wave_toggle_q) begin
                wave_toggle_q <= wave_mail[24];
                view_peak_q   <= wave_mail[15:8];
                view_level_q  <= wave_mail[23:16];
                // 百分比读数：peak*100/128 = peak*25/32。
                // 必须用本域已寄存的 view_*_q，不能直接把 mailbox 载荷接进乘法器：
                // 综合器曾把 payload 直跨 50/35 MHz 吸进 DSP，造成 4 个 hold 违例。
                // 改成移位加法后只走 pixel_clk 的 FF->LUT->FF；读数比新样本晚
                // 一个 3 kHz 样本（333 us），对肉眼显示没有影响。
                peak_pct_q    <= (({8'd0, view_peak_q} << 4) +
                                  ({8'd0, view_peak_q} << 3) +
                                   {8'd0, view_peak_q}) >> 5;
                level_pct_q   <= (({8'd0, view_level_q} << 4) +
                                  ({8'd0, view_level_q} << 3) +
                                   {8'd0, view_level_q}) >> 5;
                for (wv_i = 0; wv_i < 179; wv_i = wv_i + 1)
                    scope_buf[wv_i] <= scope_buf[wv_i + 1];
                scope_buf[179] <= wave_mail[7:0];
            end
            // 列流水级：存储器同步读 → 下一拍算 y 与配色，全部 FF→FF
            sa_q    <= scope_buf[wcol];
            sb_q    <= scope_buf[wcol_n];
            ya_q    <= wave_y_of(zoom_wave(sa_q,wave_zoom));
            yb_q    <= wave_y_of(zoom_wave(sb_q,wave_zoom));
            wfill_q <= wave_fill_of(sa_q);
            wline_q <= wave_line_of(sa_q);
        end
    end

    // 峰值保持包络：与波形同一把尺子（×0.75），上下各一条线
    wire [7:0] view_peak_zoom = view_peak_q << wave_zoom;
    wire [8:0] pk_off = ({1'b0,view_peak_zoom}>>1)+({1'b0,view_peak_zoom}>>2);
    wire [8:0] wave_pk_top = WAVE_MID - pk_off;
    wire [8:0] wave_pk_bot = WAVE_MID + pk_off;
    // 波形几何：填充区 = 中线到轨迹；描边 = 相邻两列之间的连线（保证不断线）
    wire [8:0] wave_hi  = (ya_q < yb_q) ? ya_q : yb_q;
    wire [8:0] wave_lo  = (ya_q < yb_q) ? yb_q : ya_q;
    wire [8:0] wave_top = (WAVE_MID < wave_hi) ? WAVE_MID : wave_hi;
    wire [8:0] wave_bot = (WAVE_MID > wave_lo) ? WAVE_MID : wave_lo;

    // ===================================================================
    //  实时频谱（ui_mode==5）—— 32 根对数幅度柱
    // -------------------------------------------------------------------
    //  与波形页完全同构：载荷只跨 14 bit（{toggle, bin, level}），
    //  32 bin × 8 bit 的幅度与峰值都放在 pixel_clk 域的寄存器平面里。
    //  峰值按 ~0.24 s 一格缓慢回落，既能看到"曾经到过"，又不会永远挂着。
    //  列号用 (x+1) 提前一拍对齐寄存级，与波形的 wcol 同法。
    // ===================================================================
    reg [255:0] spec_flat;      // 32 bin × 8 bit 当前对数幅度
    reg [255:0] spec_peak_flat; // 32 bin × 8 bit 峰值保持
    reg         spec_toggle_q;
    reg [22:0]  spec_decay_cnt; // 峰值衰减节拍：2^23 / 35MHz ≈ 0.24 s
    reg [7:0]   bar_level_q, bar_peak_q;
    integer     sb_i;

    wire [11:0] sx1  = x - 12'd47;                  // (x+1) - 48，提前一拍
    wire [7:0]  sraw = sx1[11:4];                   // 列号（越界时极大，自然钳到 31）
    wire [4:0]  scol = (sraw >= 8'd32) ? 5'd31 : sraw[4:0];

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            spec_flat      <= 256'd0;
            spec_peak_flat <= 256'd0;
            spec_toggle_q  <= 1'b0;
            spec_decay_cnt <= 23'd0;
            bar_level_q    <= 8'd0;
            bar_peak_q     <= 8'd0;
        end else begin
            // 新频点：载荷的 toggle 位翻转才收（同一份数据不重写）
            if (spec_mail[13] != spec_toggle_q) begin
                spec_toggle_q <= spec_mail[13];
                spec_flat[spec_mail[12:8]*8 +: 8] <= spec_mail[7:0];
                if (spec_mail[7:0] > spec_peak_flat[spec_mail[12:8]*8 +: 8])
                    spec_peak_flat[spec_mail[12:8]*8 +: 8] <= spec_mail[7:0];
            end
            // 峰值缓慢回落：2^23 拍（≈0.24 s）全体 -1
            spec_decay_cnt <= spec_decay_cnt + 23'd1;
            if (&spec_decay_cnt) begin
                for (sb_i = 0; sb_i < 32; sb_i = sb_i + 1)
                    if (spec_peak_flat[sb_i*8 +: 8] != 8'd0)
                        spec_peak_flat[sb_i*8 +: 8] <= spec_peak_flat[sb_i*8 +: 8] - 8'd1;
            end
            // 列流水级：FF->mux->FF，不进逐像素组合路径
            bar_level_q <= spec_flat[scol*8 +: 8];
            bar_peak_q  <= spec_peak_flat[scol*8 +: 8];
        end
    end

    // 柱高 = level*3（0..189px，面板 104..296 共 192px，留 3px 底线）
    wire [8:0] bar_h    = ({1'b0, bar_level_q} << 1) + {1'b0, bar_level_q};
    wire [8:0] bar_top  = (bar_h > 9'd188) ? 9'd108 : (9'd296 - bar_h);
    wire [8:0] peak_top = (bar_peak_q > 8'd62) ? 9'd108 :
                          (9'd296 - (({1'b0, bar_peak_q} << 1) + {1'b0, bar_peak_q}));
    // 与波形页同一档配色规则：低幅青 / 中幅金 / 高幅橙红
    wire [17:0] bar_color  = (bar_level_q > 8'd42) ? C_W3 :
                             (bar_level_q > 8'd26) ? C_W2 : C_W1;
    wire [17:0] bar_colorf = (bar_level_q > 8'd42) ? C_W3F :
                             (bar_level_q > 8'd26) ? C_W2F : C_W1F;

    // ===================================================================
    //  双通道李萨如（ui_mode==6）—— 96×96 光栅位图
    // -------------------------------------------------------------------
    //  位图放在 pixel_clk 域（和波形缓冲同理）：写侧只收 mailbox 的
    //  16 bit 窄载荷，每点 = 清一列（余辉）+ 打一个点。
    //  独立像素时钟每 0.5 ms 擦除一列 → 全图约 48 ms，
    //  稳态保留最多约 576 个点，接近示波器的短余辉。
    //  96×96 = 9216 个 FF，强制 syn_ramstyle="registers"，
    //  绝不进 BSRAM（本就 339/340 满载）。
    // ===================================================================
    (* syn_ramstyle="registers" *) reg [95:0] liss_col [0:95];
    reg        liss_toggle_q;
    reg [6:0]  liss_clr_ptr;
    reg [14:0] liss_clr_count;
    wire liss_clear = liss_clr_count == LISS_CLEAR_CYCLES-1;
    reg [95:0] liss_word_q;
    integer    lc_i;

    wire [11:0] lx1  = x - 12'd207;                 // (x+1) - 208，提前一拍
    wire [9:0]  lraw = lx1[11:2];                   // 列号（越界时极大，钳到 95）
    wire [6:0]  lcol = (lraw >= 10'd96) ? 7'd95 : lraw[6:0];
    wire [95:0] liss_onehot = 96'd1 << liss_mail[6:0];

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            for (lc_i = 0; lc_i < 96; lc_i = lc_i + 1) liss_col[lc_i] <= 96'd0;
            liss_toggle_q <= 1'b0;
            liss_clr_ptr  <= 7'd0;
            liss_clr_count <= 15'd0;
            liss_word_q   <= 96'd0;
        end else begin
            // Clock-driven decay also clears the trace when the audio frontend stops.
            liss_clr_count <= liss_clear ? 15'd0 : liss_clr_count + 15'd1;
            if (liss_clear) begin
                liss_col[liss_clr_ptr] <= 96'd0;
                liss_clr_ptr <= (liss_clr_ptr == 7'd95) ? 7'd0 : liss_clr_ptr + 7'd1;
            end
            if (liss_mail[15] != liss_toggle_q) begin
                liss_toggle_q <= liss_mail[15];
                for (lc_i = 0; lc_i < 96; lc_i = lc_i + 1)
                    if (lc_i[6:0] == liss_mail[13:7] && liss_mail[6:0]<96)
                        liss_col[lc_i] <= ((liss_clear && liss_clr_ptr==lc_i) ?
                            96'd0 : liss_col[lc_i]) | liss_onehot;
            end
            // 行读出流水级：FF->mux->FF（96:1 的 96 位 mux 放在寄存级）
            liss_word_q <= liss_col[lcol];
        end
    end

    // 行号用当前 y（同一扫描行内不变，不需要提前补偿）
    wire [6:0] lrow = (y - 12'd104) >> 1;
    wire       liss_pix = liss_word_q[lrow];

    // A registered balanced painter tree preserves LAST-valid-wins exactly.
    // Stage 1: local primitives and three mux levels per 8-leaf group.
    // Stage 2: balanced group reduction; Unicode/coordinates/color become FFs.
    // Stage 3: Unicode-to-ROM-address decode becomes a separate address FF.
    // Stage 4: synchronous BSRAM row read, matching base/color/gx/DE delays.
    // The display core adds its existing output FF: total panel latency = 5.
    // 叶子数 = 2 的幂会让二叉归约树最平衡；TEXT_LEAVES 从 256 提到 320 是
    // 为了给音游 HUD 留 64 个文字叶子。归约树是参数化的，多一层 2 选 1
    // 只多约 1 ns 组合延时，35 MHz 下余量充足（几何树本来就是 512 叶）。
    localparam GEOMETRY_LEAVES=512, TEXT_LEAVES=320;
    reg [18:0] geometry_leaf[0:GEOMETRY_LEAVES-1];
    reg [44:0] text_leaf[0:TEXT_LEAVES-1];
    wire [18:0] geometry_tree[1:2*GEOMETRY_LEAVES-1];
    wire [44:0] text_tree[1:2*TEXT_LEAVES-1];
    reg [18:0] geometry_group_q[0:GEOMETRY_LEAVES/8-1];
    reg [44:0] text_group_q[0:TEXT_LEAVES/8-1];
    integer clear_slot;
    function automatic [18:0] choose_geometry;
        input [18:0] low,high;
        begin choose_geometry=high[18] ? high : low; end
    endfunction
    function automatic [44:0] choose_text;
        input [44:0] low,high;
        begin choose_text=high[44] ? high : low; end
    endfunction
    genvar painter_node;
    generate for(painter_node=1;painter_node<2*GEOMETRY_LEAVES;painter_node=painter_node+1) begin: gtree
        if(painter_node>=GEOMETRY_LEAVES)
            assign geometry_tree[painter_node]=geometry_leaf[painter_node-GEOMETRY_LEAVES];
        else if(painter_node>=GEOMETRY_LEAVES/8 && painter_node<GEOMETRY_LEAVES/4) begin
            always @(posedge pixel_clk or negedge reset_n)
                if(!reset_n)geometry_group_q[painter_node-GEOMETRY_LEAVES/8]<=0;
                else geometry_group_q[painter_node-GEOMETRY_LEAVES/8]<=
                    choose_geometry(geometry_tree[painter_node*2],geometry_tree[painter_node*2+1]);
            assign geometry_tree[painter_node]=geometry_group_q[painter_node-GEOMETRY_LEAVES/8];
        end else assign geometry_tree[painter_node]=
            choose_geometry(geometry_tree[painter_node*2],geometry_tree[painter_node*2+1]);
    end
    for(painter_node=1;painter_node<2*TEXT_LEAVES;painter_node=painter_node+1) begin: ttree
        if(painter_node>=TEXT_LEAVES)
            assign text_tree[painter_node]=text_leaf[painter_node-TEXT_LEAVES];
        else if(painter_node>=TEXT_LEAVES/8 && painter_node<TEXT_LEAVES/4) begin
            always @(posedge pixel_clk or negedge reset_n)
                if(!reset_n)text_group_q[painter_node-TEXT_LEAVES/8]<=0;
                else text_group_q[painter_node-TEXT_LEAVES/8]<=
                    choose_text(text_tree[painter_node*2],text_tree[painter_node*2+1]);
            assign text_tree[painter_node]=text_group_q[painter_node-TEXT_LEAVES/8];
        end else assign text_tree[painter_node]=
            choose_text(text_tree[painter_node*2],text_tree[painter_node*2+1]);
    end endgenerate
    reg [3:0] de_pipe;
    reg [17:0] base_rgb_s2,base_rgb_s3,base_rgb_q,color_s2,color_s3,color_q;
    reg [15:0] char_s2;
    reg [4:0] gx_s2,gx_s3,gx_q,gy_s2;
    reg valid_s2,valid_s3,valid_q;
    wire [39:0] row_alpha;
    reg [1:0] coverage;
    ui_text_font #(.ADDRESS_PIPELINE(1)) text_font(.clk(pixel_clk),.char_code(char_s2),
                                                .row(gy_s2),.row_alpha(row_alpha));
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin
            de_pipe<=0;base_rgb_s2<=0;base_rgb_s3<=0;base_rgb_q<=0;
            char_s2<=0;gx_s2<=0;gx_s3<=0;gx_q<=0;gy_s2<=0;
            color_s2<=0;color_s3<=0;color_q<=0;valid_s2<=0;valid_s3<=0;valid_q<=0;
        end else begin
            de_pipe<={de_pipe[2:0],de && x<800 && y<480};
            base_rgb_s2<=geometry_tree[1][17:0];
            {valid_s2,char_s2,gx_s2,gy_s2,color_s2}<=text_tree[1];
            base_rgb_s3<=base_rgb_s2;base_rgb_q<=base_rgb_s3;
            gx_s3<=gx_s2;gx_q<=gx_s3;
            color_s3<=color_s2;color_q<=color_s3;
            valid_s3<=valid_s2;valid_q<=valid_s3;
        end
    end
    assign display_de=de_pipe[3];
    // Combinational *pre-pipeline* bundle remains available to independent
    // regression benches.  Never connected to the physical output path.
    wire [18:0] geometry_oracle_tree[1:2*GEOMETRY_LEAVES-1];
    wire [44:0] text_oracle_tree[1:2*TEXT_LEAVES-1];
    generate for(painter_node=1;painter_node<2*GEOMETRY_LEAVES;painter_node=painter_node+1) begin: goracle
        if(painter_node>=GEOMETRY_LEAVES)assign geometry_oracle_tree[painter_node]=geometry_leaf[painter_node-GEOMETRY_LEAVES];
        else assign geometry_oracle_tree[painter_node]=choose_geometry(geometry_oracle_tree[painter_node*2],geometry_oracle_tree[painter_node*2+1]);
    end
    for(painter_node=1;painter_node<2*TEXT_LEAVES;painter_node=painter_node+1) begin: toracle
        if(painter_node>=TEXT_LEAVES)assign text_oracle_tree[painter_node]=text_leaf[painter_node-TEXT_LEAVES];
        else assign text_oracle_tree[painter_node]=choose_text(text_oracle_tree[painter_node*2],text_oracle_tree[painter_node*2+1]);
    end endgenerate
    wire [17:0] geometry_base_rgb=geometry_oracle_tree[1][17:0];
    wire [15:0] text_char=text_oracle_tree[1][43:28];
    wire [4:0] text_gx=text_oracle_tree[1][27:23],text_gy=text_oracle_tree[1][22:18];
    wire [17:0] text_color=text_oracle_tree[1][17:0];
    wire text_valid=text_oracle_tree[1][44] && de && x<800 && y<480;

    // 8-bit numerator, constant divisor. One narrow blend per color channel.
    function automatic [5:0] blend6;
        input [5:0] bg,fg;
        input [1:0] alpha;
        reg [7:0] numerator;
        begin
            numerator=0;
            case(alpha)
                0:blend6=bg;
                3:blend6=fg;
                1:begin numerator=({2'b0,bg}<<1)+{2'b0,fg}+8'd1;blend6=numerator/8'd3;end
                default:begin numerator={2'b0,bg}+({2'b0,fg}<<1)+8'd1;blend6=numerator/8'd3;end
            endcase
        end
    endfunction

    // All labels select the same real-font address and coordinates.
    // ASCII is native Consolas 14px,10px advance; CJK YaHei18px,22px advance.
    function automatic [44:0] ascii_candidate;
        input integer left,top;
        input [255:0] label_text;
        input integer count;
        input [17:0] color;
        integer t,rel_x,rel_y;
        reg [44:0] candidate;
        begin
            ascii_candidate=0;
            if(y>=top && y<top+20)for(t=0;t<8;t=t+1) begin
                if(t<count && x>=left+t*10 && x<left+t*10+10)begin
                    rel_x=x-left-t*10;rel_y=y-top;
                    candidate={1'b1,8'd0,label_text[(count-1-t)*8 +:8],rel_x[4:0],rel_y[4:0],color};
                    ascii_candidate=ascii_candidate|candidate;
                end
            end
        end
    endfunction
    function automatic [44:0] ascii_candidate_long;
        input integer left,top;
        input [255:0] label_text;
        input integer count;
        input [17:0] color;
        integer t,rel_x,rel_y;
        reg [44:0] candidate;
        begin
            ascii_candidate_long=0;
            if(y>=top && y<top+20)for(t=0;t<32;t=t+1) begin
                if(t<count && x>=left+t*10 && x<left+t*10+10)begin
                    rel_x=x-left-t*10;rel_y=y-top;
                    candidate={1'b1,8'd0,label_text[(count-1-t)*8 +:8],rel_x[4:0],rel_y[4:0],color};
                    ascii_candidate_long=ascii_candidate_long|candidate;
                end
            end
        end
    endfunction
    function automatic [44:0] cjk_candidate;
        input integer left,top;
        input [511:0] label_text;
        input integer count;
        input [17:0] color;
        integer t,rel_x,rel_y;
        reg [44:0] candidate;
        begin
            cjk_candidate=0;
            if(y>=top && y<top+20)for(t=0;t<8;t=t+1) begin
                if(t<count && x>=left+t*22 && x<left+t*22+20)begin
                    rel_x=x-left-t*22;rel_y=y-top;
                    candidate={1'b1,label_text[(count-1-t)*16 +:16],rel_x[4:0],rel_y[4:0],color};
                    cjk_candidate=cjk_candidate|candidate;
                end
            end
        end
    endfunction

    // A two-times note label uses the same coverage ROM and pipeline. Only
    // coordinates are scaled; no framebuffer or second font port is needed.
    function automatic [44:0] note_candidate_large;
        input integer left,top;
        input [23:0] label_text;
        input [17:0] color;
        integer t,rel_x,rel_y;
        begin
            note_candidate_large=0;
            if(y>=top && y<top+40)for(t=0;t<3;t=t+1)begin
                if(x>=left+t*20 && x<left+t*20+20)begin
                    rel_x=(x-left-t*20)>>1;rel_y=(y-top)>>1;
                    note_candidate_large={1'b1,8'd0,label_text[(2-t)*8 +:8],
                                          rel_x[4:0],rel_y[4:0],color};
                end
            end
        end
    endfunction

    // Exactly the production pressure mapping, in sensor channel order.
    function integer pressure_pitch;
        input integer pad;
        begin case(pad)
            0:pressure_pitch=0; 1:pressure_pitch=2; 2:pressure_pitch=4; 3:pressure_pitch=5;
            4:pressure_pitch=7; 5:pressure_pitch=9; 6:pressure_pitch=11; 7:pressure_pitch=12;
            8:pressure_pitch=14; 9:pressure_pitch=16; 10:pressure_pitch=17; 11:pressure_pitch=19;
            12:pressure_pitch=21; 13:pressure_pitch=23; 14:pressure_pitch=24; default:pressure_pitch=26;
        endcase end
    endfunction

    // Sensor channel IDs 01..16, not MIDI semitones or unverified XY positions.
    function [15:0] pad_number;
        input [6:0] midi;
        begin case(midi)
            60:pad_number="01";62:pad_number="02";64:pad_number="03";65:pad_number="04";
            67:pad_number="05";69:pad_number="06";71:pad_number="07";72:pad_number="08";
            74:pad_number="09";76:pad_number="10";77:pad_number="11";79:pad_number="12";
            81:pad_number="13";83:pad_number="14";84:pad_number="15";86:pad_number="16";
            default:pad_number="--";
        endcase end
    endfunction

    // True balanced population count; no chain of 32 conditional additions.
    function automatic [2:0] population4;
        input [3:0] bits;
        reg [1:0] pair0,pair1;
        begin
            pair0={1'b0,bits[0]}+bits[1];pair1={1'b0,bits[2]}+bits[3];
            population4={1'b0,pair0}+pair1;
        end
    endfunction
    function automatic [5:0] population32;
        input [31:0] bits;
        reg [3:0] octet0,octet1,octet2,octet3;
        reg [4:0] half0,half1;
        begin
            octet0={1'b0,population4(bits[3:0])}+population4(bits[7:4]);
            octet1={1'b0,population4(bits[11:8])}+population4(bits[15:12]);
            octet2={1'b0,population4(bits[19:16])}+population4(bits[23:20]);
            octet3={1'b0,population4(bits[27:24])}+population4(bits[31:28]);
            half0={1'b0,octet0}+octet1;half1={1'b0,octet2}+octet3;
            population32={1'b0,half0}+half1;
        end
    endfunction
    // Five-level binary priority selection, rather than 32 serial overrides.
    function automatic [6:0] first_pitch;
        input [31:0] bits;
        reg [15:0] half;
        reg [7:0] octet;
        reg [3:0] nibble;
        reg [1:0] pair;
        reg [4:0] offset;
        begin
            offset[4]=!(|bits[15:0]);half=offset[4] ? bits[31:16] : bits[15:0];
            offset[3]=!(|half[7:0]);octet=offset[3] ? half[15:8] : half[7:0];
            offset[2]=!(|octet[3:0]);nibble=offset[2] ? octet[7:4] : octet[3:0];
            offset[1]=!(|nibble[1:0]);pair=offset[1] ? nibble[3:2] : nibble[1:0];
            offset[0]=!pair[0];
            first_pitch=(|bits) ? 7'd60+offset : 7'd0;
        end
    endfunction

    // BCD -> 6 位 ASCII。字节序与 ascii_candidate 一致：
    // 最高字节是最左边的字符。bcd[3:0] 为个位，所以第 k 字节放第 k 位。
    // 用加法而不是除法，综合出来只是 6 个 4 位加法器，没有除法器硬核。
    function [47:0] bcd6_ascii;
        input [31:0] b;
        integer k;
        begin
            for (k = 0; k < 6; k = k + 1)
                bcd6_ascii[8*k +: 8] = 8'd48 + b[4*k +: 4];
        end
    endfunction

    // BCD -> BCD 常量对照表结束

    function [23:0] decimal3;
        input [7:0] value;
        integer remainder;
        integer tens;
        integer digit_code;
        reg [7:0] hundreds_char;
        begin
            if (value >= 200) begin
                remainder=value-200;
                hundreds_char="2";
            end else if (value >= 100) begin
                remainder=value-100;
                hundreds_char="1";
            end else begin
                remainder=value;
                hundreds_char="0";
            end
            if      (remainder >= 90) tens=9;
            else if (remainder >= 80) tens=8;
            else if (remainder >= 70) tens=7;
            else if (remainder >= 60) tens=6;
            else if (remainder >= 50) tens=5;
            else if (remainder >= 40) tens=4;
            else if (remainder >= 30) tens=3;
            else if (remainder >= 20) tens=2;
            else if (remainder >= 10) tens=1;
            else                      tens=0;
            decimal3[23:16]=hundreds_char;
            digit_code=48+tens;
            decimal3[15:8]=digit_code[7:0];
            digit_code=48+remainder-tens*10;
            decimal3[7:0]=digit_code[7:0];
        end
    endfunction

    function integer pitch_y;
        input [6:0] midi;
        begin
            case (midi)
                48,49: pitch_y=260; 50,51: pitch_y=254;
                52: pitch_y=248; 53,54: pitch_y=242;
                55,56: pitch_y=236; 57,58: pitch_y=230;
                59: pitch_y=224;
                60,61: pitch_y=218; 62,63: pitch_y=212;
                64: pitch_y=206; 65,66: pitch_y=200;
                67,68: pitch_y=194; 69,70: pitch_y=188;
                71: pitch_y=182; 72,73: pitch_y=176;
                74,75: pitch_y=170; 76: pitch_y=164;
                77,78: pitch_y=158; 79,80: pitch_y=152;
                81,82: pitch_y=146; 83: pitch_y=140;
                84,85: pitch_y=134;86,87:pitch_y=128;
                88:pitch_y=122;89,90:pitch_y=116;
                91,92:pitch_y=110;93,94:pitch_y=104;95:pitch_y=98;
                default: pitch_y=188;
            endcase
        end
    endfunction

    function sharp_note;
        input [6:0] midi;
        begin
            case (midi)
                49,51,54,56,58,61,63,66,68,70,73,75,78,80,82,85,87,90,92,94: sharp_note=1'b1;
                default: sharp_note=1'b0;
            endcase
        end
    endfunction

    function [23:0] note_name;
        input [6:0] midi;
        reg [7:0] letter;
        reg [7:0] octave;
        begin
            case (midi)
                48,49,60,61,72,73,84,85: letter="C";
                50,51,62,63,74,75,86,87: letter="D";
                52,64,76,88: letter="E";
                53,54,65,66,77,78,89,90: letter="F";
                55,56,67,68,79,80,91,92: letter="G";
                57,58,69,70,81,82,93,94: letter="A";
                59,71,83,95: letter="B";
                default: letter="-";
            endcase
            octave=(midi >= 84) ? "6" : (midi >= 72) ? "5" : (midi >= 60) ? "4" : "3";
            if (midi < 48 || midi > 95) note_name="---";
            else if (sharp_note(midi)) note_name={letter,"#",octave};
            else note_name={letter,octave," "};
        end
    endfunction

    function [15:0] solfege;
        input [6:0] midi;
        begin
            case (midi)
                60,61,72,73: solfege="DO";
                62,63,74,75: solfege="RE";
                64,76: solfege="MI";
                65,66,77,78: solfege="FA";
                67,68,79,80: solfege="SO";
                69,70,81,82: solfege="LA";
                71,83: solfege="TI";
                default: solfege="--";
            endcase
        end
    endfunction

    // Names follow timbre_fsr16_v4/rom/timbre_manifest.json, bank order
    // family*3+preset. These are harmonic synth approximations, not samples.
    function [31:0] cjk_family_name;
        input [1:0] family;
        begin
            case (family)
                1: cjk_family_name=32'h62E85F26;
                2: cjk_family_name=32'h7BA14E50;
                3: cjk_family_name=32'h54086210;
                default: cjk_family_name=32'h952E76D8;
            endcase
        end
    endfunction

    function [47:0] cjk_preset_name;
        input [1:0] family;
        input [1:0] slot;
        begin
            case (family)
                1: case (slot)
                    1: cjk_preset_name=48'h000067D462E8;
                    2: cjk_preset_name=48'h00004EAE62E8;
                    default: cjk_preset_name=48'h0000672862E8;
                endcase
                2: case (slot)
                    1: cjk_preset_name=48'h00007C27611F;
                    2: cjk_preset_name=48'h570653F7611F;
                    default: cjk_preset_name=48'h00007B1B611F;
                endcase
                3: case (slot)
                    1: cjk_preset_name=48'h91D15C5E611F;
                    2: cjk_preset_name=48'h810951B2611F;
                    default: cjk_preset_name=48'h0000669657AB;
                endcase
                default: case (slot)
                    1: cjk_preset_name=48'h660E4EAE952E;
                    2: cjk_preset_name=48'h00007535952E;
                    default: cjk_preset_name=48'h000067D4952E;
                endcase
            endcase
        end
    endfunction

    function [1:0] cjk_preset_length;
        input [1:0] family;
        input [1:0] slot;
        begin
            if((family==0 && slot==1) || (family==2 && slot==2) ||
               (family==3 && (slot==1 || slot==2)))cjk_preset_length=3;
            else cjk_preset_length=2;
        end
    endfunction

    function integer white_pitch;
        input integer k;
        begin
            case (k)
                0:white_pitch=0; 1:white_pitch=2; 2:white_pitch=4;
                3:white_pitch=5; 4:white_pitch=7; 5:white_pitch=9;
                6:white_pitch=11; 7:white_pitch=12; 8:white_pitch=14;
                9:white_pitch=16; 10:white_pitch=17; 11:white_pitch=19;
                12:white_pitch=21; 13:white_pitch=23;
                default:white_pitch=0;
            endcase
        end
    endfunction

    function integer black_pitch;
        input integer k;
        begin
            case (k)
                0:black_pitch=1; 1:black_pitch=3; 2:black_pitch=6;
                3:black_pitch=8; 4:black_pitch=10; 5:black_pitch=13;
                6:black_pitch=15; 7:black_pitch=18; 8:black_pitch=20;
                9:black_pitch=22; default:black_pitch=1;
            endcase
        end
    endfunction

    function integer black_boundary;
        input integer k;
        begin
            case (k)
                0:black_boundary=1; 1:black_boundary=2;
                2:black_boundary=4; 3:black_boundary=5;
                4:black_boundary=6; 5:black_boundary=8;
                6:black_boundary=9; 7:black_boundary=11;
                8:black_boundary=12; 9:black_boundary=13;
                default:black_boundary=1;
            endcase
        end
    endfunction

    // A tiny vector treble clef, encoded as 19 pixels x 44 scanlines. It is
    // rendered at 2x scale, not stored as a screen-sized bitmap/framebuffer.
    function [18:0] clef_row;
        input [5:0] row;
        begin
            case (row)
                 0:clef_row=19'b0000000000110000000;
                 1:clef_row=19'b0000000001111000000;
                 2:clef_row=19'b0000000011001100000;
                 3:clef_row=19'b0000000110000110000;
                 4:clef_row=19'b0000000110000110000;
                 5:clef_row=19'b0000001100000110000;
                 6:clef_row=19'b0000001100000110000;
                 7:clef_row=19'b0000001100001100000;
                 8:clef_row=19'b0000001100011000000;
                 9:clef_row=19'b0000001100110000000;
                10:clef_row=19'b0000001101100000000;
                11:clef_row=19'b0000001111000000000;
                12:clef_row=19'b0000011110000000000;
                13:clef_row=19'b0000111100000000000;
                14:clef_row=19'b0001111000000000000;
                15:clef_row=19'b0011011000000000000;
                16:clef_row=19'b0110011000000000000;
                17:clef_row=19'b0110011000000000000;
                18:clef_row=19'b1100011000000000000;
                19:clef_row=19'b1100011000000000000;
                20:clef_row=19'b1100011111100000000;
                21:clef_row=19'b1100111111110000000;
                22:clef_row=19'b1101101000011000000;
                23:clef_row=19'b1111001000001100000;
                24:clef_row=19'b1110001000001100000;
                25:clef_row=19'b1100001000001100000;
                26:clef_row=19'b1100001000001100000;
                27:clef_row=19'b1100001100011000000;
                28:clef_row=19'b0110001100110000000;
                29:clef_row=19'b0111001111100000000;
                30:clef_row=19'b0011111111000000000;
                31:clef_row=19'b0001111110000000000;
                32:clef_row=19'b0000001100000000000;
                33:clef_row=19'b0000001100000000000;
                34:clef_row=19'b0000001100000000000;
                35:clef_row=19'b0000001100000000000;
                36:clef_row=19'b0000001100000000000;
                37:clef_row=19'b0000001100000000000;
                38:clef_row=19'b0000001100000000000;
                39:clef_row=19'b0000001100000000000;
                40:clef_row=19'b0001111100000000000;
                41:clef_row=19'b0011111100000000000;
                42:clef_row=19'b0011111000000000000;
                43:clef_row=19'b0001110000000000000;
                default:clef_row=19'd0;
            endcase
        end
    endfunction

    reg [18:0] clef_bits;
    integer clef_col;

    // ------------------------------------------------------------------
    //  下落式音游轨道（B4）—— 音符块从上方连续落到判定线
    //
    //    横轴 = 音高（低音在左、高音在右），纵轴 = 时间（越靠上 = 越晚到）。
    //    y 由"还剩几个 tick"决定：ticks_left 是**当前音符内**的剩余 tick，
    //    更后面的音符要累加前面各音符的 length 才是它们各自的剩余 tick。
    //    有了这个累加，块才是连续下滑的，而不是每跳一个音符才跳一格。
    //
    //    轨道：x 296..770，判定线 y=300，可视区 y 96..300（每 tick 8 像素）。
    //    只在 game_enable 时算，关掉音游时不影响任何像素。
    // ------------------------------------------------------------------
    reg        fall_hit;
    reg [17:0] fall_color;

    // ---- 位置预计算：每拍算好 8 个块的 x/y，逐像素只做比较 ----
    //
    //    【为什么必须拆成两级】
    //    第一版把"累加 tick + 乘法算坐标"全放在逐像素的组合 always 里，
    //    8 次循环的加法/乘法链正好压在 pixel_clk 的关键路径上：
    //    Fmax 从 38.143 MHz 掉到 35.179 MHz，对 35 MHz 约束只剩 +0.5% 余量。
    //    而块的位置只取决于 ticks_left / active_slot / score_notes / score_lengths，
    //    每帧才变一次，**没必要每个像素都重算**。
    //    所以这里用寄存器按拍算好坐标，下面的组合逻辑只剩 8 次比较。
    reg [11:0] slot_x [0:7];
    reg [11:0] slot_y [0:7];
    integer s_i;
    reg [8:0] slot_dist [0:7];
    integer s_dist;
    integer s_note;
    integer s_bx;
    integer s_by;

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            for (s_i=0;s_i<8;s_i=s_i+1) begin
                slot_dist[s_i]<=0;slot_x[s_i]<=0;slot_y[s_i]<=0;
            end
        end else begin
            s_dist={24'd0,ticks_left};
            for (s_i=0;s_i<8;s_i=s_i+1) begin
                slot_dist[s_i]<=s_dist[8:0];
                if(s_i>=active_slot) s_dist=s_dist+{28'd0,score_lengths[s_i*4+:4]};
                s_note=score_notes[s_i*7+:7];
                s_bx=300+((s_note-60)<<4)+((s_note-60)<<1)+(s_note-60);
                if(s_bx<300)s_bx=300;
                if(s_bx>754)s_bx=754;
                s_by=300-({23'd0,slot_dist[s_i]}<<3);
                if(s_i<active_slot || s_note==0) begin slot_x[s_i]<=0;slot_y[s_i]<=0;end
                else begin
                    slot_x[s_i]<=s_bx[11:0];
                    slot_y[s_i]<=(s_by>96 && s_by<=300)?s_by[11:0]:12'd0;
                end
            end
        end
    end

    wire track_enabled = ui_mode==0 && !volume_edit && (game_enable || showcase_active);
    integer f_i;
    always @* begin
        fall_hit   = 1'b0;
        fall_color = C_TEAL;
        if (track_enabled) begin
            for (f_i = 0; f_i < 8; f_i = f_i + 1) begin
                if (slot_y[f_i] != 12'd0 &&
                    x >= slot_x[f_i] && x < slot_x[f_i] + 16 &&
                    y >= slot_y[f_i] - 12 && y < slot_y[f_i]) begin
                    fall_hit   = 1'b1;
                    fall_color = (f_i == active_slot) ? C_GOLD : C_TEAL;
                end
            end
        end
    end

    always @* begin
        for(clear_slot=0;clear_slot<512;clear_slot=clear_slot+1)
            geometry_leaf[clear_slot]=19'd0;
        for(clear_slot=0;clear_slot<320;clear_slot=clear_slot+1)
            text_leaf[clear_slot]=45'd0;
        geometry_leaf[0]={1'b1,C_BG};
        nx=0; ny=0; dx=0; dy=0; key_left=0; key_bit=0;
        black_left=0; fill_width=0; note=0; duration=0;
        key_color=C_WHITE; is_current=1'b0; is_rest=1'b0;
        clef_bits=19'd0; clef_col=0;
        pad_col=0; pad_top=0; midi_number=0;
        pad_layout=1'b0; pressed_count=8'd0;
        lowest_note=7'd0; note_found=1'b0;
        case (instrument)
            1,2,3: pad_layout=1'b1;
            default: pad_layout=1'b0;
        endcase
        // Include every live pitch; FSR16 natural notes reach C6 and D6.
        // The score guide and unchanged piano/pad layout remain 24 pitches.
        pressed_count={2'd0,population32(pressed)};
        lowest_note=first_pitch(pressed);


        // Fixed typographic hierarchy: view -> family -> preset. There is no
        // invented brand, phone status, waveform, or implied audio connection.
        if (x>=24 && x<776 && y==72) geometry_leaf[1]={1'b1,C_EDGE};
        // 七个页签（频谱/李萨如是第 6/7 页，间距收到 46px、签宽 40px，
        // 最右一个页签到 x=340，不会压到 x=358 的音色/预设标签）
        if (x>=24 && x<64 && y>=46 && y<49 && ui_mode==0) geometry_leaf[2]={1'b1,C_CORAL};
        if (x>=70 && x<110 && y>=46 && y<49 && ui_mode==1) geometry_leaf[3]={1'b1,C_CORAL};
        if (x>=116 && x<156 && y>=46 && y<49 && ui_mode==2) geometry_leaf[4]={1'b1,C_CORAL};
        if (x>=162 && x<202 && y>=46 && y<49 && ui_mode==3) geometry_leaf[5]={1'b1,C_CORAL};
        if (x>=208 && x<248 && y>=46 && y<49 && ui_mode==4) geometry_leaf[469]={1'b1,C_CORAL};
        if (x>=254 && x<294 && y>=46 && y<49 && ui_mode==5) geometry_leaf[470]={1'b1,C_CORAL};
        if (x>=300 && x<340 && y>=46 && y<49 && ui_mode==6) geometry_leaf[471]={1'b1,C_CORAL};
        text_leaf[0]=cjk_candidate(24,24,32'h66F28C31,2,ui_mode==0 ? C_WHITE : C_MUTED);
        text_leaf[1]=cjk_candidate(70,24,32'h6F14594F,2,ui_mode==1 ? C_WHITE : C_MUTED);
        text_leaf[2]=cjk_candidate(116,24,32'h97F38272,2,ui_mode==2 ? C_WHITE : C_MUTED);
        text_leaf[3]=cjk_candidate(162,24,32'h6B4C5355,2,ui_mode==3 ? C_WHITE : C_MUTED);
        // "WAVE"：字体 ROM 里没有"波形"两个汉字（生成脚本已不在仓库里，
        // 不能重生成字库），所以用 ASCII，避免打出空白方块。
        text_leaf[272]=ascii_candidate(208,24,"WAVE",4,ui_mode==4 ? C_WHITE : C_MUTED);
        text_leaf[282]=ascii_candidate(254,24,"SPEC",4,ui_mode==5 ? C_WHITE : C_MUTED);
        text_leaf[283]=ascii_candidate(300,24,"LISS",4,ui_mode==6 ? C_WHITE : C_MUTED);
        text_leaf[4]=cjk_candidate(358,16,32'h4E505668,2,C_MUTED);
        text_leaf[5]=cjk_candidate(358,40,cjk_family_name(instrument),2,C_WHITE);
        text_leaf[6]=cjk_candidate(454,16,32'h97F38272,2,C_MUTED);
        text_leaf[7]=cjk_candidate(454,40,cjk_preset_name(instrument,timbre),cjk_preset_length(instrument,timbre),C_WHITE);
        text_leaf[8]=cjk_candidate(558,16,32'h6BCF5206,2,C_MUTED);
        text_leaf[9]=ascii_candidate(558,40,decimal3(bpm),3,C_WHITE);
        // Showcase title only: keep transport, input source and playback status unchanged.
        if (showcase_active) text_leaf[10]=cjk_candidate(654,18,64'h81EA753152076362,4,demo_mode ? C_CORAL : C_TEAL);
        else if (demo_mode) text_leaf[10]=cjk_candidate(654,18,64'h81EA52A88BD5542C,4,C_CORAL);
        else if(practice_active)text_leaf[11]=cjk_candidate(654,18,
            practice_mode==2 ? 64'h901097F37EC34E60 : 64'h5B9A65F68DDF8C31,4,C_TEAL);
        else text_leaf[11]=cjk_candidate(654,18,64'h89E664786F14594F,4,C_TEAL);
        if (demo_mode) text_leaf[12]=cjk_candidate(654,42,playing ? 48'h64AD653E4E2D : 48'h5DF26682505C,3,playing ? C_WHITE : C_MUTED);
        else if(practice_active)text_leaf[13]=cjk_candidate(654,42,
            guide_completed ? 32'h5B8C6210 : playing ? 32'h6F14594F : 32'h6682505C,
            2,playing ? C_WHITE : C_MUTED);
        else text_leaf[13]=cjk_candidate(654,42,playing ? 32'h6F14594F : 32'h975997F3,2,playing ? C_WHITE : C_MUTED);
        if (x>=758 && x<768 && y>=42 && y<52)
            geometry_leaf[6]={1'b1,playing ? C_CORAL : C_EDGE};

        // Warm ivory central display: flat and square like an instrument face,
        // with the same readable margins in all views.
        if (x>=24 && x<776 && y>=88 && y<312) geometry_leaf[7]={1'b1,C_PAPER};
        if(!volume_edit) begin
        case (ui_mode)
            1: begin
                if(practice_active)begin
                    text_leaf[223]=cjk_candidate(40,104,64'h66F28C3163075F15,4,C_INK);
                    // Karaoke-style stage: one current target, quiet next
                    // target, and honest event counts (not a singing score).
                    if(x>=40 && x<272 && y>=138 && y<232)geometry_leaf[381]={1'b1,C_GUIDE_PALE};
                    if(x>=40 && x<44 && y>=138 && y<232)geometry_leaf[382]={1'b1,C_CORAL};
                    if(x>=288 && x<472 && y>=138 && y<232)geometry_leaf[383]={1'b1,C_TEAL_PALE};
                    text_leaf[224]=cjk_candidate(56,142,48'h5F53524D97F3,3,C_STAFF);
                    text_leaf[225]=note_candidate_large(56,166,note_name(target_note),C_INK);
                    text_leaf[226]=cjk_candidate(500,142,32'h547D4E2D,2,C_STAFF);
                    text_leaf[227]=note_candidate_large(500,166,decimal3(guide_hits),C_TEAL);
                    text_leaf[228]=cjk_candidate(636,142,32'h951997F3,2,C_STAFF);
                    text_leaf[229]=note_candidate_large(636,166,decimal3(guide_errors),C_CORAL);
                    if(guide_completed)text_leaf[230]=cjk_candidate(56,209,32'h5B8C6210,2,C_TEAL);
                    else if(!input_online[2])text_leaf[230]=cjk_candidate(56,209,64'h8F93516579BB7EBF,4,C_INK);
                    else if(!playing)text_leaf[230]=cjk_candidate(56,209,48'h5DF26682505C,3,C_STAFF);
                    else if(guide_unsupported)text_leaf[230]=cjk_candidate(56,209,64'h8D8551FA97F357DF,4,C_INK);
                    else if(guide_wrong)text_leaf[230]=cjk_candidate(56,209,48'h8BF791CD8BD5,3,C_INK);
                    else if(target_note==0)text_leaf[230]=cjk_candidate(56,209,32'h4F116B62,2,C_STAFF);
                    else text_leaf[230]=cjk_candidate(56,209,practice_mode==2 ? 64'h7B495F856309952E : 64'h8DDF968F6F14594F,4,C_INK);
                    text_leaf[231]=cjk_candidate(500,211,input_online[2] ? 80'h8F9351655DF28FDE63A5 : 64'h8F93516579BB7EBF,input_online[2] ? 5 : 4,C_STAFF);
                    text_leaf[248]=cjk_candidate(304,142,48'h4E0B4E0097F3,3,C_STAFF);
                    if(active_slot==7)text_leaf[249]=cjk_candidate(304,178,48'h672C9875672B,3,C_INK);
                    else text_leaf[249]=note_candidate_large(304,166,note_name(next_note),C_INK);
                    text_leaf[250]=cjk_candidate(304,209,32'h9884544A,2,C_STAFF);
                    text_leaf[251]=cjk_candidate(168,142,32'h952E4F4D,2,C_STAFF);
                    text_leaf[252]=note_candidate_large(168,166,{pad_number(target_note),8'h20},C_INK);
                    // The real eight-event page, not a free-running animation.
                    // STEP waits at the highlighted event until a valid onset.
                    for(i=0;i<8;i=i+1)begin
                        nx=40+i*90;
                        if(x>=nx && x<nx+84 && y>=244 && y<275)
                            geometry_leaf[388+i*2]={1'b1,i==active_slot ? C_GUIDE_PALE : C_TEAL_PALE};
                        if(x>=nx && x<nx+84 && y>=272 && y<275 && i==active_slot)
                            geometry_leaf[389+i*2]={1'b1,C_CORAL};
                        text_leaf[234+i]=ascii_candidate(nx+26,249,
                            note_name(score_notes[i*7 +:7]),3,i==active_slot ? C_INK : C_STAFF);
                    end
                    text_leaf[242]=ascii_candidate(40,287,"S1+S3",5,C_STAFF);
                    text_leaf[243]=cjk_candidate(100,285,64'h957F63097EC34E60,4,C_STAFF);
                    text_leaf[244]=ascii_candidate(288,287,"S2+S3",5,C_STAFF);
                    text_leaf[245]=cjk_candidate(348,285,64'h957F63094F34594F,4,C_STAFF);
                    text_leaf[246]=ascii_candidate(548,287,"S1+S2",5,C_STAFF);
                    text_leaf[247]=cjk_candidate(608,285,64'h957F630997F391CF,4,C_STAFF);
                end else begin
                // PLAY reports actual mask state, never an invented waveform.
                text_leaf[14]=cjk_candidate(40,104,64'h5B9E65F66F14594F,4,C_INK);
                if (demo_mode) text_leaf[15]=cjk_candidate(40,128,64'h81EA52A88BD5542C,4,C_STAFF);
                else text_leaf[16]=cjk_candidate(40,128,64'h6309952E72B66001,4,C_STAFF);
                text_leaf[17]=cjk_candidate(450,128,32'h89E66478,2,C_STAFF);
                if(x>=505 && x<512 && y>=134 && y<141)geometry_leaf[8]={1'b1,input_online[0] ? C_TEAL : C_STAFF};
                if(x>=517 && x<524 && y>=134 && y<141)geometry_leaf[9]={1'b1,input_online[1] ? C_TEAL : C_STAFF};
                text_leaf[18]=cjk_candidate(586,128,32'h529B5EA6,2,C_STAFF);
                if(x>=642 && x<649 && y>=134 && y<141)geometry_leaf[10]={1'b1,input_online[2] ? C_TEAL : C_STAFF};
                if ((x==264 || x==452) && y>=157 && y<225) geometry_leaf[11]={1'b1,C_STAFF};
                text_leaf[19]=cjk_candidate(40,156,48'h67004F4E97F3,3,C_STAFF);
                text_leaf[20]=ascii_candidate(40,182,note_name(lowest_note),3,C_INK);
                text_leaf[21]=cjk_candidate(290,156,64'h63094E0B657091CF,4,C_STAFF);
                text_leaf[22]=ascii_candidate(290,182,decimal3(pressed_count),3,C_INK);
                text_leaf[23]=cjk_candidate(496,156,32'h529B5EA6,2,C_STAFF); text_leaf[24]=ascii_candidate(552,163,"0-127",5,C_STAFF);
                if (x>=496 && x<750 && y>=184 && y<201) geometry_leaf[12]={1'b1,C_TEAL_PALE};
                fill_width=expression*2;
                if (x>=496 && x<496+fill_width && y>=184 && y<201)
                    geometry_leaf[13]={1'b1,C_TEAL};
                text_leaf[25]=ascii_candidate(496,217,decimal3({1'b0,expression}),3,C_INK);
                text_leaf[26]=cjk_candidate(40,236,64'h5B9E65F68F935165,4,C_STAFF); text_leaf[27]=ascii_candidate(190,243,"C4-D6",5,C_STAFF);
                begin

                    key_left=40+0*29;
                    key_color=C_STAFF;
                    if (guide[0]) key_color=C_CORAL;
                    if (pressed[0]) key_color=C_TEAL;
                    if (guide[0] && pressed[0]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[14]={1'b1,key_color};
                
end
begin

                    key_left=40+1*29;
                    key_color=C_STAFF;
                    if (guide[1]) key_color=C_CORAL;
                    if (pressed[1]) key_color=C_TEAL;
                    if (guide[1] && pressed[1]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[15]={1'b1,key_color};
                
end
begin

                    key_left=40+2*29;
                    key_color=C_STAFF;
                    if (guide[2]) key_color=C_CORAL;
                    if (pressed[2]) key_color=C_TEAL;
                    if (guide[2] && pressed[2]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[16]={1'b1,key_color};
                
end
begin

                    key_left=40+3*29;
                    key_color=C_STAFF;
                    if (guide[3]) key_color=C_CORAL;
                    if (pressed[3]) key_color=C_TEAL;
                    if (guide[3] && pressed[3]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[17]={1'b1,key_color};
                
end
begin

                    key_left=40+4*29;
                    key_color=C_STAFF;
                    if (guide[4]) key_color=C_CORAL;
                    if (pressed[4]) key_color=C_TEAL;
                    if (guide[4] && pressed[4]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[18]={1'b1,key_color};
                
end
begin

                    key_left=40+5*29;
                    key_color=C_STAFF;
                    if (guide[5]) key_color=C_CORAL;
                    if (pressed[5]) key_color=C_TEAL;
                    if (guide[5] && pressed[5]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[19]={1'b1,key_color};
                
end
begin

                    key_left=40+6*29;
                    key_color=C_STAFF;
                    if (guide[6]) key_color=C_CORAL;
                    if (pressed[6]) key_color=C_TEAL;
                    if (guide[6] && pressed[6]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[20]={1'b1,key_color};
                
end
begin

                    key_left=40+7*29;
                    key_color=C_STAFF;
                    if (guide[7]) key_color=C_CORAL;
                    if (pressed[7]) key_color=C_TEAL;
                    if (guide[7] && pressed[7]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[21]={1'b1,key_color};
                
end
begin

                    key_left=40+8*29;
                    key_color=C_STAFF;
                    if (guide[8]) key_color=C_CORAL;
                    if (pressed[8]) key_color=C_TEAL;
                    if (guide[8] && pressed[8]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[22]={1'b1,key_color};
                
end
begin

                    key_left=40+9*29;
                    key_color=C_STAFF;
                    if (guide[9]) key_color=C_CORAL;
                    if (pressed[9]) key_color=C_TEAL;
                    if (guide[9] && pressed[9]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[23]={1'b1,key_color};
                
end
begin

                    key_left=40+10*29;
                    key_color=C_STAFF;
                    if (guide[10]) key_color=C_CORAL;
                    if (pressed[10]) key_color=C_TEAL;
                    if (guide[10] && pressed[10]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[24]={1'b1,key_color};
                
end
begin

                    key_left=40+11*29;
                    key_color=C_STAFF;
                    if (guide[11]) key_color=C_CORAL;
                    if (pressed[11]) key_color=C_TEAL;
                    if (guide[11] && pressed[11]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[25]={1'b1,key_color};
                
end
begin

                    key_left=40+12*29;
                    key_color=C_STAFF;
                    if (guide[12]) key_color=C_CORAL;
                    if (pressed[12]) key_color=C_TEAL;
                    if (guide[12] && pressed[12]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[26]={1'b1,key_color};
                
end
begin

                    key_left=40+13*29;
                    key_color=C_STAFF;
                    if (guide[13]) key_color=C_CORAL;
                    if (pressed[13]) key_color=C_TEAL;
                    if (guide[13] && pressed[13]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[27]={1'b1,key_color};
                
end
begin

                    key_left=40+14*29;
                    key_color=C_STAFF;
                    if (guide[14]) key_color=C_CORAL;
                    if (pressed[14]) key_color=C_TEAL;
                    if (guide[14] && pressed[14]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[28]={1'b1,key_color};
                
end
begin

                    key_left=40+15*29;
                    key_color=C_STAFF;
                    if (guide[15]) key_color=C_CORAL;
                    if (pressed[15]) key_color=C_TEAL;
                    if (guide[15] && pressed[15]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[29]={1'b1,key_color};
                
end
begin

                    key_left=40+16*29;
                    key_color=C_STAFF;
                    if (guide[16]) key_color=C_CORAL;
                    if (pressed[16]) key_color=C_TEAL;
                    if (guide[16] && pressed[16]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[30]={1'b1,key_color};
                
end
begin

                    key_left=40+17*29;
                    key_color=C_STAFF;
                    if (guide[17]) key_color=C_CORAL;
                    if (pressed[17]) key_color=C_TEAL;
                    if (guide[17] && pressed[17]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[31]={1'b1,key_color};
                
end
begin

                    key_left=40+18*29;
                    key_color=C_STAFF;
                    if (guide[18]) key_color=C_CORAL;
                    if (pressed[18]) key_color=C_TEAL;
                    if (guide[18] && pressed[18]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[32]={1'b1,key_color};
                
end
begin

                    key_left=40+19*29;
                    key_color=C_STAFF;
                    if (guide[19]) key_color=C_CORAL;
                    if (pressed[19]) key_color=C_TEAL;
                    if (guide[19] && pressed[19]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[33]={1'b1,key_color};
                
end
begin

                    key_left=40+20*29;
                    key_color=C_STAFF;
                    if (guide[20]) key_color=C_CORAL;
                    if (pressed[20]) key_color=C_TEAL;
                    if (guide[20] && pressed[20]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[34]={1'b1,key_color};
                
end
begin

                    key_left=40+21*29;
                    key_color=C_STAFF;
                    if (guide[21]) key_color=C_CORAL;
                    if (pressed[21]) key_color=C_TEAL;
                    if (guide[21] && pressed[21]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[35]={1'b1,key_color};
                
end
begin

                    key_left=40+22*29;
                    key_color=C_STAFF;
                    if (guide[22]) key_color=C_CORAL;
                    if (pressed[22]) key_color=C_TEAL;
                    if (guide[22] && pressed[22]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[36]={1'b1,key_color};
                
end
begin

                    key_left=40+23*29;
                    key_color=C_STAFF;
                    if (guide[23]) key_color=C_CORAL;
                    if (pressed[23]) key_color=C_TEAL;
                    if (guide[23] && pressed[23]) key_color=C_GOLD;
                    if (x>=key_left && x<key_left+22 && y>=263 && y<279)
                        geometry_leaf[37]={1'b1,key_color};
                
end
            end
                end
            2: begin
                // Preset names match the 12 harmonic wavetable banks.
                text_leaf[28]=cjk_candidate(40,104,64'h97F38272988489C8,4,C_INK);
                text_leaf[29]=cjk_candidate(40,128,64'h540862108FD14F3C,4,C_STAFF);
                begin

                    key_left=40+0*180;
                    text_leaf[30]=cjk_candidate(key_left,151,cjk_family_name(2'd0),2,
                             (0==instrument) ? C_INK : C_STAFF);
                    if (x>=key_left && x<key_left+136 && y>=173 && y<176)
                        geometry_leaf[38]={1'b1,(0==instrument) ? C_CORAL : C_STAFF};
                    if (0==0) text_leaf[31]=cjk_candidate(key_left,180,32'h952E76D8,2,C_STAFF);
                    else text_leaf[32]=cjk_candidate(key_left,180,64'h4E8C534156DB97F3,4,C_STAFF);
                
end
begin

                    key_left=40+1*180;
                    text_leaf[33]=cjk_candidate(key_left,151,cjk_family_name(2'd1),2,
                             (1==instrument) ? C_INK : C_STAFF);
                    if (x>=key_left && x<key_left+136 && y>=173 && y<176)
                        geometry_leaf[39]={1'b1,(1==instrument) ? C_CORAL : C_STAFF};
                    if (1==0) text_leaf[34]=cjk_candidate(key_left,180,32'h952E76D8,2,C_STAFF);
                    else text_leaf[35]=cjk_candidate(key_left,180,64'h4E8C534156DB97F3,4,C_STAFF);
                
end
begin

                    key_left=40+2*180;
                    text_leaf[36]=cjk_candidate(key_left,151,cjk_family_name(2'd2),2,
                             (2==instrument) ? C_INK : C_STAFF);
                    if (x>=key_left && x<key_left+136 && y>=173 && y<176)
                        geometry_leaf[40]={1'b1,(2==instrument) ? C_CORAL : C_STAFF};
                    if (2==0) text_leaf[37]=cjk_candidate(key_left,180,32'h952E76D8,2,C_STAFF);
                    else text_leaf[38]=cjk_candidate(key_left,180,64'h4E8C534156DB97F3,4,C_STAFF);
                
end
begin

                    key_left=40+3*180;
                    text_leaf[39]=cjk_candidate(key_left,151,cjk_family_name(2'd3),2,
                             (3==instrument) ? C_INK : C_STAFF);
                    if (x>=key_left && x<key_left+136 && y>=173 && y<176)
                        geometry_leaf[41]={1'b1,(3==instrument) ? C_CORAL : C_STAFF};
                    if (3==0) text_leaf[40]=cjk_candidate(key_left,180,32'h952E76D8,2,C_STAFF);
                    else text_leaf[41]=cjk_candidate(key_left,180,64'h4E8C534156DB97F3,4,C_STAFF);
                
end
                begin

                    ny=215+0*30;
                    if (0==timbre) begin
                        if (x>=36 && x<756 && y>=ny-4 && y<ny+20)
                            geometry_leaf[42]={1'b1,C_GUIDE_PALE};
                        if (x>=36 && x<40 && y>=ny-4 && y<ny+20)
                            geometry_leaf[43]={1'b1,C_CORAL};
                    end
                    text_leaf[42]=ascii_candidate(48,ny,decimal3(0+1),3,C_STAFF);
                    text_leaf[43]=cjk_candidate(88,ny,cjk_preset_name(instrument,2'd0),cjk_preset_length(instrument,2'd0),C_INK);
                    text_leaf[44]=cjk_candidate(282,ny,64'h6309952E8BD5542C,4,C_STAFF);
                
end
begin

                    ny=215+1*30;
                    if (1==timbre) begin
                        if (x>=36 && x<756 && y>=ny-4 && y<ny+20)
                            geometry_leaf[44]={1'b1,C_GUIDE_PALE};
                        if (x>=36 && x<40 && y>=ny-4 && y<ny+20)
                            geometry_leaf[45]={1'b1,C_CORAL};
                    end
                    text_leaf[45]=ascii_candidate(48,ny,decimal3(1+1),3,C_STAFF);
                    text_leaf[46]=cjk_candidate(88,ny,cjk_preset_name(instrument,2'd1),cjk_preset_length(instrument,2'd1),C_INK);
                    text_leaf[47]=cjk_candidate(282,ny,64'h6309952E8BD5542C,4,C_STAFF);
                
end
begin

                    ny=215+2*30;
                    if (2==timbre) begin
                        if (x>=36 && x<756 && y>=ny-4 && y<ny+20)
                            geometry_leaf[46]={1'b1,C_GUIDE_PALE};
                        if (x>=36 && x<40 && y>=ny-4 && y<ny+20)
                            geometry_leaf[47]={1'b1,C_CORAL};
                    end
                    text_leaf[48]=ascii_candidate(48,ny,decimal3(2+1),3,C_STAFF);
                    text_leaf[49]=cjk_candidate(88,ny,cjk_preset_name(instrument,2'd2),cjk_preset_length(instrument,2'd2),C_INK);
                    text_leaf[50]=cjk_candidate(282,ny,64'h6309952E8BD5542C,4,C_STAFF);
                
end
            end
            3: begin
                // Four exercises plus three user-provided melody arrangements.
                text_leaf[51]=cjk_candidate(40,104,32'h6B4C5355,2,C_INK);
                text_leaf[52]=cjk_candidate(122,104,80'h4E3B65CB5F8B65397F16,5,C_STAFF);
                text_leaf[53]=cjk_candidate(560,104,32'h6BCF5206,2,C_STAFF);
                text_leaf[54]=cjk_candidate(680,104,32'h4E8B4EF6,2,C_STAFF);
                begin
                    ny=144;
                    if(!imported_score && song_id==0) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+23)geometry_leaf[48]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+23)geometry_leaf[49]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==0) ? C_INK : C_STAFF;
                    text_leaf[55]=cjk_candidate(56,ny,48'h6B224E509882,3,key_color);
                    text_leaf[56]=ascii_candidate(568,ny,decimal3(100),3,key_color);
                    text_leaf[57]=ascii_candidate(688,ny,decimal3(32),3,key_color); // song 0 event count
                end
                begin
                    ny=168;
                    if(!imported_score && song_id==1) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+23)geometry_leaf[50]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+23)geometry_leaf[51]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==1) ? C_INK : C_STAFF;
                    text_leaf[58]=cjk_candidate(56,ny,48'h5C0F661F661F,3,key_color);
                    text_leaf[59]=ascii_candidate(568,ny,decimal3(110),3,key_color);
                    text_leaf[60]=ascii_candidate(688,ny,decimal3(42),3,key_color); // song 1 event count
                end
                begin
                    ny=192;
                    if(!imported_score && song_id==2) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+23)geometry_leaf[52]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+23)geometry_leaf[53]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==2) ? C_INK : C_STAFF;
                    text_leaf[61]=cjk_candidate(56,ny,64'h4E2453EA8001864E,4,key_color);
                    text_leaf[62]=ascii_candidate(568,ny,decimal3(120),3,key_color);
                    text_leaf[63]=ascii_candidate(688,ny,decimal3(32),3,key_color); // song 2 event count
                end
                begin
                    ny=216;
                    if(!imported_score && song_id==3) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+23)geometry_leaf[54]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+23)geometry_leaf[55]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==3) ? C_INK : C_STAFF;
                    text_leaf[64]=cjk_candidate(56,ny,64'h539F521B7EC34E60,4,key_color);
                    text_leaf[65]=ascii_candidate(568,ny,decimal3(90),3,key_color);
                    text_leaf[66]=ascii_candidate(688,ny,decimal3(24),3,key_color); // song 3 event count
                end
                begin
                    ny=240;
                    if(!imported_score && song_id==4) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+23)geometry_leaf[56]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+23)geometry_leaf[57]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==4) ? C_INK : C_STAFF;
                    text_leaf[67]=cjk_candidate(56,ny,80'h62117684672A67655F0F,5,key_color);
                    text_leaf[68]=ascii_candidate(568,ny,decimal3(158),3,key_color);
                    text_leaf[69]=ascii_candidate(688,ny,decimal3(202),3,key_color); // song 4 event count
                end
                begin
                    ny=264;
                    if(!imported_score && song_id==5) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+23)geometry_leaf[58]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+23)geometry_leaf[59]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==5) ? C_INK : C_STAFF;
                    text_leaf[70]=cjk_candidate(56,ny,64'h755957284F605BB6,4,key_color);
                    text_leaf[71]=ascii_candidate(568,ny,decimal3(125),3,key_color);
                    text_leaf[72]=ascii_candidate(688,ny,decimal3(239),3,key_color); // song 5 event count
                end
                begin
                    ny=288;
                    if(!imported_score && song_id==6) begin
                        if(x>=36 && x<756 && y>=ny-3 && y<ny+20)geometry_leaf[60]={1'b1,C_GUIDE_PALE};
                        if(x>=36 && x<40 && y>=ny-3 && y<ny+20)geometry_leaf[61]={1'b1,C_CORAL};
                    end
                    key_color=(!imported_score && song_id==6) ? C_INK : C_STAFF;
                    text_leaf[253]=cjk_candidate(56,ny,96'h661F96457A7F8D8A82829009,6,key_color);
                    text_leaf[254]=ascii_candidate(568,ny,decimal3(94),3,key_color);
                    text_leaf[255]=ascii_candidate(688,ny,decimal3(65),3,key_color);
                end
            end
            default: begin
                // SCORE: correct treble staff, accidentals and ledger lines.
                if (imported_score) text_leaf[103]=cjk_candidate(40,104,64'h5BFC516566F28C31,4,C_INK);
                else case(song_id)
                    6:text_leaf[106]=cjk_candidate(40,104,96'h661F96457A7F8D8A82829009,6,C_INK);
                    4:text_leaf[104]=cjk_candidate(40,104,80'h62117684672A67655F0F,5,C_INK);
                    5:text_leaf[105]=cjk_candidate(40,104,64'h755957284F605BB6,4,C_INK);
                    1:text_leaf[104]=cjk_candidate(40,104,48'h5C0F661F661F,3,C_INK);
                    2:text_leaf[105]=cjk_candidate(40,104,64'h4E2453EA8001864E,4,C_INK);
                    3:text_leaf[106]=cjk_candidate(40,104,64'h539F521B7EC34E60,4,C_INK);
                    default:text_leaf[107]=cjk_candidate(40,104,48'h6B224E509882,3,C_INK);
                endcase
                text_leaf[108]=cjk_candidate(300,104,64'h6BCF9875516B97F3,4,C_STAFF);
                text_leaf[109]=cjk_candidate(681,104,16'h9875,1,C_STAFF);
                text_leaf[110]=ascii_candidate(712,112,decimal3(page_index+8'd1),3,C_INK);

                begin

                    if (x>=42 && x<758 && y==158+0*12) geometry_leaf[56]={1'b1,C_STAFF};
                
end
begin

                    if (x>=42 && x<758 && y==158+1*12) geometry_leaf[57]={1'b1,C_STAFF};
                
end
begin

                    if (x>=42 && x<758 && y==158+2*12) geometry_leaf[58]={1'b1,C_STAFF};
                
end
begin

                    if (x>=42 && x<758 && y==158+3*12) geometry_leaf[59]={1'b1,C_STAFF};
                
end
begin

                    if (x>=42 && x<758 && y==158+4*12) geometry_leaf[60]={1'b1,C_STAFF};
                
end
                if ((x==438 || x==757) && y>=158 && y<=206) geometry_leaf[61]={1'b1,C_STAFF};
                if (x>=48 && x<86 && y>=134 && y<222) begin
                    clef_bits=clef_row((y-134)>>1);
                    clef_col=(x-48)>>1;
                    if (clef_bits[18-clef_col]) geometry_leaf[62]={1'b1,C_INK};
                end
                text_leaf[111]=ascii_candidate(99,159,"4",1,C_INK);
                text_leaf[112]=ascii_candidate(99,187,"4",1,C_INK);

                nx=152+active_slot*82;
                if (x>=nx-25 && x<nx-23 && y>=132 && y<238) geometry_leaf[63]={1'b1,C_CORAL};
                if (x>=nx-28 && x<nx-20 && y>=128 && y<132) geometry_leaf[64]={1'b1,C_CORAL};
                if (x>=nx-13 && x<nx+17 && y>=261 && y<263) geometry_leaf[65]={1'b1,C_CORAL};
                begin

                    nx=152+0*82;
                    note=score_notes[0*7 +: 7];
                    duration=score_lengths[0*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(0==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[66]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[67]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[68]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[69]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[70]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[71]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[72]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[73]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[74]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[75]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[76]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[113]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[114]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[115]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[77]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+1*82;
                    note=score_notes[1*7 +: 7];
                    duration=score_lengths[1*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(1==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[78]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[79]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[80]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[81]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[82]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[83]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[84]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[85]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[86]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[87]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[88]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[116]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[117]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[118]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[89]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+2*82;
                    note=score_notes[2*7 +: 7];
                    duration=score_lengths[2*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(2==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[90]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[91]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[92]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[93]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[94]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[95]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[96]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[97]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[98]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[99]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[100]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[119]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[120]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[121]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[101]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+3*82;
                    note=score_notes[3*7 +: 7];
                    duration=score_lengths[3*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(3==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[102]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[103]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[104]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[105]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[106]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[107]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[108]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[109]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[110]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[111]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[112]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[122]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[123]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[124]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[113]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+4*82;
                    note=score_notes[4*7 +: 7];
                    duration=score_lengths[4*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(4==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[114]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[115]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[116]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[117]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[118]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[119]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[120]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[121]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[122]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[123]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[124]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[125]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[126]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[127]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[125]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+5*82;
                    note=score_notes[5*7 +: 7];
                    duration=score_lengths[5*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(5==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[126]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[127]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[128]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[129]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[130]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[131]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[132]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[133]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[134]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[135]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[136]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[128]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[129]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[130]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[137]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+6*82;
                    note=score_notes[6*7 +: 7];
                    duration=score_lengths[6*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(6==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[138]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[139]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[140]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[141]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[142]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[143]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[144]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[145]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[146]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[147]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[148]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[131]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[132]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[133]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[149]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
begin

                    nx=152+7*82;
                    note=score_notes[7*7 +: 7];
                    duration=score_lengths[7*4 +: 4];
                    ny=pitch_y(note);
                    is_current=(7==active_slot);
                    is_rest=(note<48 || note>95 || duration==0);
                    if (is_rest) begin
                        if ((x>=nx-5 && x<nx+7 && y>=177 && y<181) ||
                            (x>=nx-3 && x<nx+1 && y>=181 && y<189) ||
                            (x>=nx-1 && x<nx+5 && y>=189 && y<192))
                            geometry_leaf[150]={1'b1,is_current ? C_CORAL : C_INK};
                    end else begin
                        if (x>=nx-12 && x<nx+13 &&
                            ((ny>=218 && y==218) || (ny>=230 && y==230) ||
                             (ny>=242 && y==242) || (ny>=254 && y==254) ||
                             (ny<=146 && y==146) || (ny<=134 && y==134) ||
                             (ny<=122 && y==122) || (ny<=110 && y==110) ||
                             (ny<=98 && y==98))) geometry_leaf[151]={1'b1,C_STAFF};
                        // Four-bit durations max at 15 sixteenth ticks, so no
                        // value here represents a 16-tick whole note.
                        if (note>=71) begin
                            if (x>=nx-7 && x<nx-5 && y>=ny && y<ny+34)
                                geometry_leaf[152]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx-5 && x<nx+3 && y>=ny+27 && y<ny+31)
                                geometry_leaf[153]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx-5 && x<nx+3 && y>=ny+21 && y<ny+24)
                                geometry_leaf[154]={1'b1,is_current ? C_CORAL : C_INK};
                        end else begin
                            if (x>=nx+5 && x<nx+7 && y>ny-34 && y<=ny)
                                geometry_leaf[155]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration<=3 && x>=nx+7 && x<nx+15 && y>ny-31 && y<=ny-27)
                                geometry_leaf[156]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration==1 && x>=nx+7 && x<nx+15 && y>ny-24 && y<=ny-21)
                                geometry_leaf[157]={1'b1,is_current ? C_CORAL : C_INK};
                        end
                        dx=(x>=nx) ? x-nx : nx-x;
                        dy=(y>=ny) ? y-ny : ny-y;
                        if ((dy<=2 && dx<=7) || (dy==3 && dx<=5) || (dy==4 && dx<=3)) begin
                            geometry_leaf[158]={1'b1,is_current ? C_CORAL : C_INK};
                            if (duration>=8 && dy<=1 && dx<=4) geometry_leaf[159]={1'b1,C_PAPER};
                        end
                        if ((duration==3 || duration==6 || duration==12) &&
                            x>=nx+12 && x<nx+15 && y>=ny-2 && y<ny+1)
                            geometry_leaf[160]={1'b1,is_current ? C_CORAL : C_INK};
                        if (sharp_note(note)) text_leaf[134]=ascii_candidate(nx-21,ny-5,"#",1,C_INK);
                    end
                    if (is_rest) text_leaf[135]=ascii_candidate(nx-24,246,"REST",4,C_INK);
                    else begin
                        text_leaf[136]=ascii_candidate(nx-15,(note<57 ? 266 : 242),note_name(note),3,C_INK);
                        // Native note-name labels; breathing room replaces duplicated solfege.
                    end
                    if (x>=nx-3 && x<nx+4 && y>=281 && y<285)
                        geometry_leaf[161]={1'b1,is_current ? C_CORAL : C_STAFF};
                
end
                if (x>=32 && x<768 && y>=299 && y<302) geometry_leaf[162]={1'b1,C_TEAL_PALE};
                fill_width=(progress==127) ? 736 : (progress*736)>>7;
                if (x>=32 && x<32+fill_width && y>=299 && y<302) geometry_leaf[163]={1'b1,C_CORAL};
            end
        endcase
        end else begin
            text_leaf[205]=cjk_candidate(40,104,32'h97F391CF,2,C_INK);
            text_leaf[206]=cjk_candidate(112,104,32'h603B63A7,2,C_STAFF);
            text_leaf[207]=ascii_candidate(640,104,{decimal3(volume_percent),8'h25},4,
                                           volume_step==0 ? C_STAFF : C_TEAL);
            text_leaf[208]=cjk_candidate(40,142,32'h957F6309,2,C_STAFF);
            text_leaf[209]=ascii_candidate(100,142,"S1+S2",5,C_STAFF);
            text_leaf[210]=cjk_candidate(180,142,32'h97F391CF,2,C_STAFF);
            if(x>=40 && x<760 && y>=190 && y<218)geometry_leaf[378]={1'b1,C_TEAL_PALE};
            fill_width=volume_step*36;
            if(x>=40 && x<40+fill_width && y>=190 && y<218)
                geometry_leaf[379]={1'b1,volume_step==0 ? C_STAFF : C_TEAL};
            // Fixed quarter marks avoid a pixel-rate divider.
            if((x==40 || x==220 || x==400 || x==580 || x==760) && y>=223 && y<228)
                geometry_leaf[380]={1'b1,C_STAFF};
            text_leaf[211]=ascii_candidate(40,234,"0%",2,C_STAFF);
            text_leaf[212]=ascii_candidate(370,234,"50%",3,C_STAFF);
            text_leaf[213]=ascii_candidate(720,234,"100%",4,C_STAFF);
            text_leaf[214]=ascii_candidate(40,274,"S1 -5%",6,C_INK);
            text_leaf[215]=ascii_candidate(300,274,"S2 +5%",6,C_INK);
            text_leaf[216]=ascii_candidate(560,274,"S3 EXIT",7,C_INK);
        end

        // Bottom input view is independent of SCORE/PLAY/SOUND. KEYS gets a
        // physical 14-white/10-black piano. Other UI families get 24 independent
        // chromatic note pads; these are not guitar frets or General MIDI drums.
        if (x>=24 && x<776 && y>=340 && y<459) geometry_leaf[164]={1'b1,C_PANEL};
        if (!pad_layout) begin
            begin

                key_left=36+0*52;
                key_bit=white_pitch(0);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[165]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[166]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[167]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[168]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[169]={1'b1,C_GOLD};
                end
                text_leaf[137]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+1*52;
                key_bit=white_pitch(1);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[170]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[171]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[172]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[173]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[174]={1'b1,C_GOLD};
                end
                text_leaf[138]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+2*52;
                key_bit=white_pitch(2);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[175]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[176]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[177]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[178]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[179]={1'b1,C_GOLD};
                end
                text_leaf[139]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+3*52;
                key_bit=white_pitch(3);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[180]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[181]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[182]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[183]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[184]={1'b1,C_GOLD};
                end
                text_leaf[140]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+4*52;
                key_bit=white_pitch(4);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[185]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[186]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[187]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[188]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[189]={1'b1,C_GOLD};
                end
                text_leaf[141]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+5*52;
                key_bit=white_pitch(5);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[190]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[191]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[192]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[193]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[194]={1'b1,C_GOLD};
                end
                text_leaf[142]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+6*52;
                key_bit=white_pitch(6);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[195]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[196]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[197]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[198]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[199]={1'b1,C_GOLD};
                end
                text_leaf[143]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+7*52;
                key_bit=white_pitch(7);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[200]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[201]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[202]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[203]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[204]={1'b1,C_GOLD};
                end
                text_leaf[144]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+8*52;
                key_bit=white_pitch(8);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[205]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[206]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[207]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[208]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[209]={1'b1,C_GOLD};
                end
                text_leaf[145]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+9*52;
                key_bit=white_pitch(9);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[210]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[211]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[212]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[213]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[214]={1'b1,C_GOLD};
                end
                text_leaf[146]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+10*52;
                key_bit=white_pitch(10);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[215]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[216]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[217]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[218]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[219]={1'b1,C_GOLD};
                end
                text_leaf[147]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+11*52;
                key_bit=white_pitch(11);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[220]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[221]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[222]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[223]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[224]={1'b1,C_GOLD};
                end
                text_leaf[148]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+12*52;
                key_bit=white_pitch(12);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[225]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[226]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[227]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[228]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[229]={1'b1,C_GOLD};
                end
                text_leaf[149]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
begin

                key_left=36+13*52;
                key_bit=white_pitch(13);
                key_color=C_WHITE;
                if (guide[key_bit]) key_color=C_GUIDE_PALE;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=key_left && x<key_left+50 && y>=346 && y<454)
                    geometry_leaf[230]={1'b1,key_color};
                if (x>=key_left && x<key_left+50 && y>=450 && y<454)
                    geometry_leaf[231]={1'b1,pressed[key_bit] ? C_TEAL : C_PAPER};
                if (x>=key_left && x<key_left+50 && y>=346 && y<350) begin
                    if (guide[key_bit]) geometry_leaf[232]={1'b1,C_CORAL};
                    if (pressed[key_bit]) geometry_leaf[233]={1'b1,C_TEAL};
                    if (pressed[key_bit] && guide[key_bit]) geometry_leaf[234]={1'b1,C_GOLD};
                end
                text_leaf[150]=ascii_candidate(key_left+10,420,note_name(60+key_bit),3,C_INK);
            
end
            begin

                black_left=36+black_boundary(0)*52-15;
                key_bit=black_pitch(0);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[235]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[236]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[237]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[238]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[151]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(1)*52-15;
                key_bit=black_pitch(1);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[239]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[240]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[241]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[242]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[152]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(2)*52-15;
                key_bit=black_pitch(2);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[243]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[244]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[245]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[246]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[153]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(3)*52-15;
                key_bit=black_pitch(3);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[247]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[248]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[249]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[250]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[154]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(4)*52-15;
                key_bit=black_pitch(4);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[251]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[252]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[253]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[254]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[155]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(5)*52-15;
                key_bit=black_pitch(5);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[255]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[256]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[257]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[258]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[156]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(6)*52-15;
                key_bit=black_pitch(6);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[259]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[260]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[261]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[262]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[157]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(7)*52-15;
                key_bit=black_pitch(7);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[263]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[264]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[265]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[266]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[158]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(8)*52-15;
                key_bit=black_pitch(8);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[267]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[268]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[269]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[270]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[159]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
begin

                black_left=36+black_boundary(9)*52-15;
                key_bit=black_pitch(9);
                key_color=C_BLACK;
                if (guide[key_bit]) key_color=C_CORAL;
                if (pressed[key_bit]) key_color=C_TEAL;
                if (pressed[key_bit] && guide[key_bit]) key_color=C_GOLD;
                if (x>=black_left+3 && x<black_left+33 && y>=350 && y<417)
                    geometry_leaf[271]={1'b1,C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=346 && y<414)
                    geometry_leaf[272]={1'b1,key_color};
                if (x>=black_left+4 && x<black_left+26 && y>=350 && y<353)
                    geometry_leaf[273]={1'b1,(guide[key_bit] || pressed[key_bit]) ? C_WHITE : C_EDGE};
                if (x>=black_left && x<black_left+30 && y>=408 && y<414)
                    geometry_leaf[274]={1'b1,(guide[key_bit] || pressed[key_bit]) ? key_color : C_PANEL};
                text_leaf[160]=ascii_candidate(black_left,392,note_name(60+key_bit),3,(guide[key_bit] || pressed[key_bit]) ? C_INK : C_MUTED);
            
end
            text_leaf[161]=cjk_candidate(36,319,32'h952E76D8,2,C_WHITE); text_leaf[162]=ascii_candidate(100,326,"C4-B5",5,C_WHITE);
        end else begin
            begin

                if (0<12) begin pad_col=0; pad_top=346; end
                else begin pad_col=0-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[0]) key_color=C_GUIDE_PALE;
                if (pressed[0]) key_color=C_TEAL;
                if (guide[0] && pressed[0]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[275]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[276]={1'b1,key_color};
                if (guide[0] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[277]={1'b1,C_CORAL};
                if (pressed[0] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[278]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[163]=ascii_candidate(key_left+13,pad_top+18,note_name(60+0),3,C_INK);
            
end
begin

                if (1<12) begin pad_col=1; pad_top=346; end
                else begin pad_col=1-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[1]) key_color=C_GUIDE_PALE;
                if (pressed[1]) key_color=C_TEAL;
                if (guide[1] && pressed[1]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[279]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[280]={1'b1,key_color};
                if (guide[1] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[281]={1'b1,C_CORAL};
                if (pressed[1] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[282]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[164]=ascii_candidate(key_left+13,pad_top+18,note_name(60+1),3,C_INK);
            
end
begin

                if (2<12) begin pad_col=2; pad_top=346; end
                else begin pad_col=2-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[2]) key_color=C_GUIDE_PALE;
                if (pressed[2]) key_color=C_TEAL;
                if (guide[2] && pressed[2]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[283]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[284]={1'b1,key_color};
                if (guide[2] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[285]={1'b1,C_CORAL};
                if (pressed[2] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[286]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[165]=ascii_candidate(key_left+13,pad_top+18,note_name(60+2),3,C_INK);
            
end
begin

                if (3<12) begin pad_col=3; pad_top=346; end
                else begin pad_col=3-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[3]) key_color=C_GUIDE_PALE;
                if (pressed[3]) key_color=C_TEAL;
                if (guide[3] && pressed[3]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[287]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[288]={1'b1,key_color};
                if (guide[3] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[289]={1'b1,C_CORAL};
                if (pressed[3] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[290]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[166]=ascii_candidate(key_left+13,pad_top+18,note_name(60+3),3,C_INK);
            
end
begin

                if (4<12) begin pad_col=4; pad_top=346; end
                else begin pad_col=4-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[4]) key_color=C_GUIDE_PALE;
                if (pressed[4]) key_color=C_TEAL;
                if (guide[4] && pressed[4]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[291]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[292]={1'b1,key_color};
                if (guide[4] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[293]={1'b1,C_CORAL};
                if (pressed[4] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[294]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[167]=ascii_candidate(key_left+13,pad_top+18,note_name(60+4),3,C_INK);
            
end
begin

                if (5<12) begin pad_col=5; pad_top=346; end
                else begin pad_col=5-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[5]) key_color=C_GUIDE_PALE;
                if (pressed[5]) key_color=C_TEAL;
                if (guide[5] && pressed[5]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[295]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[296]={1'b1,key_color};
                if (guide[5] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[297]={1'b1,C_CORAL};
                if (pressed[5] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[298]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[168]=ascii_candidate(key_left+13,pad_top+18,note_name(60+5),3,C_INK);
            
end
begin

                if (6<12) begin pad_col=6; pad_top=346; end
                else begin pad_col=6-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[6]) key_color=C_GUIDE_PALE;
                if (pressed[6]) key_color=C_TEAL;
                if (guide[6] && pressed[6]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[299]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[300]={1'b1,key_color};
                if (guide[6] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[301]={1'b1,C_CORAL};
                if (pressed[6] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[302]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[169]=ascii_candidate(key_left+13,pad_top+18,note_name(60+6),3,C_INK);
            
end
begin

                if (7<12) begin pad_col=7; pad_top=346; end
                else begin pad_col=7-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[7]) key_color=C_GUIDE_PALE;
                if (pressed[7]) key_color=C_TEAL;
                if (guide[7] && pressed[7]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[303]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[304]={1'b1,key_color};
                if (guide[7] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[305]={1'b1,C_CORAL};
                if (pressed[7] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[306]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[170]=ascii_candidate(key_left+13,pad_top+18,note_name(60+7),3,C_INK);
            
end
begin

                if (8<12) begin pad_col=8; pad_top=346; end
                else begin pad_col=8-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[8]) key_color=C_GUIDE_PALE;
                if (pressed[8]) key_color=C_TEAL;
                if (guide[8] && pressed[8]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[307]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[308]={1'b1,key_color};
                if (guide[8] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[309]={1'b1,C_CORAL};
                if (pressed[8] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[310]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[171]=ascii_candidate(key_left+13,pad_top+18,note_name(60+8),3,C_INK);
            
end
begin

                if (9<12) begin pad_col=9; pad_top=346; end
                else begin pad_col=9-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[9]) key_color=C_GUIDE_PALE;
                if (pressed[9]) key_color=C_TEAL;
                if (guide[9] && pressed[9]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[311]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[312]={1'b1,key_color};
                if (guide[9] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[313]={1'b1,C_CORAL};
                if (pressed[9] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[314]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[172]=ascii_candidate(key_left+13,pad_top+18,note_name(60+9),3,C_INK);
            
end
begin

                if (10<12) begin pad_col=10; pad_top=346; end
                else begin pad_col=10-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[10]) key_color=C_GUIDE_PALE;
                if (pressed[10]) key_color=C_TEAL;
                if (guide[10] && pressed[10]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[315]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[316]={1'b1,key_color};
                if (guide[10] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[317]={1'b1,C_CORAL};
                if (pressed[10] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[318]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[173]=ascii_candidate(key_left+13,pad_top+18,note_name(60+10),3,C_INK);
            
end
begin

                if (11<12) begin pad_col=11; pad_top=346; end
                else begin pad_col=11-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[11]) key_color=C_GUIDE_PALE;
                if (pressed[11]) key_color=C_TEAL;
                if (guide[11] && pressed[11]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[319]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[320]={1'b1,key_color};
                if (guide[11] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[321]={1'b1,C_CORAL};
                if (pressed[11] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[322]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[174]=ascii_candidate(key_left+13,pad_top+18,note_name(60+11),3,C_INK);
            
end
begin

                if (12<12) begin pad_col=12; pad_top=346; end
                else begin pad_col=12-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[12]) key_color=C_GUIDE_PALE;
                if (pressed[12]) key_color=C_TEAL;
                if (guide[12] && pressed[12]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[323]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[324]={1'b1,key_color};
                if (guide[12] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[325]={1'b1,C_CORAL};
                if (pressed[12] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[326]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[175]=ascii_candidate(key_left+13,pad_top+18,note_name(60+12),3,C_INK);
            
end
begin

                if (13<12) begin pad_col=13; pad_top=346; end
                else begin pad_col=13-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[13]) key_color=C_GUIDE_PALE;
                if (pressed[13]) key_color=C_TEAL;
                if (guide[13] && pressed[13]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[327]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[328]={1'b1,key_color};
                if (guide[13] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[329]={1'b1,C_CORAL};
                if (pressed[13] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[330]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[176]=ascii_candidate(key_left+13,pad_top+18,note_name(60+13),3,C_INK);
            
end
begin

                if (14<12) begin pad_col=14; pad_top=346; end
                else begin pad_col=14-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[14]) key_color=C_GUIDE_PALE;
                if (pressed[14]) key_color=C_TEAL;
                if (guide[14] && pressed[14]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[331]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[332]={1'b1,key_color};
                if (guide[14] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[333]={1'b1,C_CORAL};
                if (pressed[14] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[334]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[177]=ascii_candidate(key_left+13,pad_top+18,note_name(60+14),3,C_INK);
            
end
begin

                if (15<12) begin pad_col=15; pad_top=346; end
                else begin pad_col=15-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[15]) key_color=C_GUIDE_PALE;
                if (pressed[15]) key_color=C_TEAL;
                if (guide[15] && pressed[15]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[335]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[336]={1'b1,key_color};
                if (guide[15] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[337]={1'b1,C_CORAL};
                if (pressed[15] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[338]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[178]=ascii_candidate(key_left+13,pad_top+18,note_name(60+15),3,C_INK);
            
end
begin

                if (16<12) begin pad_col=16; pad_top=346; end
                else begin pad_col=16-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[16]) key_color=C_GUIDE_PALE;
                if (pressed[16]) key_color=C_TEAL;
                if (guide[16] && pressed[16]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[339]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[340]={1'b1,key_color};
                if (guide[16] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[341]={1'b1,C_CORAL};
                if (pressed[16] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[342]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[179]=ascii_candidate(key_left+13,pad_top+18,note_name(60+16),3,C_INK);
            
end
begin

                if (17<12) begin pad_col=17; pad_top=346; end
                else begin pad_col=17-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[17]) key_color=C_GUIDE_PALE;
                if (pressed[17]) key_color=C_TEAL;
                if (guide[17] && pressed[17]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[343]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[344]={1'b1,key_color};
                if (guide[17] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[345]={1'b1,C_CORAL};
                if (pressed[17] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[346]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[180]=ascii_candidate(key_left+13,pad_top+18,note_name(60+17),3,C_INK);
            
end
begin

                if (18<12) begin pad_col=18; pad_top=346; end
                else begin pad_col=18-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[18]) key_color=C_GUIDE_PALE;
                if (pressed[18]) key_color=C_TEAL;
                if (guide[18] && pressed[18]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[347]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[348]={1'b1,key_color};
                if (guide[18] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[349]={1'b1,C_CORAL};
                if (pressed[18] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[350]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[181]=ascii_candidate(key_left+13,pad_top+18,note_name(60+18),3,C_INK);
            
end
begin

                if (19<12) begin pad_col=19; pad_top=346; end
                else begin pad_col=19-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[19]) key_color=C_GUIDE_PALE;
                if (pressed[19]) key_color=C_TEAL;
                if (guide[19] && pressed[19]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[351]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[352]={1'b1,key_color};
                if (guide[19] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[353]={1'b1,C_CORAL};
                if (pressed[19] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[354]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[182]=ascii_candidate(key_left+13,pad_top+18,note_name(60+19),3,C_INK);
            
end
begin

                if (20<12) begin pad_col=20; pad_top=346; end
                else begin pad_col=20-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[20]) key_color=C_GUIDE_PALE;
                if (pressed[20]) key_color=C_TEAL;
                if (guide[20] && pressed[20]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[355]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[356]={1'b1,key_color};
                if (guide[20] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[357]={1'b1,C_CORAL};
                if (pressed[20] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[358]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[183]=ascii_candidate(key_left+13,pad_top+18,note_name(60+20),3,C_INK);
            
end
begin

                if (21<12) begin pad_col=21; pad_top=346; end
                else begin pad_col=21-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[21]) key_color=C_GUIDE_PALE;
                if (pressed[21]) key_color=C_TEAL;
                if (guide[21] && pressed[21]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[359]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[360]={1'b1,key_color};
                if (guide[21] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[361]={1'b1,C_CORAL};
                if (pressed[21] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[362]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[184]=ascii_candidate(key_left+13,pad_top+18,note_name(60+21),3,C_INK);
            
end
begin

                if (22<12) begin pad_col=22; pad_top=346; end
                else begin pad_col=22-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[22]) key_color=C_GUIDE_PALE;
                if (pressed[22]) key_color=C_TEAL;
                if (guide[22] && pressed[22]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[363]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[364]={1'b1,key_color};
                if (guide[22] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[365]={1'b1,C_CORAL};
                if (pressed[22] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[366]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[185]=ascii_candidate(key_left+13,pad_top+18,note_name(60+22),3,C_INK);
            
end
begin

                if (23<12) begin pad_col=23; pad_top=346; end
                else begin pad_col=23-12; pad_top=402; end
                key_left=36+pad_col*61;
                key_color=C_PAPER;
                if (guide[23]) key_color=C_GUIDE_PALE;
                if (pressed[23]) key_color=C_TEAL;
                if (guide[23] && pressed[23]) key_color=C_GOLD;
                if (x>=key_left-1 && x<key_left+58 && y>=pad_top-1 && y<pad_top+49)
                    geometry_leaf[367]={1'b1,C_EDGE};
                if (x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+48)
                    geometry_leaf[368]={1'b1,key_color};
                if (guide[23] && x>=key_left && x<key_left+57 && y>=pad_top && y<pad_top+3)
                    geometry_leaf[369]={1'b1,C_CORAL};
                if (pressed[23] && x>=key_left && x<key_left+57 &&
                    y>=pad_top+44 && y<pad_top+48) geometry_leaf[370]={1'b1,C_TEAL};
                // Note names are the single pad label; no overlapping tiny serial number.
                text_leaf[186]=ascii_candidate(key_left+13,pad_top+18,note_name(60+23),3,C_INK);
            
end
            text_leaf[187]=cjk_candidate(36,319,32'h6309952E,2,C_WHITE); text_leaf[188]=ascii_candidate(100,326,"C4-B5",5,C_WHITE);
        end

        // The last two FSR16 notes are additional live inputs above the
        // unchanged two-octave keyboard. Never highlight them from a guide.
        if (x>=220 && x<227 && y>=326 && y<333)
            geometry_leaf[371]={1'b1,pressed[24] && upper_guide[0] ? C_GOLD :
                pressed[24] ? C_TEAL : upper_guide[0] ? C_CORAL : C_EDGE};
        text_leaf[189]=ascii_candidate(236,319,"C6",2,pressed[24] ? C_TEAL : upper_guide[0] ? C_CORAL : C_MUTED);
        if (x>=292 && x<299 && y>=326 && y<333)
            geometry_leaf[372]={1'b1,pressed[26] && upper_guide[1] ? C_GOLD :
                pressed[26] ? C_TEAL : upper_guide[1] ? C_CORAL : C_EDGE};
        text_leaf[190]=ascii_candidate(308,319,"D6",2,pressed[26] ? C_TEAL : upper_guide[1] ? C_CORAL : C_MUTED);

        if (x>=472 && x<479 && y>=326 && y<333) geometry_leaf[373]={1'b1,C_TEAL};
        text_leaf[191]=cjk_candidate(486,319,32'h8F935165,2,C_MUTED);
        if (x>=546 && x<553 && y>=326 && y<333) geometry_leaf[374]={1'b1,C_CORAL};
        text_leaf[192]=cjk_candidate(560,319,32'h63075F15,2,C_MUTED);
        text_leaf[193]=cjk_candidate(618,319,32'h529B5EA6,2,C_MUTED);
        if (x>=668 && x<764 && y>=327 && y<332) geometry_leaf[375]={1'b1,C_EDGE};
        fill_width=(expression==127) ? 96 : (expression*96)>>7;
        if (x>=668 && x<668+fill_width && y>=327 && y<332) geometry_leaf[376]={1'b1,C_TEAL};

        // Controls keep the proven layout; add the requested hold actions.
        text_leaf[194]=ascii_candidate(24,458,"S1",2,C_MUTED);
        if(ui_mode==3) text_leaf[195]=cjk_candidate(48,458,(demo_mode && playing) ? 32'h6682505C : 32'h8BD5542C,2,C_MUTED);
        else text_leaf[196]=cjk_candidate(48,458,demo_mode ? 32'h64AD653E : 32'h975997F3,2,C_MUTED);
        text_leaf[197]=cjk_candidate(106,458,64'h957F630966F276EE,4,C_MUTED);
        text_leaf[198]=ascii_candidate(258,458,"S2",2,C_MUTED);
        if(ui_mode==3) text_leaf[199]=cjk_candidate(282,458,48'h4E0B4E009996,3,C_MUTED);
        else text_leaf[200]=cjk_candidate(282,458,32'h97F38272,2,C_MUTED);
        text_leaf[201]=cjk_candidate(ui_mode==3 ? 366 : 340,458,64'h957F63094E505668,4,C_MUTED);
        text_leaf[202]=ascii_candidate(514,458,"S3",2,C_MUTED);
        text_leaf[203]=cjk_candidate(538,458,32'h98759762,2,C_MUTED);
        text_leaf[204]=cjk_candidate(596,458,64'h957F63096A215F0F,4,C_MUTED);
        text_leaf[217]=cjk_candidate(350,319,32'h97F391CF,2,C_MUTED);
        text_leaf[218]=ascii_candidate(398,319,{decimal3(volume_percent),8'h25},4,
                                      volume_step==0 ? C_CORAL : C_WHITE);
        if(volume_edit)begin
            // Suppress the old footer captions while the keys edit volume.
            for(i=194;i<=204;i=i+1)text_leaf[i]=0;
            text_leaf[219]=ascii_candidate(24,458,"S1 -5%",6,C_MUTED);
            text_leaf[220]=ascii_candidate(258,458,"S2 +5%",6,C_MUTED);
            text_leaf[221]=ascii_candidate(514,458,"S3 EXIT",7,C_MUTED);
        end
        text_leaf[222]=ascii_candidate(700,458,"1+2 VOL",7,C_MUTED);
        // Keep status outside page titles and completely out of the volume
        // overlay. SYNTH distinguishes our generated backing from a recording.
        // 波形页不画这行伴奏状态：它的位置 (510,104) 正好压在示波器网格上
        if(!volume_edit && ui_mode!=3'd4)begin
            if(practice_active && (ui_mode==0 || ui_mode==1))begin
                text_leaf[108]=0;
                text_leaf[232]=cjk_candidate(300,104,practice_mode==2 ? 32'h901097F3 : 32'h8DDF8C31,2,C_TEAL);
            end
            text_leaf[233]=cjk_candidate(ui_mode==3 ? 350 : 510,104,
                backing_enabled ? 64'h540862104F34594F : 64'h4F34594F517395ED,4,backing_enabled ? C_TEAL : C_STAFF);
        end
        if(practice_active && !volume_edit)begin
            text_leaf[195]=0;text_leaf[196]=0;
            text_leaf[196]=cjk_candidate(48,458,playing ? 32'h6682505C : 32'h6F14594F,2,C_MUTED);
        end

        // In the practice stage show all sixteen physical channels in 4x4
        // order, including C6/D6, instead of implying 24 playable chromatic pads.
        if(practice_stage)begin
            for(i=137;i<=188;i=i+1)text_leaf[i]=0;
            text_leaf[187]=cjk_candidate(36,319,32'h6309952E,2,C_WHITE);
            text_leaf[188]=ascii_candidate(100,319,"01-16",5,C_WHITE);
            if(x>=24 && x<776 && y>=340 && y<459)geometry_leaf[404]={1'b1,C_PANEL};
            for(i=0;i<16;i=i+1)begin
                key_left=36+(i%4)*184;pad_top=346+(i/4)*28;
                key_bit=pressure_pitch(i);
                is_current=playing && !guide_completed && target_note==60+key_bit;
                key_color=pressed[key_bit] ? (is_current ? C_GOLD : C_TEAL) :
                          (is_current ? C_GUIDE_PALE : C_PAPER);
                if(x>=key_left && x<key_left+176 && y>=pad_top && y<pad_top+24)
                    geometry_leaf[405+i*3]={1'b1,key_color};
                if(is_current && x>=key_left && x<key_left+4 && y>=pad_top && y<pad_top+24)
                    geometry_leaf[406+i*3]={1'b1,C_CORAL};
                if(pressed[key_bit] && x>=key_left && x<key_left+176 && y>=pad_top+21 && y<pad_top+24)
                    geometry_leaf[407+i*3]={1'b1,C_TEAL};
                text_leaf[137+i*2]=ascii_candidate(key_left+12,pad_top+2,pad_number(60+key_bit),2,C_STAFF);
                text_leaf[138+i*2]=ascii_candidate(key_left+106,pad_top+2,note_name(60+key_bit),3,C_INK);
            end
        end

        // The analysis pages own their central text layer as well as its background.
        if(ui_mode>=4 && ui_mode<=6 && y>=88 && y<312)
            for(clear_slot=0;clear_slot<TEXT_LEAVES;clear_slot=clear_slot+1)text_leaf[clear_slot]=0;

        // A dedicated dark track replaces the staff only in rhythm/auto-guide view.
        // No judgement or score is invented by the automatic guide.
        if(track_enabled && y>=88 && y<312) begin
            for(clear_slot=0;clear_slot<TEXT_LEAVES;clear_slot=clear_slot+1)text_leaf[clear_slot]=0;
            if(x>=24 && x<776)geometry_leaf[452]={1'b1,C_SCOPE_BG};
            for(i=0;i<25;i=i+1)
                if(x==298+i*19 && y>=116 && y<300)geometry_leaf[452]={1'b1,C_SCOPE_GRID};
            text_leaf[300]=ascii_candidate_long(40,102,game_enable?"RHYTHM":"SCORE GUIDE",game_enable?6:11,C_W1);
            text_leaf[301]=ascii_candidate(40,144,"NOW",3,C_MUTED);
            text_leaf[302]=note_candidate_large(40,167,note_name(score_notes[active_slot*7+:7]),C_GOLD);
            text_leaf[303]=ascii_candidate(168,144,"NEXT",4,C_MUTED);
            text_leaf[304]=note_candidate_large(168,167,active_slot==7?"---":note_name(next_note),C_W1);
            text_leaf[305]=ascii_candidate_long(40,225,"FOLLOW THE NOTES",16,C_WHITE);
            text_leaf[306]=ascii_candidate_long(40,255,game_enable?"PLAY TO JUDGE":"AUTO / TEST INPUT",game_enable?13:17,C_MUTED);
            text_leaf[307]=ascii_candidate(300,96,"C4",2,C_MUTED);
            text_leaf[308]=ascii_candidate(528,96,"C5",2,C_MUTED);
            text_leaf[309]=ascii_candidate(718,96,"B5",2,C_MUTED);
        end

        // ===================================================================
        //  音游 HUD（B3）—— 把 rhythm_judge 的判定结果真正画到屏上
        //    1) 命中闪光：判定后主面板内缘描一圈判定色（余光也能看见）
        //    2) 判定弹窗：居中不透明浮层 + 判定色边框 + 中英文判定词
        //    3) 底部状态条：BEST / COMBO / SCORE / P / G / M
        //  叶子索引全部避开既有 UI：几何 453..457，文字 256..268。
        //  只在 game_enable 时画，关掉音游时屏幕上不留任何痕迹。
        // ===================================================================
        if (track_enabled) begin
            if (game_enable && game_judge_hold != 6'd0) begin
                // 命中闪光边框（主面板内缘 3px，y 88..312）
                if (x>=24 && x<776 && ((y>=88 && y<91) || (y>=309 && y<312)))
                    geometry_leaf[453]={1'b1,C_JUDGE};
                if (y>=88 && y<312 && ((x>=24 && x<27) || (x>=773 && x<776)))
                    geometry_leaf[454]={1'b1,C_JUDGE};
                // 判定弹窗：底板 + 上下边框 + 左右边框
                if (x>=320 && x<480 && y>=150 && y<210)
                    geometry_leaf[455]={1'b1,C_PANEL};
                if (x>=320 && x<480 && ((y>=150 && y<152) || (y>=208 && y<210)))
                    geometry_leaf[456]={1'b1,C_JUDGE};
                if (y>=150 && y<210 && ((x>=320 && x<322) || (x>=478 && x<480)))
                    geometry_leaf[457]={1'b1,C_JUDGE};
                // 判定词：中文 22px 步进居中，英文 10px 步进居中
                if (game_judge == 2'd1) begin
                    text_leaf[256]=cjk_candidate(378,156,32'h5B8C7F8E,2,C_GOLD);  // 完美
                    text_leaf[257]=ascii_candidate(365,184,"PERFECT",7,C_GOLD);
                end else if (game_judge == 2'd2) begin
                    text_leaf[256]=cjk_candidate(378,156,32'h826F597D,2,C_TEAL);  // 良好
                    text_leaf[257]=ascii_candidate(380,184,"GOOD",4,C_TEAL);
                end else begin
                    text_leaf[256]=cjk_candidate(378,156,32'h59318BEF,2,C_RED);   // 失误
                    text_leaf[257]=ascii_candidate(380,184,"MISS",4,C_RED);
                end
            end
            // 底部状态条：x 100..584，避开左边的模式字(48..92)与右边的音量字(700..770)
            text_leaf[260]=ascii_candidate(110,460,"BEST",4,C_MUTED);
            text_leaf[261]=ascii_candidate(152,460,decimal3(game_best_combo),3,C_WHITE);
            text_leaf[262]=ascii_candidate(200,460,"COMBO",5,
                               (game_combo >= 8'd8) ? C_GOLD : C_MUTED);
            text_leaf[263]=ascii_candidate(252,460,decimal3(game_combo),3,
                               (game_combo >= 8'd8) ? C_GOLD : C_WHITE);
            text_leaf[264]=ascii_candidate(300,460,"SCORE",5,C_MUTED);
            text_leaf[265]=ascii_candidate(352,460,bcd6_ascii(game_score_bcd),6,C_GOLD);
            text_leaf[266]=ascii_candidate(430,460,"P",1,C_GOLD);
            text_leaf[267]=ascii_candidate(442,460,decimal3(game_pf),3,C_GOLD);
            text_leaf[268]=ascii_candidate(486,460,"G",1,C_TEAL);
            text_leaf[269]=ascii_candidate(498,460,decimal3(game_gd),3,C_TEAL);
            text_leaf[270]=ascii_candidate(542,460,"M",1,C_RED);
            text_leaf[271]=ascii_candidate(554,460,decimal3(game_ms),3,C_RED);
            // ---- 下落式轨道：判定线 + 左右边线 + 下落音符块 ----
            //  几何叶子 458..460（453..457 已给判定弹窗/闪光）
            if (x>=296 && x<770 && y>=300 && y<304)
                geometry_leaf[458]={1'b1,C_GOLD};
            if (y>=96 && y<306 && ((x>=296 && x<298) || (x>=768 && x<770)))
                geometry_leaf[459]={1'b1,C_EDGE};
            if (fall_hit)
                geometry_leaf[460]={1'b1,fall_color};
        end

        // ===================================================================
        //  实时波形示波器（ui_mode==4）
        // -------------------------------------------------------------------
        //  队友那版是 64 点、抽稀 8 的稀疏虚线折线：点太少、没网格、幅度小、
        //  看不出音头。这版改成：
        //    · 180 列 × 4px 的**连续**波形（填充 + 亮描边，描边取相邻两列的
        //      min..max，保证相邻列之间不断线——稀疏虚线就是断在这儿的）
        //    · 幅度分三档配色，接近满刻度变橙红，一眼看出要过载
        //    · 中心 / ±50% / ±100% 横向网格 + 每 60px 纵向网格
        //    · 峰值保持包络（上下两条线，立即上升、约 10ms 回落一格）
        //    · 顶部 ASCII 读数 PEAK / LEVEL / 采样率，底部窗长提示
        //  几何叶子 461..468，文字叶子 273..279（页签"WAVE"占了 272）。
        // ===================================================================
        if (ui_mode == 3'd4) begin
            // 深色示波底：叶子号 > 7，优先级高于默认纸色面板，直接盖掉
            if (x>=24 && x<776 && y>=88 && y<312)
                geometry_leaf[461]={1'b1,C_SCOPE_BG};
            // 横向网格
            if (x>=WAVE_L && x<WAVE_R && y==WAVE_MID)
                geometry_leaf[462]={1'b1,C_SCOPE_MID};
            if (x>=WAVE_L && x<WAVE_R && (y==152 || y==248))
                geometry_leaf[463]={1'b1,C_SCOPE_GRID};
            if (x>=WAVE_L && x<WAVE_R && (y==104 || y==296))
                geometry_leaf[464]={1'b1,C_SCOPE_GRID};
            // 纵向网格：每 60px 一条
            grid_v=1'b0;
            for(i=0;i<13;i=i+1) if(x==WAVE_L+i*60) grid_v=1'b1;
            if (grid_v && y>=104 && y<296)
                geometry_leaf[465]={1'b1,C_SCOPE_GRID};
            // 峰值保持包络（peak==0 时两条线重合在中线上，自然不可见）
            if (x>=WAVE_L && x<WAVE_R && view_peak_q!=0 &&
                (y==wave_pk_top || y==wave_pk_bot))
                geometry_leaf[466]={1'b1,C_W3};
            if (x>=WAVE_L && x<WAVE_R) begin
                // 填充：中线 → 轨迹
                if (y>=wave_top && y<wave_bot) geometry_leaf[467]={1'b1,wfill_q};
                // 描边：±1px 加粗，避免细线在高分辨率屏上闪
                if (y>=wave_hi-9'd1 && y<wave_lo+9'd1) geometry_leaf[468]={1'b1,wline_q};
            end
            text_leaf[273]=ascii_candidate(40,94,"PEAK",4,C_MUTED);
            text_leaf[274]=ascii_candidate(90,94,decimal3(peak_pct_q),3,C_W3);
            text_leaf[275]=ascii_candidate(126,94,"LEVEL",5,C_MUTED);
            text_leaf[276]=ascii_candidate(186,94,decimal3(level_pct_q),3,C_W2);
            text_leaf[277]=ascii_candidate(232,94,"48KHZ/16",8,C_MUTED);
            text_leaf[278]=ascii_candidate_long(40,292,"SCOPE 60MS",10,C_MUTED);
            text_leaf[279]=ascii_candidate(660,292,wave_zoom_text,8,C_MUTED);
            // 三键短/长按之后，到本页即可读出当前档位，不靠记忆或猜。
            text_leaf[280]=ascii_candidate(430,94,fx_status_text,7,
                                           fx_mode==0 ? C_MUTED : C_TEAL);
            text_leaf[281]=ascii_candidate(580,94,test_status_text,8,
                                           test_sel==0 ? C_MUTED : C_CORAL);
        end

        // ===================================================================
        //  第 6 页 SPEC：32 频点实时频谱柱图
        //  柱宽 12px + 间距 4px（列号 = (x-48)>>4，纯移位）；
        //  幅度对数刻度 0..63 → 柱高 0..189px；峰值保持线 ~0.24 s 回落一格。
        //  几何叶子 472..478，文字叶子 284..292。
        // ===================================================================
        if (ui_mode == 3'd5) begin
            // 深色示波底（优先级高于默认纸色面板）
            if (x>=24 && x<776 && y>=88 && y<312)
                geometry_leaf[472]={1'b1,C_SCOPE_BG};
            // 底线 + 等分横格（1/4、1/2、3/4 高度）
            if (x>=48 && x<560 && y==296)
                geometry_leaf[473]={1'b1,C_SCOPE_MID};
            if (x>=48 && x<560 && (y==249 || y==202 || y==155))
                geometry_leaf[474]={1'b1,C_SCOPE_GRID};
            // 每 4 根柱一条纵向格线
            grid_v=1'b0;
            for(i=0;i<9;i=i+1) if(x==48+i*64) grid_v=1'b1;
            if (grid_v && y>=104 && y<296)
                geometry_leaf[475]={1'b1,C_SCOPE_GRID};
            // 柱体：填充 + 顶部 2px 亮沿；峰值保持 = 2px 亮线
            if (x>=48 && x<560 && sx1[3:0]<12) begin
                if (y>=bar_top && y<296) geometry_leaf[476]={1'b1,bar_color};
                if (y>=bar_top && y<bar_top+9'd2 && bar_level_q!=0)
                    geometry_leaf[477]={1'b1,bar_color};
                if ((y==peak_top || y==peak_top-9'd1) && bar_peak_q!=0)
                    geometry_leaf[478]={1'b1,C_GOLD};
            end
            text_leaf[284]=ascii_candidate(40,94,"SPEC",4,C_MUTED);
            text_leaf[285]=ascii_candidate(430,94,fx_status_text,7,
                                           fx_mode==0 ? C_MUTED : C_TEAL);
            text_leaf[286]=ascii_candidate(580,94,test_status_text,8,
                                           test_sel==0 ? C_MUTED : C_CORAL);
            text_leaf[287]=ascii_candidate(46,300,"C3",2,C_MUTED);
            text_leaf[288]=ascii_candidate(238,300,"C4",2,C_MUTED);
            text_leaf[289]=ascii_candidate(382,300,"A4",2,C_MUTED);
            text_leaf[290]=ascii_candidate(542,300,"G5",2,C_MUTED);
            text_leaf[291]=ascii_candidate_long(580,142,"32BIN LOG",9,C_WHITE);
            text_leaf[292]=ascii_candidate(580,176,"4096PTS",7,C_MUTED);
            text_leaf[310]=ascii_candidate(580,210,"6KHZ",4,C_MUTED);
            text_leaf[311]=ascii_candidate(580,244,"0.683SEC",8,C_MUTED);
            text_leaf[312]=ascii_candidate(580,278,"C3 - G5",7,C_W1);
        end

        // ===================================================================
        //  第 7 页 LISS：双通道李萨如图
        //  X = 主合成（效果器后），Y = 伴奏层；96×96 光栅，
        //  每个点 4×2 px，余辉约 48 ms。Y 轴静音时明确提示，不伪装。
        //  几何叶子 480..484，文字叶子 293..298。
        // ===================================================================
        if (ui_mode == 3'd6) begin
            // 深色示波底
            if (x>=24 && x<776 && y>=88 && y<312)
                geometry_leaf[480]={1'b1,C_SCOPE_BG};
            // 图形边框（上下 / 左右）
            if (x>=206 && x<594 && (y==102 || y==297))
                geometry_leaf[481]={1'b1,C_SCOPE_MID};
            if ((x==206 || x==593) && y>=102 && y<298)
                geometry_leaf[482]={1'b1,C_SCOPE_MID};
            // 中心十字（淡）
            if (x>=208 && x<592 && y==200)
                geometry_leaf[483]={1'b1,C_SCOPE_GRID};
            if (x==400 && y>=104 && y<296)
                geometry_leaf[483]={1'b1,C_SCOPE_GRID};
            // 光栅点
            if (x>=208 && x<592 && y>=104 && y<296 && liss_pix)
                geometry_leaf[484]={1'b1,C_W1};
            text_leaf[293]=ascii_candidate_long(40,94,"LISSAJOUS AUTO",14,C_MUTED);
            text_leaf[294]=ascii_candidate(40,292,"X=SYNTH",7,C_TEAL);
            text_leaf[295]=ascii_candidate(660,94,"12KHZ",5,C_MUTED);
            text_leaf[296]=ascii_candidate(660,292,"96X96",5,C_MUTED);
            if (liss_mail[14])
                text_leaf[297]=ascii_candidate_long(126,292,"Y=ACC(OFF)",10,C_RED);
            else
                text_leaf[297]=ascii_candidate_long(126,292,"Y=ACC",5,C_TEAL);
            text_leaf[298]=ascii_candidate(430,94,fx_status_text,7,
                                           fx_mode==0 ? C_MUTED : C_TEAL);
        end


        // Visible attribution: autonomous test input, not a live sensor claim.
        if(showcase_active && y>=444) begin
            for(clear_slot=0;clear_slot<TEXT_LEAVES;clear_slot=clear_slot+1) text_leaf[clear_slot]=0;
            for(clear_slot=0;clear_slot<GEOMETRY_LEAVES;clear_slot=clear_slot+1) geometry_leaf[clear_slot]=0;
            geometry_leaf[0]={1'b1,C_BG};
            text_leaf[0]=ascii_candidate_long(24,458,showcase_label,32,C_TEAL);
            text_leaf[1]=ascii_candidate_long(400,458,showcase_hold ? "HOLD S1:RUN  S2:NEXT S3:PAGE" : "AUTO S1:HOLD S2:NEXT S3:PAGE",28,C_WHITE);
        end

        if (!de || x>=800 || y>=480) begin
            geometry_leaf[511]={1'b1,18'd0};
        end
    end

    // Coverage ROM and the registered base pixel are aligned after one edge.
    // The blend preserves background at alpha0, exact text color at alpha3.
    always @* begin
        coverage=0;
        if(valid_q && gx_q<20)coverage=row_alpha[39-gx_q*2 -:2];
        rgb666={blend6(base_rgb_q[17:12],color_q[17:12],coverage),
                blend6(base_rgb_q[11:6],color_q[11:6],coverage),
                blend6(base_rgb_q[5:0],color_q[5:0],coverage)};
        if(!display_de || !reset_n)rgb666=0;
    end
endmodule
