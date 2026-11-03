`timescale 1ns/1ps
// 频谱不是“柱子会动”就算通过：这里检查峰的位置、双音分辨、32 音覆盖和静音归零。
module tb_spectrum_goertzel;
    reg clk = 0;
    always #10 clk = ~clk;                 // 50 MHz

    reg reset_n = 0;
    reg sample_en = 0;
    reg enable = 1;
    reg signed [15:0] pcm_in = 0;
    wire [4:0] spec_bin;
    wire [7:0] spec_level;
    wire spec_toggle;
    wire frame_done;

    audio_spectrum_goertzel dut (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .enable(enable), .pcm_in(pcm_in),
        .spec_bin(spec_bin), .spec_level(spec_level),
        .spec_toggle(spec_toggle), .frame_done(frame_done));

    integer pass = 0;
    integer fail = 0;
    reg [7:0] levels [0:31];
    reg last_toggle = 0;
    integer frames_seen = 0;
    integer levels_seen = 0;
    real phase1, phase2, freq1, freq2, amp1, amp2;
    real sample_value;
    integer sample_count;
    integer i;
    integer max_level;
    integer max_bin;
    integer second_level;
    integer second_bin;
    integer covered;

    task check;
        input condition;
        input [8*88-1:0] message;
        begin
            if (condition) begin
                pass = pass + 1;
                $display("  [PASS] %0s", message);
            end else begin
                fail = fail + 1;
                $display("  [FAIL] %0s", message);
            end
        end
    endtask

    always @(negedge clk) begin
        if (!reset_n) begin
            last_toggle <= 1'b0;
        end else begin
            if (spec_toggle != last_toggle) begin
                last_toggle <= spec_toggle;
                levels[spec_bin] <= spec_level;
                levels_seen <= levels_seen + 1;
                $display("  [OUT ] bin=%0d level=%0d", spec_bin, spec_level);
            end
            if (frame_done) frames_seen <= frames_seen + 1;
        end
    end

    task do_reset;
        begin
            reset_n = 0;
            sample_en = 0;
            pcm_in = 0;
            enable = 1;
            repeat (5) @(negedge clk);
            reset_n = 1;
            repeat (3) @(negedge clk);
            frames_seen = 0;
            levels_seen = 0;
            phase1 = 0;
            phase2 = 0;
            sample_count = 0;
            for (i = 0; i < 32; i = i + 1) levels[i] = 0;
        end
    endtask

    task drive_one_sample;
        begin
            sample_value = amp1 * $sin(phase1) + amp2 * $sin(phase2);
            pcm_in = $rtoi(sample_value);
            phase1 = phase1 + 6.283185307179586 * freq1 / 48000.0;
            phase2 = phase2 + 6.283185307179586 * freq2 / 48000.0;
            sample_en = 1;
            @(negedge clk);
            sample_en = 0;
            // 72 sys_clk/样本，大于 64 个频点更新周期（两拍流水），贴近真实调度且仿真较快。
            repeat (71) @(negedge clk);
            sample_count = sample_count + 1;
        end
    endtask

    task run_one_frame;
        begin
            while (frames_seen == 0 && sample_count < 33000)
                drive_one_sample;
            check(frames_seen == 1, "4096 个抽取样本后产生且只产生一帧");
            while (levels_seen < 32 && sample_count < 33100)
                @(negedge clk);
            check(levels_seen == 32, "一帧完整串行输出 32 个频点");
        end
    endtask

    task find_maxima;
        begin
            max_level = 0;
            max_bin = -1;
            second_level = 0;
            second_bin = -1;
            for (i = 0; i < 32; i = i + 1) begin
                if (levels[i] > max_level) begin
                    second_level = max_level;
                    second_bin = max_bin;
                    max_level = levels[i];
                    max_bin = i;
                end else if (levels[i] > second_level) begin
                    second_level = levels[i];
                    second_bin = i;
                end
            end
        end
    endtask

    initial begin
        $display("== 单音 C4：峰必须落在 bin12 ==");
        do_reset;
        freq1 = 261.625565; freq2 = 0;
        amp1 = 12000; amp2 = 0;
        run_one_frame;
        find_maxima;
        $display("  [INFO] max bin=%0d level=%0d", max_bin, max_level);
        check(max_bin == 12, "C4 最大谱峰位于 MIDI60 / bin12");
        check(max_level >= 24, "单音具有足够显示动态范围");

        $display("== 双音 C4 + A4：两个峰都要可辨 ==");
        do_reset;
        freq1 = 261.625565; freq2 = 440.0;
        amp1 = 6000; amp2 = 6000;
        run_one_frame;
        find_maxima;
        $display("  [INFO] top1=%0d/%0d top2=%0d/%0d C4=%0d A4=%0d",
                 max_bin,max_level,second_bin,second_level,levels[12],levels[21]);
        check((max_bin == 12 && second_bin == 21) ||
              (max_bin == 21 && second_bin == 12),
              "前两个谱峰恰好是 C4 与 A4");
        check(levels[12] >= max_level - 4 && levels[21] >= max_level - 4,
              "两个等幅音的显示幅度相近");

        $display("== 32 音：每个目标频点都必须起来 ==");
        do_reset;
        // 在 testbench 内逐样本生成 32 个正弦，避免 32 个实数相位数组的兼容性问题。
        frames_seen = 0; levels_seen = 0; sample_count = 0;
        for (i = 0; i < 32; i = i + 1) levels[i] = 0;
        while (frames_seen == 0 && sample_count < 33000) begin : drive_32
            integer k;
            real p;
            sample_value = 0;
            for (k = 0; k < 32; k = k + 1) begin
                p = 6.283185307179586 *
                    (130.812783 * (2.0 ** (k / 12.0))) * sample_count / 48000.0;
                sample_value = sample_value + 700.0 * $sin(p);
            end
            pcm_in = $rtoi(sample_value);
            sample_en = 1;
            @(negedge clk);
            sample_en = 0;
            repeat (71) @(negedge clk);
            sample_count = sample_count + 1;
        end
        while (levels_seen < 32 && sample_count < 33100) @(negedge clk);
        find_maxima;
        covered = 0;
        // 32 个正弦的相位干涉与 log2 量化会带来约 11 档差异；
        // 判定目标是“每个频点都起来”，不是要求 32 个幅度逐一相等。
        for (i = 0; i < 32; i = i + 1)
            if (levels[i] >= max_level - 12) covered = covered + 1;
        $display("  [INFO] max=%0d covered=%0d/32", max_level, covered);
        check(covered == 32, "32 个等幅半音全部落在统一动态范围内");

        $display("== 静音：整帧幅度必须归零 ==");
        do_reset;
        freq1 = 0; freq2 = 0; amp1 = 0; amp2 = 0;
        run_one_frame;
        find_maxima;
        check(max_level == 0, "静音时 32 个频点全部为 0");

        $display("TB spectrum: PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("*** tb_spectrum_goertzel ALL PASS ***");
        else $display("*** tb_spectrum_goertzel FAIL ***");
        $finish;
    end

    initial begin
        #2000000000;
        $display("ERROR: 超时");
        $finish;
    end
endmodule
