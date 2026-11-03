`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_midi_rx.v —— MIDI 1.0（31250 bps）接收解析自检测
//   激励：按 UART 8N1 逐位灌入 midi_rx（空闲高，起始位低，LSB 先发）
//   覆盖：Note On / Running Status / Note Off / vel==0 当 Note Off /
//         CC64 延音 / CC1 调制轮 / 弯音轮 / System Real-time / SysEx
// ---------------------------------------------------------------------------
module tb_midi_rx;

    localparam integer T = 10;                 // 50 MHz → 半周期 10 ns
    localparam integer BITT = 50000000 / 31250; // 1600 个 clk / bit

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg midi_rx = 1'b1;

    always #T clk <= ~clk;

    wire        note_on, note_off;
    wire [6:0]  note_on_num, note_on_vel, note_off_num;
    wire        sustain;
    wire [6:0]  mod_wheel, channel_volume;
    wire signed [13:0] pitch_bend;
    wire [7:0]  msg_count, err_count;
    wire        activity;

    midi_uart_rx #(.CLK_HZ(50000000), .BAUD(31250)) uut (
        .clk(clk), .rst_n(rst_n), .midi_rx(midi_rx),
        .note_on(note_on), .note_on_num(note_on_num), .note_on_vel(note_on_vel),
        .note_off(note_off), .note_off_num(note_off_num),
        .sustain(sustain), .mod_wheel(mod_wheel),
        .channel_volume(channel_volume), .pitch_bend(pitch_bend),
        .msg_count(msg_count), .err_count(err_count), .activity(activity));

    // ---------------- 事件采集 ----------------
    integer on_cnt, off_cnt;
    integer on_num   [0:15];
    integer on_vel   [0:15];
    integer off_num  [0:15];
    integer i;

    initial begin
        on_cnt = 0; off_cnt = 0;
        for (i = 0; i < 16; i = i + 1) begin
            on_num[i] = -1; on_vel[i] = -1; off_num[i] = -1;
        end
    end

    always @(posedge clk) begin
        if (note_on && on_cnt < 16) begin
            on_num[on_cnt] = note_on_num;
            on_vel[on_cnt] = note_on_vel;
            on_cnt         = on_cnt + 1;
        end
        if (note_off && off_cnt < 16) begin
            off_num[off_cnt] = note_off_num;
            off_cnt          = off_cnt + 1;
        end
    end

    // ---------------- 发送一个 UART 字节 ----------------
    task send_byte;
        input [7:0] d;
        integer k;
        begin
            midi_rx = 1'b0;                       // 起始位
            repeat (BITT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin   // 数据位 LSB 先
                midi_rx = d[k];
                repeat (BITT) @(posedge clk);
            end
            midi_rx = 1'b1;                       // 停止位
            repeat (BITT) @(posedge clk);
        end
    endtask

    task idle;
        input integer n;
        begin
            midi_rx = 1'b1;
            repeat (n) @(posedge clk);
        end
    endtask

    // ---------------- 判分 ----------------
    integer pass_n, fail_n;
    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) begin pass_n = pass_n + 1; $display("[PASS] %0s", name); end
            else       begin fail_n = fail_n + 1; $display("[FAIL] %0s", name); end
        end
    endtask

    initial begin
        pass_n = 0; fail_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        idle(200);

        // 1) Note On C4(60) vel 64      90 3C 40
        send_byte(8'h90); send_byte(8'h3C); send_byte(8'h40);
        // 2) Running Status：只发数据    3E 50  → Note On D4(62) vel 80
        send_byte(8'h3E); send_byte(8'h50);
        // 3) Note Off C4                 80 3C 00
        send_byte(8'h80); send_byte(8'h3C); send_byte(8'h00);
        // 4) Note On vel==0 视作 Note Off F4(65)
        send_byte(8'h90); send_byte(8'h41); send_byte(8'h00);
        // 5) CC64 踏板踩下 / 抬起        B0 40 7F / B0 40 00
        send_byte(8'hB0); send_byte(8'h40); send_byte(8'h7F);
        send_byte(8'hB0); send_byte(8'h40); send_byte(8'h00);
        // 6) CC1 调制轮                  B0 01 7F
        send_byte(8'hB0); send_byte(8'h01); send_byte(8'h7F);
        // 7) 弯音轮居中 E0 00 40 / 最大 E0 7F 7F
        send_byte(8'hE0); send_byte(8'h00); send_byte(8'h40);
        send_byte(8'hE0); send_byte(8'h7F); send_byte(8'h7F);
        // 8) System Real-time 时钟，必须被忽略且不破坏 running status
        send_byte(8'hF8); send_byte(8'hFE);
        // 9) SysEx 整段丢弃  F0 7E 7F 09 01 F7
        send_byte(8'hF0); send_byte(8'h7E); send_byte(8'h7F);
        send_byte(8'h09); send_byte(8'h01); send_byte(8'hF7);
        // 10) SysEx 之后 running status 已失效，重新发状态字节
        send_byte(8'h90); send_byte(8'h43); send_byte(8'h64);  // G4(67) vel 100

        idle(2000);

        // ---------------- 校验 ----------------
        chk("Note On 共 3 次",              on_cnt == 3);
        chk("Note On#0 音符号 60 (C4)",     on_num[0] == 60);
        chk("Note On#0 力度 64",            on_vel[0] == 64);
        chk("Running Status #1 音符号 62",  on_num[1] == 62);
        chk("Running Status #1 力度 80",    on_vel[1] == 80);
        chk("Note On#2 音符号 67 (G4)",     on_num[2] == 67);
        chk("Note On#2 力度 100",           on_vel[2] == 100);

        chk("Note Off 共 2 次",             off_cnt == 2);
        chk("Note Off#0 音符号 60",         off_num[0] == 60);
        chk("vel==0 判定为 Note Off 65",    off_num[1] == 65);

        chk("踏板最终抬起 sustain=0",        sustain === 1'b0);
        chk("调制轮 CC1 = 127",              mod_wheel == 127);
        chk("弯音轮最终 = +8191",            pitch_bend == 8191);
        chk("报文计数 = 10",                 msg_count == 10);
        chk("无帧错误 err_count=0",          err_count == 8'd0);

        $display("");
        $display("=============================================");
        $display("  MIDI 接收仿真：%0d PASS / %0d FAIL", pass_n, fail_n);
        $display("=============================================");
        if (fail_n == 0) $display("  >>> 全部通过");
        else             $display("  >>> 存在失败项");
        $finish;
    end

    initial begin
        #30_000_000;
        $display("[TIMEOUT] 仿真超时");
        $finish;
    end

endmodule
