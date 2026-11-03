`timescale 1ns/1ps
// 验证伴奏开关对最终输出的影响：
//   1. 伴奏关 → acc_pcm 恒 0（关掉就是真的没声音，不会残留）
//   2. 伴奏开 → acc_pcm 有输出
//   3. 混音饱和相加：正常值相加正确，溢出钳到 ±32767/-32768 而不绕回
//
// 背景：伴奏原本只挂在 fsr16 链路，ENGINE_PRO=1 时输出走 32 复音，
//       伴奏等于"开关切得动但听不见"。现在把伴奏挪到最终输出端混音，
//       这个 TB 就是给那 3 行混音逻辑和 enable 门控兜底。
module tb_accomp_mix;

    reg clk = 0, reset_n = 0;
    reg sample_en = 0;
    reg enable = 0, note_gate = 0;
    reg [31:0] freq_word = 32'd0;

    wire signed [15:0] pcm;
    wire [1:0] voices_active;
    wire clipped;

    // 440 Hz @48k 的相位步进数量级：440 * 2^32 / 48000
    localparam [31:0] FW_A4 = 32'd39_410_397;

    score_accompaniment uut(
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .enable(enable), .note_gate(note_gate), .freq_word(freq_word),
        .pcm(pcm), .voices_active(voices_active), .clipped(clipped));

    always #10 clk = ~clk;              // 50 MHz

    // 仿真里把采样周期压到 4 个 clk，省时间；只验证有无输出，不验证音高
    integer scnt;
    always @(posedge clk) begin
        if (!reset_n) begin scnt <= 0; sample_en <= 0; end
        else begin
            scnt <= scnt + 1;
            sample_en <= (scnt[1:0] == 2'd3);
        end
    end

    integer pass_cnt = 0, fail_cnt = 0;
    integer i, nonzero;

    task automatic chk;
        input cond;
        input [8*40:1] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1;
                $display("  [OK  ] %0s", name); end
            else begin fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", name); end
        end
    endtask

    // 300 个采样周期 = 1200 个 clk，足够包络起来
    task automatic run_samples;
        input integer n;
        begin
            repeat (n * 4) @(posedge clk);
        end
    endtask

    // ---- 被测的混音逻辑（与 top_music_pro.v 第 10 节逐字一致）----
    function signed [15:0] sat_mix;
        input signed [15:0] a;
        input signed [15:0] b;
        reg signed [16:0] s;
        begin
            s = {a[15], a} + {b[15], b};
            if      (s >  32767) sat_mix =  16'sd32767;
            else if (s < -32768) sat_mix = -16'sd32768;
            else                 sat_mix = s[15:0];
        end
    endfunction

    initial begin
        $display("=== tb_accomp_mix: 伴奏开关与混音饱和 ===");

        reset_n = 0; enable = 0; note_gate = 0; freq_word = 32'd0;
        repeat (5) @(posedge clk);
        reset_n = 1;
        repeat (5) @(posedge clk);

        // ---- 1. 伴奏关：无论 gate/freq 怎么给，输出必须恒 0 ----
        $display("-- 测试1: 伴奏关闭时输出恒 0 --");
        enable = 0; note_gate = 1; freq_word = FW_A4;
        run_samples(300);
        chk(pcm === 16'sd0, "伴奏关：pcm 恒为 0");
        chk(voices_active === 2'b00, "伴奏关：无声部激活");

        // ---- 2. 伴奏开：有音符时应出声 ----
        $display("-- 测试2: 伴奏打开时输出非 0 --");
        enable = 1; note_gate = 1; freq_word = FW_A4;
        run_samples(300);
        nonzero = 0;
        for (i = 0; i < 40; i = i + 1) begin
            run_samples(1);
            if (pcm !== 16'sd0) nonzero = nonzero + 1;
        end
        chk(nonzero > 0, "伴奏开：pcm 出现非 0 采样");

        // ---- 3. 音符为休止（freq_word=0）时不应爆出非 0 ----
        $display("-- 测试3: 休止符（freq_word=0）不触发新音符 --");
        freq_word = 32'd0;
        run_samples(10);
        chk(note_gate == 1'b1, "前置条件：gate 仍为 1（靠 freq==0 静音）");

        // ---- 4. 关掉伴奏后必须干净归零 ----
        $display("-- 测试4: 重新关闭后立刻归零 --");
        freq_word = FW_A4;
        run_samples(50);
        enable = 0;
        run_samples(4);
        chk(pcm === 16'sd0, "伴奏重新关闭：pcm 归零");

        // ---- 5. 混音饱和 ----
        $display("-- 测试5: 混音饱和相加 --");
        chk(sat_mix(16'sd100, 16'sd200) === 16'sd300, "正常相加 100+200=300");
        chk(sat_mix(-16'sd100, -16'sd200) === -16'sd300, "负向相加 -100-200=-300");
        chk(sat_mix(16'sd30000, 16'sd30000) === 16'sd32767, "正向溢出钳到 +32767");
        chk(sat_mix(-16'sd30000, -16'sd30000) === -16'sd32768, "负向溢出钳到 -32768");
        chk(sat_mix(16'sd32767, 16'sd0) === 16'sd32767, "伴奏为 0 时原样通过");
        chk(sat_mix(-16'sd32768, 16'sd0) === -16'sd32768, "伴奏为 0 时负满量程通过");
        chk(sat_mix(16'sd32767, -16'sd32768) === -16'sd1, "极端一正一负不绕回");

        $display("=== 结果: PASS=%0d  FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("=== tb_accomp_mix 全部通过 ===");
        else $display("=== tb_accomp_mix 存在失败 ===");
        $finish;
    end

endmodule
