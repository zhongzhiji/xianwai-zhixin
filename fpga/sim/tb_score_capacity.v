`timescale 1ns/1ps
// ============================================================================
// tb_score_capacity.v —— 曲谱容量 64 → 255 扩容验证
//
// 背景：原实现把单曲事件数**硬编码成 64**（score_transport 里 notes/lengths
//       数组是 [0:63]、load_addr 只有 6 位），一首完整曲子必须切成 4 段，
//       现场演示体验很差。现在参数化成 MAX_EVENTS=255。
//
// 本 TB 要证明的不是"没弄坏旧的"，而是"新的真的能用"：
//   1. 装载 255 个事件能被接受（旧版 addr 会被截成 6 位 → 只写进前 64 个）
//   2. 第 100 / 200 个事件真的写进了数组（验证深度扩到 255，且没被截断）
//   3. 播放能推进过第 64 个事件（旧版 event_index 到 63 就绕回）
//   4. 少写一个事件时提交被拒绝（新的 O(1) 计数器校验要顶用）
//   5. count=64 的旧用法仍然正常（不破坏兼容性）
//
// 驱动时序注意：激励必须在 posedge **之后**再改（#1），否则和被测模块的
// 采样沿撞在同一时刻，iverilog 的事件调度顺序不确定 → 字节时有时无。
// commit_accept 是单拍脉冲，用 sticky 寄存器抓拍，不能靠"恰好检查到"。
//
// 运行：
//   iverilog -g2012 -o sim/out/cap.vvp -s tb_score_capacity -I rtl \
//       -y rtl sim/tb_score_capacity.v
//   vvp sim/out/cap.vvp
// ============================================================================
module tb_score_capacity;

    localparam integer MAX_EVENTS = 255;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [7:0] byte_data = 8'd0;
    reg       byte_valid = 1'b0;

    wire       load_we, load_commit, frame_done, commit_accept;
    wire [7:0] load_addr;
    wire [6:0] load_note;
    wire [3:0] load_length;
    wire [7:0] load_count, load_bpm;
    wire [2:0] err_code;
    wire [7:0] err_count;

    // transport 侧
    reg  frame_tick = 1'b0, toggle_play = 1'b0, restart = 1'b0;
    reg  next_timbre = 1'b0, next_song = 1'b0, pause_request = 1'b0;
    reg  step_mode = 1'b0, step_advance = 1'b0;
    wire [55:0] score_notes;
    wire [31:0] score_lengths;
    wire [2:0]  active_slot;
    wire [7:0]  page_index;
    wire [6:0]  progress;
    wire [23:0] guide;
    wire [6:0]  current_midi_note, target_midi_note;
    wire        target_ready, completed, playing;
    wire [1:0]  timbre;
    wire [7:0]  bpm;
    wire        imported_score;
    wire [2:0]  song_id;

    always #10 clk = ~clk;   // 50 MHz

    score_loader_core #(.MAX_EVENTS(MAX_EVENTS)) u_core (
        .clk(clk), .rst_n(rst_n),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .frame_done(frame_done), .commit_accept(commit_accept),
        .err_code(err_code), .err_count(err_count), .recv_count());

    score_transport #(
        .FRAME_HZ(55), .ENABLE_GUIDANCE(0),
        .MAX_EVENTS(MAX_EVENTS), .ADDR_W(8)
    ) u_tp (
        .clk(clk), .reset_n(rst_n), .frame_tick(frame_tick),
        .toggle_play(toggle_play), .restart(restart),
        .next_timbre(next_timbre), .next_song(next_song),
        .pause_request(pause_request), .step_mode(step_mode),
        .step_advance(step_advance),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .score_notes(score_notes), .score_lengths(score_lengths),
        .active_slot(active_slot), .page_index(page_index),
        .progress(progress), .guide(guide),
        .current_midi_note(current_midi_note),
        .target_midi_note(target_midi_note), .target_ready(target_ready),
        .completed(completed), .playing(playing), .timbre(timbre),
        .bpm(bpm), .imported_score(imported_score), .song_id(song_id));

    integer pass_cnt, fail_cnt;
    integer i;
    integer evt_before, bpm_before;

    // ---- 安全驱动：在 posedge 之后 1ns 才改激励，避开采样沿竞态 ----
    task automatic send_byte;
        input [7:0] b;
        begin
            @(posedge clk);
            #1;
            byte_data  = b;
            byte_valid = 1'b1;
            @(posedge clk);          // 这一拍被采样
            #1;
            byte_valid = 1'b0;
        end
    endtask

    // ---- commit_accept 是单拍脉冲，用 sticky 抓拍 ----
    // 注意：不能在 posedge 采样——commit_accept 本身就是在 posedge 上被置位的，
    // posedge 采样只能读到**上一拍**的值，永远抓不到。改在 negedge（脉冲中点）采。
    reg commit_seen;
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) commit_seen <= 1'b0;
        else if (commit_accept) commit_seen <= 1'b1;
    end

    task automatic clear_commit_seen;
        begin
            @(negedge clk);
            commit_seen <= 1'b0;
            @(negedge clk);
        end
    endtask

    // 装载 n 个事件（音符 = 60 + (i % 24)，长度全部 1 → 播放推进最快）
    task automatic load_song;
        input [7:0] n;
        input [7:0] bpm_v;
        begin
            send_byte(8'h55); send_byte(8'h4C); send_byte(n); send_byte(bpm_v);
            for (i = 0; i < n; i = i + 1) begin
                send_byte(8'h55); send_byte(8'h57);
                send_byte(i[7:0]); send_byte(60 + (i % 24)); send_byte(8'd1);
            end
            send_byte(8'h55); send_byte(8'h43);   // commit
            // 等 3 拍：core 置 load_commit(第1拍) -> transport 采样(第2拍)
            // -> imported_score/bpm/event_count 更新可见(第3拍)
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic chk;
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

    // 记录播放过程中到达过的最大 page_index（页 = 8 事件）
    reg [7:0] max_page;
    always @(posedge clk) begin
        if (!rst_n) begin
            max_page <= 8'd0;
        end else if (imported_score && playing && page_index > max_page) begin
            max_page <= page_index;
        end
    end

    // 单拍脉冲 restart（把 playing 拉起来）
    task automatic do_restart;
        begin
            @(posedge clk); #1;
            restart = 1'b1;
            @(posedge clk); #1;
            restart = 1'b0;
        end
    endtask

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        $display("=== tb_score_capacity: 曲谱容量 64->%0d ===", MAX_EVENTS);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---- 1. 装载 255 个事件 ----
        $display("-- 测试1: 装载 255 事件 --");
        clear_commit_seen;
        load_song(8'd255, 8'd240);
        $display("  DBG commit_seen=%b accept=%b err=%0d imported=%b bpm=%0d evt=%0d written=%0d",
                 commit_seen, commit_accept, err_count, imported_score, bpm,
                 u_tp.event_count, u_tp.draft_written);
        chk(commit_seen, "commit 被接受（255 事件）");
        chk(err_count == 8'd0, "协议层无错误");
        chk(imported_score, "transport 已切到导入曲谱");
        chk(bpm == 8'd240, "bpm 已装载");

        // ---- 2. 深地址真的写进去了（旧版 addr 会被截成 6 位）----
        // 直接探测当前活动 bank 的数组：index 100 应为 60+(100%24)=64，
        // index 200 应为 60+(200%24)=68。若地址被截断，这两个位置会是
        // reset 时的 demo_note，值对不上。
        $display("-- 测试2: 深地址写入检查（index 100 / 200）--");
        chk((u_tp.active_bank ? u_tp.notes_b[100] : u_tp.notes_a[100]) == 7'd64,
            "index 100 的音符 = 64（未被 6 位地址截断）");
        chk((u_tp.active_bank ? u_tp.notes_b[200] : u_tp.notes_a[200]) == 7'd68,
            "index 200 的音符 = 68（数组深度已扩到 255）");

        // ---- 3. 播放能越过第 64 个事件 ----
        $display("-- 测试3: 播放越界检查 --");
        do_restart;
        for (i = 0; i < 4000; i = i + 1) begin
            @(posedge clk); #1; frame_tick = 1'b1;
            @(posedge clk); #1; frame_tick = 1'b0;
        end
        $display("     播放中到达的最大 page_index = %0d（页 = 8 事件）", max_page);
        chk(max_page >= 8'd8, "播放越过第 64 个事件（page_index >= 8）");

        // ---- 4. 少写一个事件时提交必须被拒 ----
        // 注意：两道门。core 的 commit_accept 只看**协议**是否合法（count/bpm
        // 在范围内就置位），transport 的 commit_valid 才是第二道门（检查草稿
        // 是否写全）。所以这里不能查 commit_accept，必须查 transport 有没有
        // 真的换曲谱 —— event_count / bpm 保持不变才是"拒绝"。
        $display("-- 测试4: 漏写校验（transport 第二道门）--");
        evt_before = u_tp.event_count;
        bpm_before = bpm;
        clear_commit_seen;
        send_byte(8'h55); send_byte(8'h4C); send_byte(8'd200); send_byte(8'd120);
        for (i = 0; i < 199; i = i + 1) begin          // 只写 199 个，少 1 个
            send_byte(8'h55); send_byte(8'h57);
            send_byte(i[7:0]); send_byte(60 + (i % 24)); send_byte(8'd1);
        end
        send_byte(8'h55); send_byte(8'h43);
        repeat (3) @(posedge clk);
        $display("     DBG 协议层 accept=%b，transport event_count %0d->%0d，bpm %0d->%0d",
                 commit_seen, evt_before, u_tp.event_count, bpm_before, bpm);
        chk(commit_seen, "协议层仍接受（count/bpm 合法）—— 说明门在 transport");
        chk(u_tp.event_count == evt_before, "transport 拒绝换曲（event_count 未变）");
        chk(bpm == bpm_before, "transport 拒绝换曲（bpm 未变）");
        chk(u_tp.draft_written == 10'd199, "草稿计数器 = 199（少 1 个）");

        // ---- 5. 旧用法（count=64）仍正常 ----
        $display("-- 测试5: 兼容旧的 64 事件用法 --");
        clear_commit_seen;
        load_song(8'd64, 8'd120);
        chk(commit_seen, "count=64 仍能正常装载");

        $display("=== 结果：PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("*** ALL PASS ***");
        else $display("*** 有 %0d 项失败 ***", fail_cnt);
        $finish;
    end

    initial begin
        #8000000;
        $display("ERROR: 超时未结束");
        $finish;
    end

endmodule
