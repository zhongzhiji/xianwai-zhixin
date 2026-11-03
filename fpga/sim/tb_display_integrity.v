`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_visual_pages.v —— SPEC / LISS 两个新页的像素级回归
//
// 验证的不是 Goertzel / 李萨如前端算法（各自有 tb_spectrum_goertzel /
// tb_lissajous_scope），而是"数据确实被画到屏上"这件事本身：
//   1) 频谱：给 bin10 level=40，柱区像素必须是柱色，柱外必须是底色，
//      峰值线必须是金色；
//   2) 李萨如：给点 (30,30)，对应像素必须点亮，相邻列必须保持底色。
// 直接例化真实渲染器 + 真实字体 ROM，逐点送 (x,y)，等流水线后读颜色，
// 与 tb_rhythm_hud 完全同一套方法。
// ---------------------------------------------------------------------------
module tb_display_integrity;

    reg        pixel_clk = 1'b0;
    reg        reset_n   = 1'b0;
    reg        de        = 1'b1;
    reg [11:0] x         = 12'd0;
    reg [11:0] y         = 12'd0;
    reg [2:0]  ui_mode   = 3'd0;
    reg [13:0] spec_mail = 14'd0;
    reg [15:0] liss_mail = 16'd0;

    wire        display_de;
    wire [17:0] rgb666;

    score_ui_renderer #(.LISS_CLEAR_CYCLES(8)) uut(
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .de(de), .x(x), .y(y),
        .pressed(32'd0), .guide(24'd0),
        .score_notes(56'd0), .score_lengths(32'd0),
        .active_slot(3'd0), .page_index(8'd0),
        .progress(7'd0), .playing(1'b0), .timbre(2'd0), .bpm(8'd100),
        .expression(7'd64), .volume_step(5'd12), .volume_edit(1'b0),
        .practice_mode(2'd0), .backing_enabled(1'b0),
        .target_note(7'd0), .guide_hits(8'd0), .guide_errors(8'd0),
        .guide_completed(1'b0), .guide_unsupported(1'b0),
        .guide_wrong(1'b0), .upper_guide(2'd0),
        .demo_mode(1'b0), .ui_mode(ui_mode), .instrument(2'd0),
        .imported_score(1'b0), .song_id(3'd0), .input_online(3'd0),
        .game_enable(1'b0), .game_judge(2'd0),
        .game_judge_hold(6'd0),
        .game_combo(8'd0), .game_best_combo(8'd0),
        .game_score_bcd(32'd0),
        .game_pf(8'd0), .game_gd(8'd0), .game_ms(8'd0),
        .wave_mail(25'd0),
        .spec_mail(spec_mail), .liss_mail(liss_mail),
        .showcase_active(1'b1), .showcase_hold(1'b0), .showcase_stage(5'd19),
        .fx_mode(2'd0), .test_sel(3'd0),
        .display_de(display_de), .rgb666(rgb666));

    always #10 pixel_clk = ~pixel_clk;

    integer errors = 0;
    integer scan,jj;
    reg [3:0] exp_de=0;
    reg [17:0] exp_color[0:3];
    task chk;
        input [319:0] name;
        input cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin
                $display("[FAIL] %0s", name);
                errors = errors + 1;
            end
        end
    endtask

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

    localparam [17:0] C_SCOPE_BG = {6'd5,  6'd7,  6'd11};
    localparam [17:0] C_W1       = {6'd18, 6'd54, 6'd50};
    localparam [17:0] C_W2F      = {6'd24, 6'd19, 6'd9};
    localparam [17:0] C_GOLD     = {6'd61, 6'd43, 6'd25};

    initial begin
        #100 reset_n = 1'b1;
        #200;

        // ================= 第 6 页 SPEC =================
        ui_mode = 3'd5;
        // 给 bin10 送 level=40：bar_top = 296-40*3 = 176，peak_top = 176
        spec_mail = {1'b1, 5'd10, 8'd40};
        repeat (6) @(posedge pixel_clk); #1;

        // 柱内（bin10 → x = 48+10*16+6 = 214，y=290 在 176..296 之间）
        get_pixel(12'd214, 12'd290);
        chk("SPEC 柱内是柱色",          px_rgb === {6'd58,6'd46,6'd16});
        chk("SPEC display_de 有效",     px_de  === 1'b1);
        // 柱上方（y=150 < 176）是深色底
        get_pixel(12'd214, 12'd150);
        chk("SPEC 柱上方是底色",        px_rgb === C_SCOPE_BG);
        // 峰值线（y=175 = peak_top-1）
        get_pixel(12'd214, 12'd175);
        chk("SPEC 峰值线是金色",        px_rgb === C_GOLD);
        // 相邻空柱（bin11 → x = 48+11*16+6 = 230，level=0 不画）
        get_pixel(12'd230, 12'd290);
        chk("SPEC 空柱保持底色",        px_rgb === C_SCOPE_BG);

        // ================= 第 7 页 LISS =================
        ui_mode = 3'd6;
        // 给点 (30,30)：像素 x = 208+30*4+2 = 330，y = 104+30*2 = 164
        liss_mail = {1'b1, 1'b0, 7'd30, 7'd30};
        repeat (6) @(posedge pixel_clk); #1;

        get_pixel(12'd330, 12'd164);
        chk("LISS 打点像素点亮",        px_rgb === C_W1);
        // 相邻列（col31 → x=334）无点保持底色
        get_pixel(12'd334, 12'd164);
        chk("LISS 相邻列保持底色",      px_rgb === C_SCOPE_BG);
        // 盒外（x=100）保持底色
        get_pixel(12'd100, 12'd164);
        chk("LISS 盒外保持底色",        px_rgb === C_SCOPE_BG);

        // Positive full-scale X maps to the rightmost valid column, not offscreen.
        liss_mail={~liss_mail[15],1'b0,7'd95,7'd30};
        get_pixel(590,164);
        chk("rightmost Lissajous column visible",px_rgb===C_W1);
        repeat(780)@(posedge pixel_clk);#1;
        get_pixel(590,164);
        chk("old trace clears without any new mailbox",px_rgb===C_SCOPE_BG);
        chk("negative full-scale sample has high-level colour",
            uut.wave_line_of(8'h80)==={6'd61,6'd22,6'd13});
        chk("small waveform is magnified without signed wrap",uut.zoom_wave(8'hfe,3'd4)===8'he0);
        chk("wave display gain saturates positive peaks",uut.zoom_wave(8'd100,3'd4)===8'd127);
        get_pixel(134,460);
        chk("long footer retains stage digits beyond character eight",uut.text_char===16'h0032);
        get_pixel(400,460);
        chk("button help retains its first character",uut.text_char===16'h0041);
        get_pixel(670,460);
        chk("button help retains its last character",uut.text_char===16'h0045);
        // Four renderer stages: stream coordinates and DE, rather than holding a pixel.
        ui_mode=5;y=90;
        repeat(8)@(negedge pixel_clk);
        for(scan=0;scan<80;scan=scan+1)begin
            x=scan;de=(scan%9!=0);
            exp_de={exp_de[2:0],de};
            for(jj=3;jj>0;jj=jj-1)exp_color[jj]=exp_color[jj-1];
            exp_color[0]=!de ? 18'd0 : scan>=24 ? C_SCOPE_BG : {6'd7,6'd8,6'd9};
            @(posedge pixel_clk);#1;
            if(scan>=4 && (display_de!==exp_de[3] || rgb666!==exp_color[3]))begin
                errors=errors+1;$display("[FAIL] raster at scan %0d",scan);
            end
            @(negedge pixel_clk);
        end
        if (errors == 0) $display("===== 全部用例通过 =====");
        else             $display("===== 失败 %0d 例 =====", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("===== tb_visual_pages 超时 =====");
        $finish;
    end
endmodule
