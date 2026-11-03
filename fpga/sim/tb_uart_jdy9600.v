`timescale 1ns/1ps
// Independent absolute-time 9600 8N1 waveform into the actual score loader.
// Pixel clock is 35 MHz, rounded divider 3646 (about -0.0046% error).
module tb_uart_jdy9600;

    localparam integer CLK_PER_BIT = 3646;              // 35 MHz / 9600
    localparam real    CLK_PERIOD  = 1000000000.0 / 35000000.0;  // 28.5714 ns
    localparam real    BIT_TIME    = 1000000000.0 / 9600.0;    // 104166.667 ns

    reg clk = 1'b0, rst_n = 1'b0, rx = 1'b1;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    wire        load_we, load_commit, frame_done, commit_accept;
    wire [7:0]  load_addr;
    wire [6:0]  load_note;
    wire [7:0]  load_count;
    wire [3:0]  load_length;
    wire [7:0]  load_bpm;
    wire [2:0]  err_code;
    wire [7:0]  err_count, recv_count;

    score_loader_uart #(.CLK_PER_BIT(CLK_PER_BIT)) uut(
        .clk(clk), .rst_n(rst_n), .rx(rx),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .frame_done(frame_done), .commit_accept(commit_accept),
        .err_code(err_code), .err_count(err_count), .recv_count(recv_count));

    integer errors = 0, we_count = 0, cm_count = 0;
    reg accept_seen = 1'b0;   // commit_accept 是单拍脉冲，必须锁存后再判断

    // ---- 以真实波特率位宽发送一位（绝对延时，与 clk 完全异步）----
    task bit_tx;
        input v;
        begin
            rx = v;
            #(BIT_TIME);
        end
    endtask

    task byte_tx;
        input [7:0] b;
        integer k;
        begin
            bit_tx(1'b0);                       // 起始位
            for (k = 0; k < 8; k = k + 1) bit_tx(b[k]);
            bit_tx(1'b1);                       // 停止位
        end
    endtask

    always @(posedge clk) begin
        if (load_we)     we_count <= we_count + 1;
        if (load_commit) cm_count <= cm_count + 1;
        if (commit_accept) accept_seen <= 1'b1;
    end

    initial begin
        $display("================================================================");
        $display("波特率兼容性验证：DUT 时钟 35 MHz, CLK_PER_BIT=%0d", CLK_PER_BIT);
        $display("  DUT 实际波特率 = %.1f Hz", 35000000.0 / CLK_PER_BIT);
        $display("  名义波特率     = 9600.0 Hz");
        $display("  相对误差       = %.3f %%",
                 (35000000.0 / CLK_PER_BIT - 9600.0) / 9600.0 * 100.0);
        $display("================================================================");

        rst_n = 1'b0; #1000; rst_n = 1'b1; #1000;

        // 1) 装载头：4 个音符，BPM 120
        byte_tx(8'h55); byte_tx(8'h4C); byte_tx(8'd4); byte_tx(8'd120);
        #(BIT_TIME * 3);
        if (!(load_count == 7'd4 && load_bpm == 8'd120)) begin
            $display("FAIL: 装载头解析错 count=%0d bpm=%0d（期望 4/120）", load_count, load_bpm);
            errors = errors + 1;
        end else
            $display("PASS: 装载头 count=4 bpm=120");

        // 2) 连续 8 个事件（最大化采样误差累积）
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd0); byte_tx(8'd60); byte_tx(8'd3);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd1); byte_tx(8'd62); byte_tx(8'd6);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd2); byte_tx(8'd0);  byte_tx(8'd2);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd3); byte_tx(8'd67); byte_tx(8'd1);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd4); byte_tx(8'd83); byte_tx(8'd4);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd5); byte_tx(8'd71); byte_tx(8'd2);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd6); byte_tx(8'd64); byte_tx(8'd3);
        byte_tx(8'h55); byte_tx(8'h57); byte_tx(8'd7); byte_tx(8'd76); byte_tx(8'd2);
        #(BIT_TIME * 3);
        if (we_count != 8) begin
            $display("FAIL: load_we 应为 8 次，实测 %0d", we_count);
            errors = errors + 1;
        end else
            $display("PASS: 连续 8 帧写事件全部正确识别");

        // 3) 提交
        byte_tx(8'h55); byte_tx(8'h43);
        #(BIT_TIME * 3);
        if (!(cm_count == 1 && accept_seen)) begin
            $display("FAIL: 提交失败 cm=%0d accept_seen=%0b", cm_count, accept_seen);
            errors = errors + 1;
        end else
            $display("PASS: 提交被接受");

        // 4) 最后一帧的值是否准确（验证没有采样错位）
        if (!(load_addr == 6'd7 && load_note == 7'd76 && load_length == 4'd2)) begin
            $display("FAIL: 末帧值 addr=%0d note=%0d len=%0d（期望 7/76/2）",
                     load_addr, load_note, load_length);
            errors = errors + 1;
        end else
            $display("PASS: 末帧数据 addr=7 note=76 len=2");

        // 5) 不应有任何协议错误
        if (err_count != 0) begin
            $display("FAIL: 出现 %0d 次协议错误（最后一个 err_code=%0d）", err_count, err_code);
            errors = errors + 1;
        end else
            $display("PASS: 零协议错误，无采样错位");

        $display("================================================================");
        $display("=== %s : errors=%0d ===",
                 (errors == 0) ? "BAUD CHECK PASS" : "BAUD CHECK FAIL", errors);
        $display("================================================================");
        if (errors != 0) $fatal(1,"9600 UART errors");
        $finish;
    end
endmodule
