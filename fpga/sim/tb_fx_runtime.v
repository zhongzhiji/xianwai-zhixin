`timescale 1ns/1ps
// 运行时效果器验证：旁路直通、回声在指定延迟后真的返回、合唱/混响链有输出。
// 延迟线参数在仿真中缩短，算法和时序路径与上板版本完全相同。
module tb_fx_runtime;
    reg clk=0,reset_n=0,sample_en=0,enable=0;
    reg [1:0] fx_mode=0;
    reg signed [15:0] pcm_in=0;
    wire signed [15:0] pcm_out;
    wire fx_active;

    fx_rack #(
        .ECHO_DEPTH(16384),.ECHO_DELAY(4),
        .CHORUS_BASE(8),.CHORUS_SWING(2),.CHORUS_BUF(16),
        .COMB0(4),.COMB1(5),.COMB2(6),.COMB3(7),.AP0(2),.AP1(1)
    ) dut(
        .clk(clk),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
        .fx_mode(fx_mode),.pcm_in(pcm_in),.pcm_out(pcm_out),.fx_active(fx_active));

    always #10 clk=~clk;
    integer pass_cnt=0,fail_cnt=0,i;
    reg signed [15:0] direct_level;

    task chk;
        input cond;
        input [8*48:1] name;
        begin
            if(cond) begin pass_cnt=pass_cnt+1;$display("  [OK  ] %0s",name);end
            else begin fail_cnt=fail_cnt+1;$display("  [FAIL] %0s",name);end
        end
    endtask

    task do_reset;
        input [1:0] mode;
        begin
            reset_n=0;enable=0;sample_en=0;pcm_in=0;fx_mode=mode;
            repeat(4) @(negedge clk);
            reset_n=1;enable=1;
            repeat(2) @(negedge clk);
        end
    endtask

    // 每个样本间隔 32 拍，足够覆盖混响 en[22] 的全部流水。
    task run_sample;
        input signed [15:0] value;
        begin
            @(negedge clk);pcm_in=value;sample_en=1;
            @(negedge clk);sample_en=0;
            repeat(31) @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_fx_runtime: 现场效果器四档 ===");
        // 旁路：不依赖 sample_en，每拍直通寄存；fx_active 必须为 0。
        do_reset(0);
        pcm_in=16'sd1234;
        @(posedge clk);#1;
        chk(pcm_out===16'sd1234,"旁路：PCM 直通且数值不变");
        chk(fx_active===1'b0,"旁路：fx_active=0");

        // 回声：先用 16 个零样本完成预填充，再发一个脉冲。
        do_reset(1);
        for(i=0;i<16384;i=i+1) run_sample(0);
        run_sample(16'sd10000);
        direct_level=pcm_out;
        chk(direct_level===16'sd10000,"回声：输入脉冲先以干信号输出");
        run_sample(0);run_sample(0);run_sample(0);
        chk(pcm_out===16'sd0,"回声：延迟时间未到时不提前回显");
        run_sample(0);
        $display("  [DBG ] echo direct=%0d delayed=%0d",direct_level,pcm_out);
        chk(pcm_out>16'sd2990 && pcm_out<16'sd3010,
            "回声：第 4 个样本后出现 0.30 湿度回显");
        chk(fx_active===1'b1,"回声：fx_active=1");

        // 合唱：预填充后输入非零样本，干湿混合输出必须非零。
        do_reset(2);
        for(i=0;i<16;i=i+1) run_sample(0);
        run_sample(16'sd8000);
        chk(pcm_out!==16'sd0,"合唱：实际输出非零 PCM");
        chk(fx_active===1'b1,"合唱：fx_active=1");

        // 混响：即使湿声仍在预填充，干声也必须按 en[22] 正常输出。
        do_reset(3);
        run_sample(16'sd6000);
        chk(pcm_out!==16'sd0,"混响：实际输出非零 PCM");
        chk(fx_active===1'b1,"混响：fx_active=1");

        enable=0;@(posedge clk);#1;
        chk(pcm_out===16'sd0,"总使能关闭后输出归零");
        $display("PASS=%0d FAIL=%0d",pass_cnt,fail_cnt);
        $finish;
    end
endmodule
