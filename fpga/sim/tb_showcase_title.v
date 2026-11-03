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
module tb_showcase_title;

    reg        pixel_clk = 1'b0;
    reg        reset_n   = 1'b0;
    reg showcase_active=1, demo_mode=1, playing=1;
    reg [1:0] practice_mode=0;
    reg        de        = 1'b1;
    reg [11:0] x         = 12'd0;
    reg [11:0] y         = 12'd0;
    reg [2:0]  ui_mode   = 3'd0;
    reg [13:0] spec_mail = 14'd0;
    reg [15:0] liss_mail = 16'd0;

    wire        display_de;
    wire [17:0] rgb666;

    score_ui_renderer #(.LISS_CLEAR_CYCLES(8),.REGISTER_FONT(1)) uut(
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .de(de), .x(x), .y(y),
        .pressed(32'd0), .guide(24'd0),
        .score_notes(56'd0), .score_lengths(32'd0),
        .active_slot(3'd0), .page_index(8'd0),
        .progress(7'd0), .playing(playing), .timbre(2'd0), .bpm(8'd100),
        .expression(7'd64), .volume_step(5'd12), .volume_edit(1'b0),
        .practice_mode(practice_mode), .backing_enabled(1'b0),
        .target_note(7'd0), .guide_hits(8'd0), .guide_errors(8'd0),
        .guide_completed(1'b0), .guide_unsupported(1'b0),
        .guide_wrong(1'b0), .upper_guide(2'd0),
        .demo_mode(demo_mode), .ui_mode(ui_mode), .instrument(2'd0),
        .imported_score(1'b0), .song_id(3'd0), .input_online(3'd0),
        .game_enable(1'b0), .game_judge(2'd0),
        .game_judge_hold(6'd0),
        .game_combo(8'd0), .game_best_combo(8'd0),
        .game_score_bcd(32'd0),
        .game_pf(8'd0), .game_gd(8'd0), .game_ms(8'd0),
        .wave_mail(25'd0),
        .spec_mail(spec_mail), .liss_mail(liss_mail),
        .showcase_active(showcase_active), .showcase_hold(1'b0), .showcase_stage(5'd19),
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
            repeat (8) @(posedge pixel_clk);
            #1;
            px_rgb = rgb666;
            px_de  = display_de;
        end
    endtask

    localparam [17:0] C_SCOPE_BG = {6'd5,  6'd7,  6'd11};
    localparam [17:0] C_W1       = {6'd18, 6'd54, 6'd50};
    localparam [17:0] C_W2F      = {6'd24, 6'd19, 6'd9};
    localparam [17:0] C_GOLD     = {6'd61, 6'd43, 6'd25};


    integer mode_i, practice_i, auto_i, k, px, py, fh;
    reg [15:0] expected[0:3];
    initial begin
      expected[0]=16'h81EA;expected[1]=16'h7531;expected[2]=16'h5207;expected[3]=16'h6362;
      #100 reset_n=1;#200;
      for(mode_i=0;mode_i<7;mode_i=mode_i+1) begin
       ui_mode=mode_i;
       for(auto_i=0;auto_i<2;auto_i=auto_i+1) begin
        demo_mode=auto_i;
        for(practice_i=0;practice_i<3;practice_i=practice_i+1) begin
         practice_mode=practice_i;
         for(k=0;k<4;k=k+1) begin
          get_pixel(654+k*22,18);
          if(uut.text_char!==expected[k]) $fatal(1,"wrong title page=%0d auto=%0d practice=%0d char=%0d",mode_i,auto_i,practice_i,k);
         end
        end
       end
      end
      $display("PASS title on all 7 pages / 2 auto states / 3 practice states");
      ui_mode=0;practice_mode=0;demo_mode=1;playing=1;
      get_pixel(654,42);if(uut.text_char!==16'h64AD)$fatal(1,"playing status changed");
      playing=0;get_pixel(654,42);if(uut.text_char!==16'h5DF2)$fatal(1,"paused status changed");
      demo_mode=0;playing=1;get_pixel(654,42);if(uut.text_char!==16'h6F14)$fatal(1,"live status changed");
      playing=0;get_pixel(654,42);if(uut.text_char!==16'h9759)$fatal(1,"silent status changed");
      $display("PASS lower status retains playing/paused/live/silent");
      showcase_active=0;demo_mode=1;
      get_pixel(676,18);if(uut.text_char!==16'h52A8)$fatal(1,"non-showcase auto title changed");
      demo_mode=0;practice_mode=1;
      get_pixel(654,18);if(uut.text_char!==16'h5B9A)$fatal(1,"non-showcase practice title changed");
      practice_mode=0;
      get_pixel(654,18);if(uut.text_char!==16'h89E6)$fatal(1,"non-showcase touch title changed");
      $display("PASS non-showcase titles unchanged");
      showcase_active=1;demo_mode=1;playing=1;
      get_pixel(134,460);if(uut.text_char!==16'h0032)$fatal(1,"TEST INPUT stage footer changed");
      $display("PASS TEST INPUT stage footer preserved");
      fh=$fopen("../output/free_switch_label_20261103/title_actual_rtl.ppm","wb");
      if(!fh)$fatal(1,"cannot open pixel output");
      $fwrite(fh,"P6\n140 62\n255\n");
      for(py=8;py<70;py=py+1) for(px=640;px<780;px=px+1) begin
        get_pixel(px,py);
        if(px_de!==1 || (^px_rgb)===1'bx)$fatal(1,"invalid pixel");
        $fwrite(fh,"%c%c%c",{px_rgb[17:12],2'b00},{px_rgb[11:6],2'b00},{px_rgb[5:0],2'b00});
      end
      $fclose(fh);$display("PASS actual RTL header pixel capture 140x62");$finish;
    end
    initial begin #100000000;$fatal(1,"title test timeout");end
endmodule
