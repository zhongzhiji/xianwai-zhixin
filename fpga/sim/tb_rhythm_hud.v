`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_rhythm_hud.v —— 音游 HUD 像素级回归
//
// 验证的不是 rhythm_judge 的算法（那个已有 tb），而是"判定结果确实被画到
// 屏上"这件事本身。LCD UI 最常见的失败模式是：逻辑跑通了、波形里也看到
// judge_pulse 了，但因为叶子索引冲突 / 端口漏接，屏幕上一个像素都没变。
//
// 直接例化真实渲染器 + 真实字体 ROM，逐点送 (x,y)，等 4 拍流水线后读颜色。
// ---------------------------------------------------------------------------
module tb_rhythm_hud;

    reg        pixel_clk = 1'b0;
    reg        reset_n   = 1'b0;
    reg        de        = 1'b1;
    reg [11:0] x         = 12'd0;
    reg [11:0] y         = 12'd0;

    // 既有 UI 输入全部置 0（只关心 HUD，不与既有界面抢）
    wire [31:0] pressed = 32'd0;
    wire [23:0] guide   = 24'd0;
    wire [55:0] score_notes   = 56'd0;
    wire [31:0] score_lengths = 32'd0;
    wire [2:0]  active_slot   = 3'd0;
    wire [7:0]  page_index    = 8'd0;
    wire [6:0]  progress      = 7'd0;
    wire        playing       = 1'b0;
    wire [1:0]  timbre        = 2'd0;
    wire [7:0]  bpm           = 8'd100;
    wire [6:0]  expression    = 7'd64;
    wire [4:0]  volume_step   = 5'd12;
    wire        volume_edit   = 1'b0;
    wire [1:0]  practice_mode = 2'd0;
    wire        backing_enabled = 1'b0;
    wire [6:0]  target_note   = 7'd0;
    wire [7:0]  guide_hits    = 8'd0, guide_errors = 8'd0;
    wire        guide_completed = 1'b0, guide_unsupported = 1'b0, guide_wrong = 1'b0;
    wire [1:0]  upper_guide   = 2'd0;
    wire        demo_mode     = 1'b0;
    wire [2:0]  ui_mode       = 3'd0;
    wire [1:0]  instrument    = 2'd0;
    wire        imported_score = 1'b0;
    wire [2:0]  song_id       = 3'd0;
    wire [2:0]  input_online  = 3'd0;

    // HUD 输入
    reg        game_enable     = 1'b0;
    reg [1:0]  game_judge      = 2'd0;
    reg [5:0]  game_judge_hold = 6'd0;
    reg [7:0]  game_combo      = 8'd0;
    reg [7:0]  game_best_combo = 8'd0;
    reg [31:0] game_score_bcd  = 32'd0;
    reg [7:0]  game_pf = 8'd0, game_gd = 8'd0, game_ms = 8'd0;

    wire        display_de;
    wire [17:0] rgb666;

    score_ui_renderer uut(
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .de(de), .x(x), .y(y),
        .pressed(pressed), .guide(guide),
        .score_notes(score_notes), .score_lengths(score_lengths),
        .active_slot(active_slot), .page_index(page_index),
        .progress(progress), .playing(playing), .timbre(timbre), .bpm(bpm),
        .expression(expression), .volume_step(volume_step), .volume_edit(volume_edit),
        .practice_mode(practice_mode), .backing_enabled(backing_enabled),
        .target_note(target_note), .guide_hits(guide_hits), .guide_errors(guide_errors),
        .guide_completed(guide_completed), .guide_unsupported(guide_unsupported),
        .guide_wrong(guide_wrong), .upper_guide(upper_guide),
        .demo_mode(demo_mode), .ui_mode(ui_mode), .instrument(instrument),
        .imported_score(imported_score), .song_id(song_id), .input_online(input_online),
        .game_enable(game_enable), .game_judge(game_judge),
        .game_judge_hold(game_judge_hold),
        .game_combo(game_combo), .game_best_combo(game_best_combo),
        .game_score_bcd(game_score_bcd),
        .game_pf(game_pf), .game_gd(game_gd), .game_ms(game_ms),
        .wave_mail(25'd0), .fx_mode(2'd0), .test_sel(3'd0),
        .display_de(display_de), .rgb666(rgb666));

    always #10 pixel_clk = ~pixel_clk;

    integer errors = 0;
    task chk;
        input [255:0] name;
        input cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin
                $display("[FAIL] %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // 送一个像素，等 4 拍流水线，取回输出
    reg [17:0] px_rgb;
    reg        px_de;
    task get_pixel;
        input [11:0] px;
        input [11:0] py;
        begin
            x = px; y = py;
            repeat (6) @(posedge pixel_clk);
            #1;
            px_rgb = rgb666;
            px_de  = display_de;
        end
    endtask

    reg [17:0] off_panel, off_strip, on_panel, on_strip, on_border, on_flash;
    reg [17:0] c_gold, c_teal, c_red, c_panel;

    initial begin
        c_gold  = {6'd61, 6'd43, 6'd25};
        c_teal  = {6'd22, 6'd39, 6'd36};
        c_red   = {6'd55, 6'd16, 6'd16};
        c_panel = {6'd10, 6'd11, 6'd12};

        #100 reset_n = 1'b1;
        #200;

        // ---------- 1. 音游关：HUD 区必须是原来的样子 ----------
        game_enable = 1'b0;
        get_pixel(12'd330, 12'd155);  off_panel = px_rgb;   // 弹窗区（未画）
        get_pixel(12'd110, 12'd465);  off_strip = px_rgb;   // 底部条（未画）
        chk("音游关时弹窗区不是判定面板色", off_panel !== c_panel);
        chk("音游关时 display_de 有效", px_de === 1'b1);

        // ---------- 2. 音游开 + PERFECT ----------
        game_enable     = 1'b1;
        game_judge      = 2'd1;        // PERFECT
        game_judge_hold = 6'd20;
        game_combo      = 8'd12;
        game_best_combo = 8'd34;
        game_score_bcd  = 32'h00001234;
        game_pf = 8'd7; game_gd = 8'd3; game_ms = 8'd1;
        #40;

        get_pixel(12'd330, 12'd155);  on_panel = px_rgb;
        chk("PERFECT：弹窗底板已绘制", on_panel === c_panel);

        get_pixel(12'd400, 12'd151);  on_border = px_rgb;
        chk("PERFECT：弹窗上边框 = 金色", on_border === c_gold);

        get_pixel(12'd400, 12'd89);   on_flash = px_rgb;
        chk("PERFECT：主面板命中闪光边框 = 金色", on_flash === c_gold);

        get_pixel(12'd110, 12'd465);  on_strip = px_rgb;
        $display("  [DBG ] HUD strip off=%06h on=%06h",off_strip,on_strip);
        chk("底部状态条已绘制（与关闭时不同）", on_strip !== off_strip);

        // ---------- 3. 判定色随 judge_code 切换 ----------
        game_judge = 2'd2;   // GOOD
        #40;
        get_pixel(12'd400, 12'd151);
        chk("GOOD：弹窗边框 = 青色", rgb666 === c_teal);

        game_judge = 2'd3;   // MISS
        #40;
        get_pixel(12'd400, 12'd151);
        chk("MISS：弹窗边框 = 红色", rgb666 === c_red);

        // ---------- 4. hold 归零后弹窗必须消失（不能糊在屏上）----------
        game_judge_hold = 6'd0;
        #40;
        get_pixel(12'd330, 12'd155);
        // Rhythm now has a dedicated dark track, even after the popup expires.
        chk("hold=0 后弹窗消失", rgb666 === {6'd5,6'd7,6'd11});
        get_pixel(12'd400, 12'd89);
        chk("hold=0 后命中闪光消失", rgb666 !== c_red);
        get_pixel(12'd110, 12'd465);
        chk("hold=0 后底部状态条仍在", rgb666 === on_strip);

        // ---------- 5. 屏幕外不画 ----------
        get_pixel(12'd900, 12'd155);
        chk("x>=800 时 display_de 无效", px_de === 1'b0);

        #200;
        if (errors == 0) $display("\n===== 全部用例通过 =====\n");
        else             $display("\n===== 失败 %0d 项 =====\n", errors);
        $finish;
    end

endmodule
