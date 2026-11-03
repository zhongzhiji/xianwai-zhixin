// ============================================================================
//  tb_guidance_pipe.v —— 指引通路打拍（关键路径修复）的专项回归
//
// 背景：2026-11-01 实测最差路径 slack 只有 0.005 ns，链路是
//   transport/event_index -> notes_a[event_index] 异步读(255 选 1 LUT 多路器)
//   -> target_midi_note -> matcher 的 32 位移位 + PLAYABLE_MASK 归约
//   -> advance/hits 进位链，合计约 28 ns 组合逻辑（pixel_clk 只有 28.57 ns）。
// 修复：transport 出口的 target_midi_note/target_ready 打一拍，
//       display core 里 event_token 同步打一拍保持对齐。
//
// 本 TB 要证明"打拍没有把功能打坏"：
//   A1. target_midi_note 恰好是 current_midi_note 的一拍延迟（不多不少）
//   A2. 自由播放时 8 个音符按顺序全部出现在指引口上（没有因为多一拍而漏音）
//   A3. 步进（练习）模式下逐音推进仍然正确 —— 这一支最怕打拍打出错位
//   B1. 换音瞬间旧键还按着，音游**不得**误判命中（token 与 note 必须同拍）
//   B2. 松手重按新音后仍能正常判定命中（没把正常判定也一起关掉）
//
// 运行：bash sim/run_all_sim.sh tb_guidance_pipe
// ============================================================================
`timescale 1ns/1ps
module tb_guidance_pipe;

    localparam integer MAX_EVENTS = 255;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer pass_cnt = 0, fail_cnt = 0;
    integer i;

    task chk;
        input cond;
        input [255:0] name;
        begin
            if (cond) begin
                $display("  [PASS] %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] %0s", name);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ========================================================================
    // A 部分：score_transport 指引出口
    // ========================================================================
    reg  [7:0] byte_data = 8'd0;
    reg        byte_valid = 1'b0;
    wire       load_we, load_commit, commit_accept;
    wire [7:0] load_addr;
    wire [6:0] load_note;
    wire [3:0] load_length;
    wire [7:0] load_count, load_bpm;

    reg  frame_tick = 1'b0, toggle_play = 1'b0, restart = 1'b0;
    reg  step_mode = 1'b0, step_advance = 1'b0;
    wire [55:0] score_notes;
    wire [31:0] score_lengths;
    wire [2:0]  active_slot;
    wire [7:0]  page_index;
    wire [23:0] guide;
    wire [6:0]  current_midi_note, target_midi_note;
    wire        target_ready, completed, playing;
    wire        imported_score;

    score_loader_core #(.MAX_EVENTS(MAX_EVENTS)) u_core (
        .clk(clk), .rst_n(rst_n),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .frame_done(), .commit_accept(commit_accept),
        .err_code(), .err_count(), .recv_count());

    score_transport #(
        .FRAME_HZ(55), .ENABLE_GUIDANCE(1),
        .MAX_EVENTS(MAX_EVENTS), .ADDR_W(8)
    ) u_tp (
        .clk(clk), .reset_n(rst_n), .frame_tick(frame_tick),
        .toggle_play(toggle_play), .restart(restart),
        .next_timbre(1'b0), .next_song(1'b0),
        .pause_request(1'b0), .step_mode(step_mode),
        .step_advance(step_advance),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .score_notes(score_notes), .score_lengths(score_lengths),
        .active_slot(active_slot), .page_index(page_index),
        .progress(), .guide(guide),
        .current_midi_note(current_midi_note),
        .target_midi_note(target_midi_note), .target_ready(target_ready),
        .completed(completed), .playing(playing), .timbre(),
        .bpm(), .imported_score(imported_score), .song_id());

    task send_byte;
        input [7:0] b;
        begin
            @(posedge clk); #1;
            byte_data  = b;
            byte_valid = 1'b1;
            @(posedge clk); #1;
            byte_valid = 1'b0;
        end
    endtask

    // 8 个互不相同的音，便于查出"漏音/错序"
    reg [6:0] expect_note [0:7];
    initial begin
        expect_note[0]=7'd60; expect_note[1]=7'd62; expect_note[2]=7'd64;
        expect_note[3]=7'd65; expect_note[4]=7'd67; expect_note[5]=7'd69;
        expect_note[6]=7'd71; expect_note[7]=7'd72;
    end

    task load_song8;
        begin
            send_byte(8'h55); send_byte(8'h4C); send_byte(8'd8); send_byte(8'd240);
            for (i = 0; i < 8; i = i + 1) begin
                send_byte(8'h55); send_byte(8'h57);
                send_byte(i[7:0]); send_byte(expect_note[i]); send_byte(8'd1);
            end
            send_byte(8'h55); send_byte(8'h43);
            repeat (3) @(posedge clk);
        end
    endtask

    task do_restart;
        begin
            @(posedge clk); #1; restart = 1'b1;
            @(posedge clk); #1; restart = 1'b0;
        end
    endtask

    task one_frame;
        begin
            @(posedge clk); #1; frame_tick = 1'b1;
            @(posedge clk); #1; frame_tick = 1'b0;
        end
    endtask

    // A1 不变量：playing 期间 target 必须等于上一拍的 current。
    // 在 negedge 采样，避开 posedge 上非阻塞赋值的更新竞态。
    reg [6:0] current_d;
    reg       playing_d;
    reg       inv_en = 1'b0;
    integer   inv_errors = 0;
    always @(negedge clk) begin
        if (!rst_n) begin
            current_d <= 7'd0; playing_d <= 1'b0;
        end else begin
            if (inv_en && playing_d && playing &&
                target_midi_note !== current_d) begin
                inv_errors = inv_errors + 1;
                if (inv_errors <= 3)
                    $display("     DBG 不变量违例：target=%0d current_d=%0d",
                             target_midi_note, current_d);
            end
            current_d <= current_midi_note;
            playing_d <= playing;
        end
    end

    // A2 记录指引口上出现过的音符序列（去重，只记变化）
    reg [6:0] seen_note [0:31];
    integer   seen_n = 0;
    reg [6:0] seen_last = 7'h7f;
    always @(negedge clk) begin
        if (rst_n && playing && target_ready &&
            target_midi_note != 0 && target_midi_note != seen_last) begin
            seen_note[seen_n] <= target_midi_note;
            seen_n    <= seen_n + 1;
            seen_last <= target_midi_note;
        end
    end

    // ========================================================================
    // B 部分：matcher + rhythm_judge 的 token/note 对齐（复刻 display 新接法）
    // ========================================================================
    reg  [6:0]  raw_note = 7'd0;
    reg  [10:0] raw_token = 11'd0;
    reg  [31:0] pressed = 32'd0;
    reg         j_frame = 1'b0;

    // display core 现在就是这样：note/ready 在 transport 打拍，token 在这里打拍
    reg [6:0]  note_q = 7'd0;
    reg [10:0] token_q = 11'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin note_q <= 7'd0; token_q <= 11'd0; end
        else begin note_q <= raw_note; token_q <= raw_token; end
    end

    wire        m_advance, m_wrong, m_unsupported;
    wire [31:0] m_mask;
    wire [15:0] m_hits, m_errors;
    score_note_matcher u_m (
        .clk(clk), .reset_n(rst_n), .enable(1'b1), .online(1'b1),
        .resync(1'b0), .clear_stats(1'b0), .target_ready(1'b1),
        .target_midi_note(note_q), .event_token(token_q),
        .pressed(pressed), .advance(m_advance), .wrong_note(m_wrong),
        .unsupported(m_unsupported), .target_mask(m_mask),
        .hits(m_hits), .errors(m_errors));

    wire [1:0]  j_code;
    wire        j_pulse;
    wire [15:0] j_perfect, j_good, j_miss;
    rhythm_judge u_j (
        .clk(clk), .reset_n(rst_n), .frame_tick(j_frame), .enable(1'b1),
        .clear_stats(1'b0), .target_ready(1'b1), .target_midi_note(note_q),
        .event_token(token_q), .pressed(pressed), .target_mask(m_mask),
        .wrong_note(m_wrong), .advance(m_advance),
        .judge_code(j_code), .judge_pulse(j_pulse),
        .combo(), .best_combo(), .score(),
        .cnt_perfect(j_perfect), .cnt_good(j_good), .cnt_miss(j_miss));

    // 换音后 3 拍内不得出判定（旧键还按着的那段危险窗口）
    reg     watch = 1'b0;
    integer watch_bad = 0;
    always @(negedge clk) begin
        if (watch && j_pulse) watch_bad = watch_bad + 1;
    end

    task set_key;
        input [6:0] midi;
        begin
            // 与 target_mask 同一条映射：60 -> bit0
            pressed = 32'd1 << (midi - 7'd60);
        end
    endtask

    initial begin
        $display("=== tb_guidance_pipe: 指引通路打拍回归 ===");
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---------------- A：transport ----------------
        $display("-- A1/A2 自由播放：延迟一拍 + 不漏音 --");
        load_song8;
        do_restart;
        seen_n = 0; seen_last = 7'h7f;
        inv_en = 1'b1;
        for (i = 0; i < 1500; i = i + 1) one_frame;
        inv_en = 1'b0;
        chk(inv_errors == 0, "A1 target_midi_note 恒等于 current 的一拍延迟");
        $display("     指引口共出现 %0d 个不同音符", seen_n);
        chk(seen_n >= 8, "A2 至少出现 8 个音符");
        for (i = 0; i < 8; i = i + 1) begin
            if (i < seen_n)
                chk(seen_note[i] == expect_note[i],
                    "A2 指引音符顺序正确");
        end

        $display("-- A3 步进（练习）模式逐音推进 --");
        // 注意顺序：step_mode 变化会让 transport 进入"暂停的新尝试"
        //（playing<=0，见 score_transport 的 step_active != previous_step_active
        // 分支），所以必须先切模式、再 restart 把 playing 拉起来。
        // 真实板子上就是"先切练习模式，再按 S1 开始"。
        @(posedge clk); #1; step_mode = 1'b1;
        repeat (4) @(posedge clk);
        do_restart;
        repeat (4) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            // 等两拍让指引口稳定，再核对当前目标音
            repeat (2) @(negedge clk);
            chk(target_midi_note == expect_note[i],
                "A3 步进模式当前目标音正确");
            @(posedge clk); #1; step_advance = 1'b1;
            @(posedge clk); #1; step_advance = 1'b0;
            repeat (2) @(posedge clk);
        end
        chk(u_tp.event_index >= 10'd7 || completed,
            "A3 步进模式推进到最后一个事件");

        // ---------------- B：换音窗口不得误判 ----------------
        $display("-- B1/B2 音游换音窗口对齐 --");
        @(negedge clk); raw_note = 7'd60; raw_token = 11'd1; pressed = 32'd0;
        repeat (4) @(negedge clk);          // 等 token/note 生效 + matcher 上膛
        set_key(7'd60);                     // 按下 60 -> 正常命中一次
        repeat (4) @(negedge clk);
        chk(j_perfect + j_good >= 16'd1, "B0 正常按键能判定命中（前置条件）");

        // 关键场景：60 的键**一直按着**，目标切到 62
        @(negedge clk); raw_note = 7'd62; raw_token = 11'd2;
        watch = 1'b1;
        repeat (3) @(negedge clk);
        watch = 1'b0;
        chk(watch_bad == 0, "B1 换音后 3 拍内没有误判命中");
        chk(j_perfect + j_good == 16'd1, "B1 命中计数没有凭空增加");

        // 松手 -> 按 62，必须还能正常命中
        @(negedge clk); pressed = 32'd0;
        repeat (3) @(negedge clk);
        set_key(7'd62);
        repeat (4) @(negedge clk);
        chk(m_hits >= 16'd2, "B2 松手重按后 matcher 仍能判中");
        chk(j_perfect + j_good >= 16'd2, "B2 松手重按后音游仍能判中");

        $display("========================================");
        $display("  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("  *** tb_guidance_pipe ALL PASS ***");
        else               $display("  *** tb_guidance_pipe HAS FAIL ***");
        $finish;
    end

    initial begin
        #40000000;
        $display("  [TIMEOUT]");
        $finish;
    end
endmodule
