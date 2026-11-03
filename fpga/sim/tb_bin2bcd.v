`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_bin2bcd.v —— 二进制 → BCD 转换回归
//   覆盖：0、个位数、999999、16777215（24 位全 1）、连续两次 start、
//         done 只拉高一拍、转换中途 start 能正确重来。
// ---------------------------------------------------------------------------
module tb_bin2bcd;

    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg [23:0] bin_in = 24'd0;
    reg start = 1'b0;
    wire [31:0] bcd;
    wire done;

    bin2bcd #(.W(24), .DIGITS(8)) uut (
        .clk(clk), .reset_n(reset_n), .bin_in(bin_in),
        .start(start), .bcd(bcd), .done(done));

    always #10 clk = ~clk;

    integer errors = 0;

    task chk;
        input [255:0] name;
        input cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin
                $display("[FAIL] %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // BCD[31:0] → 整数，便于直接比对
    function integer bcd_val;
        input [31:0] b;
        integer k;
        begin
            bcd_val = 0;
            for (k = 7; k >= 0; k = k - 1)
                bcd_val = bcd_val * 10 + b[4*k +: 4];
        end
    endfunction

    // 完整跑一次转换：给 start，等 done
    task convert;
        input [23:0] v;
        integer guard;
        begin
            bin_in = v;
            @(posedge clk); #1; start = 1'b1;
            @(posedge clk); #1; start = 1'b0;
            guard = 0;
            while (!done && guard < 200) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            @(posedge clk); #1;
        end
    endtask

    reg [31:0] seen_bcd;
    integer done_cnt;

    initial begin
        #100 reset_n = 1'b1;
        #100;

        convert(24'd0);
        chk("0 -> BCD 0", bcd_val(bcd) == 0);

        convert(24'd7);
        chk("7 -> BCD 7", bcd_val(bcd) == 7);

        convert(24'd42);
        chk("42 -> BCD 42", bcd_val(bcd) == 42);

        convert(24'd999999);
        chk("999999 -> BCD 999999", bcd_val(bcd) == 999999);
        chk("999999 各位数码正确", bcd[3:0] == 4'd9 && bcd[7:4] == 4'd9 &&
                                  bcd[11:8] == 4'd9 && bcd[15:12] == 4'd9 &&
                                  bcd[19:16] == 4'd9 && bcd[23:20] == 4'd9);

        convert(24'd100000);
        chk("100000 -> BCD 100000", bcd_val(bcd) == 100000);

        convert(24'hFFFFFF);              // 16777215，8 位 BCD 刚好装下
        chk("16777215 -> BCD 16777215", bcd_val(bcd) == 16777215);

        // done 只能拉高一拍
        bin_in = 24'd1234;
        @(posedge clk); #1; start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        done_cnt = 0; seen_bcd = 32'd0;
        repeat (60) begin
            @(posedge clk); #1;
            if (done) begin
                done_cnt = done_cnt + 1;
                seen_bcd = bcd;
            end
        end
        chk("done 恰好一次", done_cnt == 1);
        chk("done 时 bcd = 1234", bcd_val(seen_bcd) == 1234);

        // 转换中途重新 start：结果必须是后一个值
        bin_in = 24'd5555;
        @(posedge clk); #1; start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        repeat (5) @(posedge clk);        // 只走 5 拍就打断
        #1; bin_in = 24'd8888;
        @(posedge clk); #1; start = 1'b1;
        @(posedge clk); #1; start = 1'b0;
        begin : restart_blk
            integer g;
            g = 0;
            while (!done && g < 200) begin
                @(posedge clk); #1; g = g + 1;
            end
        end
        @(posedge clk); #1;
        chk("中途重启 -> 取最后一次 start 的值 8888", bcd_val(bcd) == 8888);

        // 空闲时不该自己动
        seen_bcd = bcd;
        repeat (40) @(posedge clk);
        chk("空闲时 bcd 保持不变", bcd === seen_bcd);

        #200;
        if (errors == 0) $display("\n===== 全部用例通过 =====\n");
        else             $display("\n===== 失败 %0d 项 =====\n", errors);
        $finish;
    end

endmodule
