`timescale 1ns/1ps
// 三键现场验证控制：短按只发 fx_step，长按只发 test_step，
// 组合键期间不得泄漏成普通的播放/音色/翻页动作。
module tb_runtime_controls;
    reg clk=0, reset_n=0;
    reg [2:0] pressed=0, short_action=0, long_action=0;
    wire [2:0] normal_short, normal_long;
    wire volume_edit, backing_enabled, fx_step, test_step;
    wire [4:0] volume_step;
    wire [1:0] practice_mode;

    ui_volume_control #(.HOLD_CYCLES(8),.DEFAULT_VOLUME_STEP(12)) dut(
        .clk(clk),.reset_n(reset_n),.pressed(pressed),
        .short_action(short_action),.long_action(long_action),
        .normal_short(normal_short),.normal_long(normal_long),
        .volume_edit(volume_edit),.volume_step(volume_step),
        .practice_mode(practice_mode),.backing_enabled(backing_enabled),
        .fx_step(fx_step),.test_step(test_step));

    always #10 clk=~clk;
    integer pass_cnt=0, fail_cnt=0;
    integer fx_count=0, test_count=0, leak_count=0;

    always @(posedge clk) begin
        #1;
        if(fx_step) fx_count=fx_count+1;
        if(test_step) test_count=test_count+1;
        if(normal_short!=0 || normal_long!=0) leak_count=leak_count+1;
    end

    task chk;
        input cond;
        input [8*48:1] name;
        begin
            if(cond) begin pass_cnt=pass_cnt+1; $display("  [OK  ] %0s",name); end
            else begin fail_cnt=fail_cnt+1; $display("  [FAIL] %0s",name); end
        end
    endtask

    initial begin
        $display("=== tb_runtime_controls: 三键短按/长按与动作隔离 ===");
        repeat(3) @(negedge clk);
        reset_n=1;
        repeat(2) @(negedge clk);

        // 三键短按：松开时只产生一次 fx_step。
        fx_count=0;test_count=0;leak_count=0;
        pressed=3'b111;
        repeat(3) @(negedge clk);
        pressed=0;
        repeat(4) @(negedge clk);
        chk(fx_count==1,"三键短按：fx_step 恰好 1 次");
        chk(test_count==0,"三键短按：不得触发 test_step");
        chk(leak_count==0,"三键短按：普通按键动作全部被吞掉");

        // 三键长按：到阈值发 test_step，松手后不得再补 fx_step。
        fx_count=0;test_count=0;leak_count=0;
        pressed=3'b111;
        repeat(12) @(negedge clk);
        pressed=0;
        repeat(4) @(negedge clk);
        chk(test_count==1,"三键长按：test_step 恰好 1 次");
        chk(fx_count==0,"三键长按：松手不得补发 fx_step");
        chk(leak_count==0,"三键长按：普通按键动作全部被吞掉");

        // 原有组合键不能被新功能破坏。
        fx_count=0;test_count=0;
        pressed=3'b011;
        repeat(12) @(negedge clk);
        pressed=0;
        repeat(4) @(negedge clk);
        chk(volume_edit===1'b1,"S1+S2 长按仍进入音量编辑");
        chk(fx_count==0 && test_count==0,"S1+S2 不得误触现场验证档位");

        // 非组合状态下，普通短按必须原样透传。
        reset_n=0;pressed=0;short_action=0;long_action=0;
        repeat(2) @(negedge clk);
        reset_n=1;
        @(negedge clk);short_action=3'b001;
        #1;chk(normal_short==3'b001,"普通 S1 短按原样透传");
        short_action=0;

        $display("PASS=%0d FAIL=%0d",pass_cnt,fail_cnt);
        $finish;
    end
endmodule
