`timescale 1ns/1ps
// 赛题评分项：N 音测试必须真的让 N 个独立声部进入活跃状态。
// 不只检查 test_count 数值，而是检查 32 个 timbre_voice 的 voices_active 位图。
module tb_test_voices;
    reg clk50=0,reset_n=0,sample_en=0,enable=0;
    reg [15:0] note_gate=0,ext_gate=0;
    reg [31:0] ext_freq_word=0,freq_override_word=0;
    reg [1:0] family=0,preset=0,octave=1;
    reg [6:0] expression=112;
    reg freq_override=0,test_mode=0;
    reg [5:0] test_count=0;
    reg [3:0] vib_depth=0;
    reg glide_en=0;
    reg [2:0] glide_rate=0;
    wire signed [15:0] pcm;
    wire [31:0] voices_active;
    wire [15:0] note_on,note_off,expression_smoothed;
    wire clipped;

    fsr32_engine dut(
        .clk50(clk50),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
        .note_gate(note_gate),.ext_gate(ext_gate),.ext_freq_word(ext_freq_word),
        .family(family),.preset(preset),.octave(octave),.expression(expression),
        .freq_override(freq_override),.freq_override_word(freq_override_word),
        .test_mode(test_mode),.test_count(test_count),
        .vib_depth(vib_depth),.glide_en(glide_en),.glide_rate(glide_rate),
        .pcm(pcm),.voices_active(voices_active),.note_on(note_on),.note_off(note_off),
        .expression_smoothed(expression_smoothed),.clipped(clipped));

    always #10 clk50=~clk50;
    reg [1:0] divcnt=0;
    always @(posedge clk50) begin
        if(!reset_n) begin divcnt<=0;sample_en<=0;end
        else begin divcnt<=divcnt+1'b1;sample_en<=(divcnt==2'd3);end
    end

    integer pass_cnt=0,fail_cnt=0;
    task chk;
        input cond;
        input [8*48:1] name;
        begin
            if(cond) begin pass_cnt=pass_cnt+1;$display("  [OK  ] %0s",name);end
            else begin fail_cnt=fail_cnt+1;$display("  [FAIL] %0s",name);end
        end
    endtask

    task run_count;
        input [5:0] n;
        input [31:0] expected;
        begin
            reset_n=0;enable=0;test_mode=0;test_count=0;
            repeat(4) @(negedge clk50);
            reset_n=1;enable=1;test_mode=1;test_count=n;
            // 80 个时钟 = 20 个采样，足够包络离开 0、颤音扫描跑完一轮。
            repeat(80) @(negedge clk50);
            chk(voices_active===expected,"N 音测试活跃位图与 N 完全一致");
        end
    endtask

    initial begin
        $display("=== tb_test_voices: 4/8/16/32 独立声部活跃验证 ===");
        run_count(4,32'h0000000f);
        run_count(8,32'h000000ff);
        run_count(16,32'h0000ffff);
        run_count(32,32'hffffffff);
        repeat(400) @(negedge clk50);
        chk(pcm!==16'sd0,"32 音测试实际产生非零 PCM 样本");
        $display("PASS=%0d FAIL=%0d",pass_cnt,fail_cnt);
        $finish;
    end
endmodule
