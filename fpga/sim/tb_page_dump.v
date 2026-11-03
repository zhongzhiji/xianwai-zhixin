`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_page_dump.v —— 真实 RTL 逐像素渲染导出七个 UI 页面（800x480 PPM）
//
// 不是手绘示意图：例化真实 score_ui_renderer（含真实字体 ROM），按真实
// 光栅时序逐时钟驱动 (x,y)，捕获流水线末端 rgb666，整帧写入 PPM。
// WAVE / SPEC / LISS 三页先按 mailbox 协议灌入真实负载（模拟 12kHz 数据流），
// 再扫屏。数据为明确的合成测试激励，非实物测量；验证的是当前 RTL 像素输出。
// 用法：vvp tb_page_dump.vvp +page=0..6   （七页并行各起一进程）
// ---------------------------------------------------------------------------
module tb_page_dump;

    localparam W = 800;
    localparam H = 480;
    localparam D = 4;                    // 渲染器面板延迟（注释载明 total=5）

    reg        pixel_clk = 1'b0;
    reg        reset_n   = 1'b0;
    reg        de        = 1'b1;
    reg [11:0] x = 12'd0, y = 12'd0;

    reg [31:0] pressed = 0;
    reg [23:0] guide = 0;
    reg [55:0] score_notes = 0;
    reg [31:0] score_lengths = 0;
    reg [2:0]  active_slot = 0;
    reg [7:0]  page_index = 0;
    reg [6:0]  progress = 0;
    reg        playing = 1;
    reg [1:0]  timbre = 0;
    reg [7:0]  bpm = 158;
    reg [6:0]  expression = 90;
    reg [4:0]  volume_step = 12;
    reg        volume_edit = 0;
    reg [1:0]  practice_mode = 0;
    reg        backing_enabled = 0;
    reg [6:0]  target_note = 0;
    reg [7:0]  guide_hits = 0, guide_errors = 0;
    reg        guide_completed = 0, guide_unsupported = 0, guide_wrong = 0;
    reg [1:0]  upper_guide = 0;
    reg        demo_mode = 1;
    reg [2:0]  ui_mode = 0;
    reg [1:0]  instrument = 0;
    reg        imported_score = 0;
    reg [2:0]  song_id = 1;              // 《我的未来式》
    reg [2:0]  input_online = 3'b000;    // 触摸/蓝牙/压力全在线
    reg        game_enable = 0;
    reg [1:0]  game_judge = 0;
    reg [5:0]  game_judge_hold = 0;
    reg [7:0]  game_combo = 0, game_best_combo = 0;
    reg [31:0] game_score_bcd = 0;
    reg [7:0]  game_pf = 0, game_gd = 0, game_ms = 0;
    reg [7:0]  ticks_left = 0;
    reg [24:0] wave_mail = 0;
    reg [13:0] spec_mail = 0;
    reg [15:0] liss_mail = 0;
    reg [1:0]  fx_mode = 0;
    reg [2:0]  test_sel = 0;
    reg [4:0] stage=31;
    reg live_liss=0;
    integer liss_div=0, live_phase=560;
    real live_t;
    reg [6:0] live_x,live_y;

    wire        display_de;
    wire [17:0] rgb666;

    score_ui_renderer #(.REGISTER_FONT(1)) uut(
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
        .guide_wrong(guide_wrong), .upper_guide(upper_guide), .demo_mode(demo_mode),
        .ui_mode(ui_mode), .instrument(instrument),
        .imported_score(imported_score), .song_id(song_id), .input_online(input_online),
        .game_enable(game_enable), .game_judge(game_judge),
        .game_judge_hold(game_judge_hold),
        .game_combo(game_combo), .game_best_combo(game_best_combo),
        .game_score_bcd(game_score_bcd),
        .game_pf(game_pf), .game_gd(game_gd), .game_ms(game_ms),
        .ticks_left(ticks_left),
        .wave_mail(wave_mail), .spec_mail(spec_mail), .liss_mail(liss_mail),
        .showcase_active(1'b1),.showcase_hold(1'b1),.showcase_stage(stage),
        .fx_mode(fx_mode), .test_sel(test_sel),
        .display_de(display_de), .rgb666(rgb666));

    always #10 pixel_clk = ~pixel_clk;

    // ---- 帧缓冲与捕获流水 ----
    reg [17:0] fb [0:W*H-1];
    reg [11:0] x_pipe [0:D-1];
    reg [11:0] y_pipe [0:D-1];
    reg        capt_en = 0;
    integer pi;

    reg [D-1:0] valid_pipe=0;
    integer pixels_written=0;
    always @(posedge pixel_clk) begin
        valid_pipe <= {valid_pipe[D-2:0],capt_en};
        x_pipe[0]<=x;y_pipe[0]<=y;
        for(pi=1;pi<D;pi=pi+1) begin x_pipe[pi]<=x_pipe[pi-1];y_pipe[pi]<=y_pipe[pi-1];end
        if(valid_pipe[D-1]) begin
            if(display_de!==1'b1 || (^rgb666)===1'bx) $fatal(1,"invalid pixel at %0d,%0d",x_pipe[D-1],y_pipe[D-1]);
            fb[y_pipe[D-1]*W+x_pipe[D-1]]<=rgb666;
            pixels_written=pixels_written+1;
        end
    end
    // Continuous independent X/Y fixture through the same renderer mailbox.
    always @(negedge pixel_clk) if(live_liss) begin
        if(liss_div==2916) begin
            liss_div=0;live_t=6.28318530718*live_phase/187.0;live_phase=live_phase+1;
            live_x=48.0+43.0*$sin(3.0*live_t);
            live_y=48.0+43.0*$sin(2.0*live_t+0.785398);
            liss_mail={~liss_mail[15],1'b0,live_x,live_y};
        end else liss_div=liss_div+1;
    end

    integer fx, fy, idx, fh, pno;
    reg [8*64:1] outname;

    task dump_page;
        input [8*64:1] fname;
        begin
            capt_en = 0;
            repeat (D + 2) @(posedge pixel_clk); #1;
            capt_en = 1;
            for (fy = 0; fy < H; fy = fy + 1) begin
                for (fx = 0; fx < W; fx = fx + 1) begin
                    x = fx[11:0]; y = fy[11:0];
                    @(posedge pixel_clk); #1;
                    if(fx==799 && fy%80==0)begin $display("ROW %0d page %0d",fy,pno);$fflush();end
                end
            end
            capt_en = 0;
            repeat (D + 2) @(posedge pixel_clk); #1;
            if(pixels_written!=W*H)$fatal(1,"pixel count %0d",pixels_written);
            fh = $fopen(fname, "wb");
            if(!fh)$fatal(1,"cannot create output");
            $fwrite(fh, "P6\n%0d %0d\n255\n", W, H);
            for (idx = 0; idx < W*H; idx = idx + 1)
                $fwrite(fh, "%c%c%c",
                        {fb[idx][17:12], 2'b00},
                        {fb[idx][11:6],  2'b00},
                        {fb[idx][5:0],   2'b00});
            $fclose(fh);
            $display("[DUMP] %0s", fname);
        end
    endtask

    // ---- mailbox 灌载（幅度拉满，保证一眼可见） ----
    integer wi;
    real    ws;
    task fill_wave;
        reg [7:0] samp;
        begin
            for (wi = 0; wi < 180; wi = wi + 1) begin
                // 钢琴包络：起振快、慢衰减，叠加二次谐波，幅值接近满量程
                ws = 80.0*(0.45 + 0.55*$exp(-wi/150.0))*$sin(6.28318*wi/13.0)
                          + 26.0*(0.45 + 0.55*$exp(-wi/110.0))*$sin(6.28318*wi/5.7 + 1.1)
                          + 10.0*$sin(6.28318*wi/3.1);
                if (ws < -127.0) ws = -127.0;
                if (ws > 127.0) ws = 127.0;
                samp = $rtoi(ws);
                wave_mail = {~wave_mail[24], 8'd70, 8'd118, samp};
                @(posedge pixel_clk); #1;
            end
        end
    endtask

    integer sb_i;
    reg [7:0] spec_lev [0:31];
    reg [7:0] spec_pk  [0:31];
    task fill_spec;
        begin
            for (sb_i = 0; sb_i < 32; sb_i = sb_i + 1) begin
                spec_lev[sb_i] = 8'd8 + (sb_i%5); // 底噪可见
                spec_pk [sb_i] = spec_lev[sb_i] + 8'd4;
            end
            spec_lev[12] = 8'd50; spec_pk[12] = 8'd54;   // 基音
            spec_lev[16] = 8'd44; spec_pk[16] = 8'd49;   // 二次泛音
            spec_lev[19] = 8'd48; spec_pk[19] = 8'd52;   // 三次泛音
            spec_lev[24] = 8'd34; spec_pk[24] = 8'd40;
            for (sb_i = 0; sb_i < 32; sb_i = sb_i + 1) begin
                spec_mail = {~spec_mail[13], sb_i[4:0], spec_pk[sb_i]};
                @(posedge pixel_clk); #1;
                spec_mail = {~spec_mail[13], sb_i[4:0], spec_lev[sb_i]};
                @(posedge pixel_clk); #1;
            end
        end
    endtask

    integer li;
    real    lt;
    task fill_liss;
        reg [6:0] lx, ly;
        real    rx, ry;
        begin
            for (li = 0; li < 560; li = li + 1) begin
                lt = 6.28318*li/187.0;
                rx = 48.0 + 45.0*$sin(3.0*lt);
                ry = 48.0 + 45.0*$sin(2.0*lt + 0.7854);
                lx = rx; if (lx > 95) lx = 95;
                ly = ry; if (ly > 95) ly = 95;
                liss_mail = {~liss_mail[15], 1'b0, lx, ly};
                @(posedge pixel_clk); #1;
            end
        end
    endtask

    initial begin
        pno = 0;
        if (!$value$plusargs("page=%d", pno)) pno = 0;

        reset_n = 0; repeat (6) @(posedge pixel_clk);
        reset_n = 1; repeat (6) @(posedge pixel_clk); #1;

        score_notes={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
        score_lengths=32'h44444444; guide=24'h000091;pressed=32'h00000091;
        case(pno)
          0:stage=21;1:stage=3;2:stage=5;3:stage=22;4:stage=18;5:stage=19;6:stage=20;
        endcase
        case (pno)
        // ===== 0：练习 / 音游（定时跟谱：满窗下落块 + PERFECT + 连击） =====
        0: begin
            ui_mode = 0; practice_mode = 0; game_enable = 0; demo_mode=1;
            score_notes   = {7'd64,7'd62,7'd60,7'd62,7'd64,7'd67,7'd65,7'd64};
            score_lengths = 32'h24244484;
            active_slot = 3'd1; ticks_left = 8'd2;
            guide = 24'h0003FF;
            game_combo = 8'd17; game_best_combo = 8'd24;
            game_score_bcd = 32'h00092600;
            game_pf = 8'd21; game_gd = 8'd4; game_ms = 8'd1;
            game_judge = 2'd1; game_judge_hold = 6'd42;
            progress = 7'd38; guide_hits = 8'd25; guide_errors = 8'd2;
            dump_page("sim/pages_verified/page0_practice.ppm");
        end
        // ===== 1：演奏（和弦按下 + 力度条 + 进度） =====
        1: begin
            ui_mode = 1; practice_mode = 2'd0; game_enable = 0;
            pressed = 32'h00000C93;       // 多键点亮
            expression = 7'd104; progress = 7'd52;
            dump_page("sim/pages_verified/page1_perform.ppm");
        end
        // ===== 2：音色 =====
        2: begin
            ui_mode = 2; timbre = 2'd1; instrument = 2'd1; fx_mode = 2'd1;
            dump_page("sim/pages_verified/page2_timbre.ppm");
        end
        // ===== 3：歌曲列表（演示中） =====
        3: begin
            ui_mode = 3; demo_mode = 1; song_id = 3'd1;
            dump_page("sim/pages_verified/page3_song.ppm");
        end
        // ===== 4：WAVE 实时波形 =====
        4: begin
            fill_wave;
            ui_mode = 4;
            dump_page("sim/pages_verified/page4_wave.ppm");
        end
        // ===== 5：SPEC 实时频谱 =====
        5: begin
            fill_spec;
            ui_mode = 5;
            dump_page("sim/pages_verified/page5_spec.ppm");
        end
        // ===== 6：LISS 李萨如 =====
        6: begin
            fill_liss; live_liss=1; backing_enabled=1;
            ui_mode = 6;
            dump_page("sim/pages_verified/page6_liss.ppm");
        end
        endcase

        $display("=== tb_page_dump page %0d 完成 ===", pno);
        $finish;
    end

endmodule
