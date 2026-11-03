`timescale 1ns/1ps
// 验证实时波形示波器的音频侧前端 rtl/audio_wave_scope.v：
//   1. 复位后全部输出归零
//   2. 抽稀：DECIMATE=16，第一个采样节拍就出样本，之后每 16 个出一个
//   3. toggle 位每来一个样本翻一次（mailbox 靠"载荷变化"判有无新数据，
//      波形是连续流，相邻样本经常相等，没有 toggle 就会被当成没变化丢掉）
//   4. 样本值 = 当时 pcm 的高 8 位（有符号），峰值与样本同一把尺子
//   5. 峰值保持：立即上升，之后每 512 个采样节拍才回落 1 格
//   6. pcm = -32768 的边界：取反会溢出 16 bit，必须先扩位再饱和，
//      否则算成 0，波形底部出现假的"回抽"，峰值也会漏掉
//   7. enable=0（整机静音）时样本/峰值/电平全部拉回 0
//   8. 电平是一阶低通：单调爬升且不超过满刻度，静音后回落
//
// 说明：scope_valid 只有 1 拍宽，do_sample 会走两个时钟，所以在
// always 块里累计 valid 个数，而不是在 task 返回后再去读它。
module tb_wave_scope;

    reg        clk = 0;
    reg        reset_n = 0;
    reg        sample_en = 0;
    reg        enable = 0;
    reg signed [15:0] pcm_in = 0;
    wire [7:0] scope_sample, scope_peak, scope_level;
    wire       scope_valid, scope_toggle;

    audio_wave_scope #(.DECIMATE(16)) uut(
        .clk(clk), .reset_n(reset_n),
        .sample_en(sample_en), .enable(enable), .pcm_in(pcm_in),
        .scope_sample(scope_sample), .scope_peak(scope_peak),
        .scope_level(scope_level), .scope_valid(scope_valid),
        .scope_toggle(scope_toggle));

    integer pass = 0;
    integer fail = 0;
    integer k;
    integer valid_seen = 0;
    reg     toggle_d = 0;
    integer toggle_cnt = 0;

    always #10 clk = ~clk;              // 50 MHz

    // 在 negedge 上统计：scope_valid 只有 1 拍宽，posedge 上读到的是跳变
    // 前的旧值，会漏计；负沿时正沿的 NBA 已经落地，读到的才是真实值。
    always @(negedge clk) begin
        if (!reset_n) begin
            valid_seen <= 0;
            toggle_cnt <= 0;
            toggle_d   <= 1'b0;
        end else begin
            if (scope_valid) valid_seen <= valid_seen + 1;
            toggle_d <= scope_toggle;
            if (scope_toggle !== toggle_d) toggle_cnt <= toggle_cnt + 1;
        end
    end

    // 从 negedge 驱动 sample_en：如果直接在 @(posedge clk) 之后同拍拉高，
    // 会撞上 uut 的 always @(posedge clk)，同一个节拍被采到两次
    // （实测 dec_cnt 每次 +2，抽稀比变成了 8）。从负沿驱动就没有这个竞态。
    task do_sample;
        input signed [15:0] v;
        begin
            @(negedge clk);
            pcm_in    = v;
            sample_en = 1'b1;
            @(posedge clk);
            #1;
            sample_en = 1'b0;
            // 多等一个负沿：统计块在 negedge 上记账，不等就少记最后一拍
            @(negedge clk);
            #1;
        end
    endtask

    task chk;
        input [255:0] name;
        input         cond;
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

    reg [7:0] p0;

    initial begin
        $display("=== tb_wave_scope: audio_wave_scope frontend ===");

        // ---- 1. reset ----
        reset_n = 0;
        repeat (4) @(posedge clk);
        #1;
        chk("T1 reset: sample=0", scope_sample == 8'd0);
        chk("T1 reset: peak=0",   scope_peak   == 8'd0);
        chk("T1 reset: level=0",  scope_level  == 8'd0);
        chk("T1 reset: toggle=0", scope_toggle == 1'b0);

        // ---- 2/3/4. decimate + toggle + sample value ----
        reset_n = 1;
        enable  = 1;
        @(posedge clk);
        do_sample(16'sd1000);
        #1;
        chk("T2 first beat emits a sample", valid_seen == 1);
        chk("T4 sample = pcm[15:8] (1000/256=3)", scope_sample == 8'd3);
        chk("T3 toggle flipped once", toggle_cnt == 1);

        // 再送 15 个：还不到下一个抽稀点
        for (k = 0; k < 15; k = k + 1) do_sample(16'sd1000);
        #1;
        chk("T2 only 1 sample in first 16 beats", valid_seen == 1);

        // 第 17 个：出第二个样本
        do_sample(16'sd1000);
        #1;
        chk("T2 17th beat emits 2nd sample", valid_seen == 2);
        chk("T3 toggle flipped twice", toggle_cnt == 2);

        // ---- 5. peak hold ----
        for (k = 0; k < 64; k = k + 1) do_sample(16'sd30000);
        #1;
        // 30000/256 = 117
        chk("T5 peak rises to 117", scope_peak == 8'd117);
        chk("T5 peak <= full scale 127", scope_peak <= 8'd127);

        // ---- 6. -32768 boundary ----
        enable = 0; repeat (4) @(posedge clk); enable = 1;
        // 连送 32 个，保证一定撞上抽稀点（单送一个不一定更新 sample）
        for (k = 0; k < 32; k = k + 1) do_sample(-16'sd32768);
        #1;
        chk("T6 -32768 saturates to peak 127", scope_peak == 8'd127);
        chk("T6 -32768 sample is -128", scope_sample == 8'h80);

        // ---- 8. level is a 1st-order low pass ----
        enable = 0; repeat (4) @(posedge clk); enable = 1;
        for (k = 0; k < 200; k = k + 1) do_sample(16'sd16000);
        #1;
        // 16000/256 = 62
        chk("T8 level climbs above 40", scope_level > 8'd40);
        chk("T8 level <= 127", scope_level <= 8'd127);

        enable = 0;
        for (k = 0; k < 400; k = k + 1) do_sample(16'sd0);
        #1;
        chk("T8 level decays when muted", scope_level < 8'd20);

        // ---- 7. enable=0 forces everything to zero ----
        do_sample(16'sd20000);
        #1;
        chk("T7 muted: sample=0", scope_sample == 8'd0);
        chk("T7 muted: peak=0",   scope_peak   == 8'd0);
        chk("T7 muted: level=0",  scope_level  == 8'd0);

        // ---- 5b. peak decays gradually, not in one frame ----
        enable = 1;
        for (k = 0; k < 64; k = k + 1) do_sample(16'sd30000);
        #1;
        p0 = scope_peak;
        for (k = 0; k < 600; k = k + 1) do_sample(16'd0);
        #1;
        chk("T5 peak starts decaying", scope_peak < p0);
        chk("T5 decay is gradual (>= p0-4)", scope_peak >= p0 - 8'd4);

        $display("----------------------------------------");
        $display("  PASS=%0d  FAIL=%0d", pass, fail);
        if (fail == 0) $display("  *** tb_wave_scope ALL PASS ***");
        else           $display("  *** tb_wave_scope FAILED ***");
        $finish;
    end
endmodule
