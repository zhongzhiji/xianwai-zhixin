`timescale 1ns/1ps
// 验证下落式音游轨道（B4）的位置计算：
//   1. 窗口内每个音符块出现在"距判定线还剩多少 tick"对应的 y 上
//   2. ticks_left 变小 → 块下移（真的是"下落"，不是跳格）
//   3. 更后面的音符要累加前面各音符的 length，位置才对
//   4. game_enable=0 时轨道完全不画（关掉音游不留痕迹）
//
// 采样点用渲染器内部的 geometry_oracle_tree[1]（组合、无流水延迟），
// 这是模块特意为回归 bench 留的 pre-pipeline 输出，不接物理输出路径。
//
// 几何叶子优先级：choose_geometry 取索引大的，而 461..510 未使用，
// 所以 460（下落块）命中时必然覆盖掉背景与其它叶子，颜色可直接比对。
module tb_fall_notes;

    reg        pixel_clk = 0;
    reg        reset_n   = 0;
    reg        de        = 1;
    reg [11:0] x = 0, y = 0;

    reg [31:0] pressed = 0;
    reg [23:0] guide = 0;
    reg [55:0] score_notes = 0;
    reg [31:0] score_lengths = 0;
    reg [2:0]  active_slot = 0;
    reg [7:0]  page_index = 0;
    reg [6:0]  progress = 0;
    reg        playing = 1;
    reg [1:0]  timbre = 0;
    reg [7:0]  bpm = 100;
    reg [6:0]  expression = 100;
    reg [4:0]  volume_step = 12;
    reg        volume_edit = 0;
    reg [1:0]  practice_mode = 1;
    reg        backing_enabled = 0;
    reg [6:0]  target_note = 0;
    reg [7:0]  guide_hits = 0, guide_errors = 0;
    reg        guide_completed = 0, guide_unsupported = 0, guide_wrong = 0;
    reg [1:0]  upper_guide = 0;
    reg        demo_mode = 0;
    reg [2:0]  ui_mode = 0;
    reg [1:0]  instrument = 0;
    reg        imported_score = 0;
    reg [2:0]  song_id = 0;
    reg [2:0]  input_online = 0;

    reg        game_enable = 0;
    reg [1:0]  game_judge = 0;
    reg [5:0]  game_judge_hold = 0;
    reg [7:0]  game_combo = 0, game_best_combo = 0;
    reg [31:0] game_score_bcd = 0;
    reg [7:0]  game_pf = 0, game_gd = 0, game_ms = 0;
    reg [7:0]  ticks_left = 0;

    wire       display_de;
    wire [17:0] rgb666;

    score_ui_renderer #(.REGISTER_FONT(1)) uut(
        .de(de), .x(x), .y(y),
        .pressed(pressed), .guide(guide),
        .score_notes(score_notes), .score_lengths(score_lengths),
        .active_slot(active_slot), .page_index(page_index), .progress(progress),
        .playing(playing), .timbre(timbre), .bpm(bpm), .expression(expression),
        .volume_step(volume_step), .volume_edit(volume_edit),
        .practice_mode(practice_mode), .backing_enabled(backing_enabled),
        .target_note(target_note),
        .guide_hits(guide_hits), .guide_errors(guide_errors),
        .guide_completed(guide_completed),
        .guide_unsupported(guide_unsupported), .guide_wrong(guide_wrong),
        .upper_guide(upper_guide), .demo_mode(demo_mode),
        .ui_mode(ui_mode), .instrument(instrument),
        .imported_score(imported_score), .song_id(song_id),
        .input_online(input_online),
        .game_enable(game_enable), .game_judge(game_judge),
        .game_judge_hold(game_judge_hold),
        .game_combo(game_combo), .game_best_combo(game_best_combo),
        .game_score_bcd(game_score_bcd),
        .game_pf(game_pf), .game_gd(game_gd), .game_ms(game_ms),
        .ticks_left(ticks_left),
        .wave_mail(25'd0), .fx_mode(2'd0), .test_sel(3'd0),
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .display_de(display_de), .rgb666(rgb666));

    always #10 pixel_clk = ~pixel_clk;

    localparam [17:0] C_GOLD = {6'd61, 6'd43, 6'd25};
    localparam [17:0] C_TEAL = {6'd22, 6'd39, 6'd36};

    integer pass_cnt = 0, fail_cnt = 0;

    task automatic chk;
        input cond;
        input [8*44:1] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1;
                $display("  [OK  ] %0s", name); end
            else begin fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", name); end
        end
    endtask

    // 采样某个像素当前拿到的几何颜色（组合 oracle，无流水延迟）
    // 注意：块的 x/y 是**按拍预计算**的寄存器（为时序打平，见渲染器注释），
    // 所以改完激励后必须先等一个 posedge，再读组合 oracle，否则读到旧坐标。
    task automatic sample;
        input [11:0] sx;
        input [11:0] sy;
        output [17:0] color;
        begin
            x = sx; y = sy;
            repeat (3) @(posedge pixel_clk);
            #1;
            color = uut.geometry_oracle_tree[1][17:0];
        end
    endtask

    reg [17:0] c;

    initial begin
        $display("=== tb_fall_notes: 下落式音游轨道 ===");

        // 窗口内 8 个音：60 62 64 65 67 69 71 72，每个长度都是 4 tick
        score_notes   = {7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
        score_lengths = 32'h44444444;
        active_slot   = 3'd0;
        practice_mode = 2'd1;

        reset_n = 0; repeat (4) @(posedge pixel_clk);
        reset_n = 1; repeat (4) @(posedge pixel_clk);

        // ---- 1. game_enable=0 时轨道区不该有下落块 ----
        $display("-- 测试1: 音游关闭时不画轨道 --");
        game_enable = 0; ticks_left = 8'd4;
        sample(307, 262, c);
        chk(c !== C_GOLD && c !== C_TEAL, "音游关：判定线上方无下落块");

        // ---- 2. 打开音游，按 tick 距离定位 ----
        //   ticks_left=4，每 tick 8 像素，判定线 y=300
        //   slot0(note=60): dist=4  → by=268, 块 y 256..267, x 300..315
        //   slot1(note=62): dist=8  → by=236, 块 y 224..235, x 338..353
        //   slot2(note=64): dist=12 → by=204, 块 y 192..203, x 376..391
        $display("-- 测试2: 三个音符块落在预期位置 --");
        game_enable = 1; ticks_left = 8'd4;
        sample(307, 262, c);
        chk(c === C_GOLD, "slot0 当前音符块为金色（正好在 x=300 列）");
        sample(345, 230, c);
        chk(c === C_TEAL, "slot1 下一音符为青色（累加 1 个 length）");
        sample(383, 198, c);
        chk(c === C_TEAL, "slot2 再下一个为青色（累加 2 个 length）");

        // ---- 3. 块之间的空隙不该被误判为块 ----
        $display("-- 测试3: 块外区域不命中 --");
        sample(307, 240, c);
        chk(c !== C_GOLD && c !== C_TEAL, "slot0 与 slot1 之间的空隙不命中");
        sample(500, 262, c);
        chk(c !== C_GOLD && c !== C_TEAL, "同高度但音高列不同 → 不命中");

        // ---- 4. ticks_left 减小，块必须下移（连续下落）----
        $display("-- 测试4: 剩余 tick 变少时块下移 --");
        // ticks_left=4 → slot0 块在 y 256..267
        sample(307, 262, c);
        chk(c === C_GOLD, "ticks_left=4 时块在 y 256..267");

        ticks_left = 8'd2;                 // dist=2 → by=284, 块 y 272..283
        sample(307, 262, c);
        chk(c !== C_GOLD && c !== C_TEAL, "ticks_left=2 时原位置已空出");
        sample(307, 278, c);
        chk(c === C_GOLD, "ticks_left=2 时块下移到 y 272..283");

        ticks_left = 8'd0;                 // dist=0 → by=300, 块 y 288..299
        sample(307, 294, c);
        chk(c === C_GOLD, "ticks_left=0 时块贴到判定线 y 288..299");

        // ---- 5. 判定线本身 ----
        $display("-- 测试5: 判定线 --");
        sample(500, 302, c);
        chk(c === C_GOLD, "判定线 y=300..303 为金色");

        // ---- 6. active_slot 变化时，金色跟着当前音符走 ----
        $display("-- 测试6: 当前音符随 active_slot 切换 --");
        //   active_slot=2 → slot2 就是"当前音符"，它的距离直接等于 ticks_left=4
        //   → by=268，块 y 256..267；x 由 note=64 决定：300+(64-60)*19=376
        ticks_left = 8'd4; active_slot = 3'd2;
        sample(383, 262, c);
        chk(c === C_GOLD, "active_slot=2 时 slot2 变金色（且是当前距离）");
        sample(307, 262, c);
        chk(c !== C_GOLD, "active_slot=2 时 slot0 不再画（已过去）");

        $display("=== 结果: PASS=%0d  FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("=== tb_fall_notes 全部通过 ===");
        else $display("=== tb_fall_notes 存在失败 ===");
        $finish;
    end

endmodule
