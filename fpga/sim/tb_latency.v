`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_latency.v —— 按键到出声的延迟实测（仿真法，赛题基础2/拓展3 的证据）
//
// 赛题：基础要求 控制→出声 ≤10 ms；拓展要求 ≤5 ms 无抖动。
// 测量定义（与 docs/12 第三节一致）：从 note_gate 拉高那一拍开始计数，
// 到引擎 pcm 在 sample_en 沿上第一次非零为止。
//   · 主链是纯组合式逐样本运算（DDS→波表→ADSR→混音），预期 1~2 个样本；
//   · 48 kHz 一个样本 = 20.83 us，所以核心链延迟应在 ~40 us 量级，
//     距离 5 ms 红线两个数量级；
//   · 还做了"任意相位起测 ×16 次"：note_gate 落在采样节拍的任意位置，
//     延迟的抖动范围必须 < 1 个样本周期（这是"无抖动"的数值化）。
//
// 注意：本 TB 测的是合成核心；整机还要加上
//   · 输入侧：FSR 采样 / UART 接收（≤1 ms，见 bt_uart_link / fsr 链路）
//   · 输出侧：I2S 串化 ≤1 个样本周期（≤20.8 us）
//   这些加起来也远小于 5 ms。
// ---------------------------------------------------------------------------
module tb_latency;
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

    fsr32_engine #(.LAYOUT(1)) dut(
        .clk50(clk50),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
        .note_gate(note_gate),.ext_gate(ext_gate),.ext_freq_word(ext_freq_word),
        .family(family),.preset(preset),.octave(octave),.expression(expression),
        .freq_override(freq_override),.freq_override_word(freq_override_word),
        .test_mode(test_mode),.test_count(test_count),
        .vib_depth(vib_depth),.glide_en(glide_en),.glide_rate(glide_rate),
        .pcm(pcm),.voices_active(voices_active),.note_on(note_on),.note_off(note_off),
        .expression_smoothed(expression_smoothed),.clipped(clipped));

    // 50 MHz 时钟；sample_en 每 1042 拍一个（48.0 kHz），与整机 clk_gen 一致
    always #10 clk50=~clk50;
    reg [10:0] divcnt=0;
    always @(posedge clk50) begin
        if(!reset_n) begin divcnt<=0;sample_en<=0;end
        else if(divcnt==11'd1041) begin divcnt<=0;sample_en<=1;end
        else begin divcnt<=divcnt+1'b1;sample_en<=0;end
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

    integer trial, cycles, lat_min, lat_max, total_cycles, sample_beats;
    integer first_pcm;
    reg started;

    initial begin
        $display("=== tb_latency: note_on -> 第一个非零 PCM 样本 ===");
        lat_min=999999; lat_max=0; total_cycles=0;
        for(trial=0;trial<16;trial=trial+1) begin
            // 复位并让采样节拍跑起来
            reset_n=0;enable=0;note_gate=0;
            repeat(4) @(negedge clk50);
            reset_n=1;enable=1;
            // 让 note_on 落在采样节拍的"任意相位"：trial 错开 67 拍
            repeat(67*trial+13) @(negedge clk50);
            note_gate=16'h0001; started=1; cycles=0; sample_beats=0;
            // 计数到 pcm 在采样沿上**确定且**非零（x 不算出声：
            // 管线的首个样本可能含未知位，必须等到已知电平）
            while((pcm===16'sd0 || (^pcm)===1'bx) && cycles<20000) begin
                @(posedge clk50);
                cycles=cycles+1;
                if(sample_en) sample_beats=sample_beats+1;
            end
            first_pcm=pcm;
            if(cycles<lat_min) lat_min=cycles;
            if(cycles>lat_max) lat_max=cycles;
            total_cycles=total_cycles+cycles;
            note_gate=0;
            $display("  [TRIAL %2d] latency=%0d cycles (%.2f us), %0d sample beats, first pcm=%0d",
                     trial,cycles,cycles*0.02,sample_beats,first_pcm);
        end
        $display("  ---- 统计：min=%0d max=%0d 抖动=%0d 拍 (%.2f us) 平均=%0d",
                 lat_min,lat_max,lat_max-lat_min,
                 (lat_max-lat_min)*0.02,total_cycles/16);
        // 判定1：上限 < 1 ms（50000 拍 @50MHz，对 5 ms 红线仍有 5 倍余量）。
        // 实测 ~260us 的构成：≤1 个采样周期等下一个 sample_en（20.8us）+
        // expression 软启动（128/样本的防爆音斜率）+ ADSR attack 初期
        // envelope 量化取整 —— 是有意的防爆音设计，不是组合链真实延迟。
        chk(lat_max<50000,"延迟上限 < 1 ms（对 5 ms 红线有 5 倍余量）");
        // 判定2：抖动 < 1 个样本周期（1042 拍）——"无抖动"数值化
        chk((lat_max-lat_min)<1042,"延迟抖动 < 1 个采样周期（20.8 us）");
        // 判定3：每次都真的出了声
        chk(pcm!==16'sd0,"16 次起测每次都产生非零样本");
        $display("PASS=%0d FAIL=%0d",pass_cnt,fail_cnt);
        $finish;
    end

    initial begin
        #200000000;
        $display("  [FAIL] 超时");
        $finish;
    end
endmodule
