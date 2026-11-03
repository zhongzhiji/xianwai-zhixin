// ============================================================================
//  tb_lissajous_scope.v —— audio_lissajous_scope 前端自检
// ----------------------------------------------------------------------------
//  覆盖：复位值、16bit→光栅坐标的映射（含正负满刻度）、抽稀率、toggle、
//        伴奏静音判定、enable 关断、以及最关键的一条——
//        **两路真实正交信号能画出四象限都覆盖的图形，而不是一条直线**
//        （单通道延迟伪造圆的做法在这里会被 T8 直接打死：
//         伪造时 X 与 Y 强相关，四象限判据过不了）。
// ============================================================================
`timescale 1ns / 1ps

module tb_lissajous_scope;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg sample_en = 1'b0;
    reg enable = 1'b0;
    reg signed [15:0] pcm_x = 16'sd0;
    reg signed [15:0] pcm_y = 16'sd0;

    wire [6:0] liss_x, liss_y;
    wire liss_quiet, liss_toggle;

    audio_lissajous_scope #(.DECIMATE(4)) uut(
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en), .enable(enable),
        .pcm_x(pcm_x), .pcm_y(pcm_y),
        .liss_x(liss_x), .liss_y(liss_y),
        .liss_quiet(liss_quiet), .liss_toggle(liss_toggle));

    always #10 clk = ~clk;   // 50 MHz

    integer pass = 0;
    integer fail = 0;
    integer k, n;
    integer toggle_cnt;
    integer pulse_cnt;
    integer min_x, max_x, min_y, max_y;
    integer q1, q2, q3, q4;
    reg prev_toggle;
    real ang;

    task chk;
        input [319:0] name;   // 40 字符，够放下完整用例名再留余量
        input cond;
        begin
            if (cond) begin
                pass = pass + 1;
                $display("  PASS  %0s", name);
            end else begin
                fail = fail + 1;
                $display("  FAIL  %0s", name);
            end
        end
    endtask

    // 发出 n 个 48 kHz 采样节拍（每个节拍占 10 个 sys_clk）
    task beat;
        input integer cnt;
        begin
            for (n = 0; n < cnt; n = n + 1) begin
                sample_en = 1'b1;
                @(posedge clk); #1;
                sample_en = 1'b0;
                repeat (9) @(posedge clk);
            end
            // 收尾多等 1ns：让最后一次打点的 NBA 先落地，
            // 否则调用方读到的 prev_toggle 是跳变前的值，会多数出一个点。
            @(posedge clk); #1;
        end
    endtask

    initial begin
        $display("=== tb_lissajous_scope: dual-channel Lissajous frontend ===");
        // ---- T1 复位值：在 reset_n 仍为 0 时读，避免释放沿的同拍竞争 ----
        repeat (4) @(posedge clk);
        chk("T1 reset: x=0",          liss_x === 7'd0);
        chk("T1 reset: y=0",          liss_y === 7'd0);
        chk("T1 reset: toggle=0",     liss_toggle === 1'b0);
        chk("T1 reset: quiet=0",      liss_quiet === 1'b0);
        reset_n = 1'b1;
        @(posedge clk);

        // ---- T2 正半轴映射：pcm_x=+16384 → ux=0xC0 → x=72 ----
        enable = 1'b1;
        pcm_x  = 16'sd16384;
        pcm_y  = 16'sd0;
        beat(4);
        chk("T2 x=72 at pcm_x=+16384", liss_x === 7'd72);
        chk("T2 y=48 (centre) at pcm_y=0", liss_y === 7'd48);

        // ---- T3 负半轴映射：pcm_x=-16384 → ux=0x40 → x=24 ----
        pcm_x = -16'sd16384;
        beat(4);
        chk("T3 x=24 at pcm_x=-16384", liss_x === 7'd24);

        // ---- T4 Y 轴满刻度 ----
        pcm_x = 16'sd0;
        pcm_y = 16'sd32767;
        beat(4);
        chk("T4 y=95 at pcm_y=+32767", liss_y === 7'd95);
        pcm_y = -16'sd32768;
        beat(4);
        chk("T4 y=0 at pcm_y=-32768",  liss_y === 7'd0);

        pcm_x=16'sd32767; beat(4);
        chk("X positive full-scale fits 96 columns", liss_x===95);
        pcm_x=-16'sd32768; beat(4);
        chk("X negative full-scale reaches column 0", liss_x===0);

        // ---- T5 抽稀率：40 个节拍只出 10 个点 ----
        pcm_x = 16'sd8000;
        pcm_y = 16'sd4000;
        prev_toggle = liss_toggle;
        toggle_cnt  = 0;
        pulse_cnt   = 0;
        for (n = 0; n < 40 * 10; n = n + 1) begin
            sample_en = (n % 10 == 0);
            if (n % 10 == 0) pulse_cnt = pulse_cnt + 1;
            @(posedge clk); #1;
            if (liss_toggle !== prev_toggle) begin
                toggle_cnt = toggle_cnt + 1;
                prev_toggle = liss_toggle;
            end
        end
        sample_en = 1'b0;
        $display("   [dbg] T5: pulses=%0d points=%0d", pulse_cnt, toggle_cnt);
        chk("T5 decim: 40 beats -> 10 pts", toggle_cnt == 10);

        // ---- T6 伴奏静音判定 ----
        pcm_y = 16'sd0;
        beat(260 * 4);
        chk("T6 quiet=1 after 260 silent points", liss_quiet === 1'b1);
        pcm_y = 16'sd9000;
        beat(8);
        chk("T6 quiet drops as soon as acc sounds", liss_quiet === 1'b0);

        // ---- T7 enable=0：停止打点 ----
        pcm_y = 16'sd9000;
        prev_toggle = liss_toggle;
        toggle_cnt  = 0;
        enable = 1'b0;
        beat(40);
        chk("T7 muted: no new point",  liss_toggle === prev_toggle);
        chk("T7 muted: quiet reported", liss_quiet === 1'b1);

        // ---- T8 两路正交信号 → 四象限全覆盖（不是一条直线）----
        enable = 1'b1;
        // 初值必须落在 0..127 / 0..95 之内：坐标是无符号数，
        // 与负整数比较会被当成无符号比较而永远失败。
        min_x = 95; max_x = 0; min_y = 95; max_y = 0;
        q1 = 0; q2 = 0; q3 = 0; q4 = 0;
        prev_toggle = liss_toggle;
        for (n = 0; n < 64 * 4 * 10; n = n + 1) begin
            // 每 40 个 sys_clk 换一次相位（= 每 4 个采样节拍 = 一个打点）
            if (n % 40 == 0) begin
                ang = 3.14159265358979 * 2.0 * (n / 40) / 64.0;
                pcm_x = $rtoi(30000.0 * $cos(ang));
                pcm_y = $rtoi(30000.0 * $sin(ang));
            end
            sample_en = (n % 10 == 0);
            @(posedge clk); #1;
            if (liss_toggle !== prev_toggle) begin
                prev_toggle = liss_toggle;
                if (liss_x < min_x) min_x = liss_x;
                if (liss_x > max_x) max_x = liss_x;
                if (liss_y < min_y) min_y = liss_y;
                if (liss_y > max_y) max_y = liss_y;
                if (liss_x >= 48 && liss_y >= 48) q1 = q1 + 1;
                if (liss_x <  48 && liss_y >= 48) q2 = q2 + 1;
                if (liss_x <  48 && liss_y <  48) q3 = q3 + 1;
                if (liss_x >= 48 && liss_y <  48) q4 = q4 + 1;
            end
        end
        sample_en = 1'b0;
        $display("   [dbg] T8: x %0d..%0d  y %0d..%0d", min_x, max_x, min_y, max_y);
        chk("T8 x span > 60 (real X excursion)", (max_x - min_x) > 60);
        chk("T8 y span > 30 (real Y excursion)", (max_y - min_y) > 30);
        chk("T8 quadrant 1 occupied", q1 > 0);
        chk("T8 quadrant 2 occupied", q2 > 0);
        chk("T8 quadrant 3 occupied", q3 > 0);
        chk("T8 quadrant 4 occupied", q4 > 0);

        // A quiet single voice must remain legible without changing the audio.
        reset_n=0;repeat(4)@(negedge clk);reset_n=1;
        enable=1;pcm_x=16'sd800;pcm_y=0;beat(8);
        chk("small input uses display-only gain",liss_x>60 && liss_y==48);
        $display("----------------------------------------");
        $display("  PASS=%0d  FAIL=%0d", pass, fail);
        if (fail == 0) $display("  *** tb_lissajous_scope ALL PASS ***");
        else           $display("  *** tb_lissajous_scope HAS FAILURES ***");
        $finish;
    end

    initial begin
        #200000000;
        $display("  *** tb_lissajous_scope TIMEOUT ***");
        $finish;
    end
endmodule
