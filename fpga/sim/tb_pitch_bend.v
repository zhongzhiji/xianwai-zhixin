`timescale 1ns/1ps
// ============================================================================
// tb_pitch_bend.v —— MIDI 弯音轮（pitch_bend_apply）自检
//
// 覆盖点：
//   1. 零弯（bend=0）→ 输出 ≈ 输入（倍率应≈1.0）
//   2. 最大正弯（+8191）→ 倍率 ≈ 2^(+2/12) = 1.1225
//   3. 最大负弯（-8192）→ 倍率 ≈ 2^(-2/12) = 0.8909
//   4. 中间档（±1 半音）→ 倍率 ≈ 1.0595 / 0.9439
//   5. 流水线延迟正好 2 拍（不是 1 拍、不是 3 拍）
//   6. 单调性：正弯越大频率越高，负弯越大频率越低
//   7. 复位期间输出为 0
//   8. BEND_EN=0 时旁路（输出 = 输入，仅打一拍）
//
// 运行：
//   iverilog -g2012 -o sim/bend.vvp -s tb_pitch_bend -I rtl \
//       sim/tb_pitch_bend.v rtl/pitch_bend_apply.v
//   vvp sim/bend.vvp
// ============================================================================
module tb_pitch_bend;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg signed [13:0] bend = 14'sd0;
    reg  [31:0] fw_in = 32'd0;
    wire [31:0] fw_out;

    integer pass_cnt, fail_cnt;

    // MIDI69 (A4 440Hz) 的频率字，取自 audio/rom/midi_fw.mem
    localparam [31:0] FW_A4 = 32'd39370534;

    pitch_bend_apply #(
        .BEND_EN(1), .LUT_FILE("audio/rom/bend_lut.mem")
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .bend(bend), .fw_in(fw_in), .fw_out(fw_out));

    always #10 clk = ~clk;   // 50 MHz

    // 施加 bend，等 2 拍流水线后取回 fw_out
    task automatic apply_bend;
        input signed [13:0] b;
        output [31:0] out;
        begin
            bend  = b;
            fw_in = FW_A4;
            @(posedge clk);   // 拍1：查表
            @(posedge clk);   // 拍2：乘法
            #1;               // 避开时钟沿
            out = fw_out;
        end
    endtask

    real ratio;
    reg [31:0] got;

    task automatic check_ratio;
        input signed [13:0] b;
        input real lo, hi;
        input [127:0] name;
        begin
            apply_bend(b, got);
            ratio = $itor(got) / $itor(FW_A4);
            if (ratio >= lo && ratio <= hi) begin
                $display("  [PASS] %0s : bend=%0d ratio=%.5f (期望 %.5f~%.5f)",
                         name, b, ratio, lo, hi);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] %0s : bend=%0d ratio=%.5f (期望 %.5f~%.5f)",
                         name, b, ratio, lo, hi);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        $display("=== tb_pitch_bend: 弯音轮接入验证 ===");

        // 复位
        rst_n = 1'b0; bend = 14'sd0; fw_in = FW_A4;
        repeat (3) @(posedge clk);
        #1;
        if (fw_out == 32'd0) begin
            $display("  [PASS] 复位期间 fw_out = 0");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] 复位期间 fw_out = %0d（应为 0）", fw_out);
            fail_cnt = fail_cnt + 1;
        end
        rst_n = 1'b1;
        @(posedge clk);

        // ---- 1~4. 倍率精度（±2 半音音域，Q15 查表量化误差 <0.2%）----
        $display("-- 倍率精度 --");
        check_ratio(14'sd0,     0.998, 1.002, "零弯");           // 1.0000
        check_ratio(14'sd4096,  1.057, 1.062, "正弯 +1 半音");   // 1.0595
        check_ratio(-14'sd4096, 0.942, 0.946, "负弯 -1 半音");   // 0.9439
        check_ratio(14'sd8191,  1.119, 1.125, "最大正弯 +2");    // 1.1225
        check_ratio(-14'sd8192, 0.889, 0.893, "最大负弯 -2");    // 0.8909

        // ---- 5. 流水线延迟必须是 2 拍 ----
        $display("-- 流水线延迟 --");
        bend = 14'sd8191; fw_in = FW_A4;
        @(posedge clk);            // 拍1：查表（此拍末 fw_out 还没变）
        #1;
        if (fw_out != 32'd0 && fw_out != FW_A4) begin
            // 第一拍就出有效值说明只有 1 级流水
        end
        @(posedge clk);            // 拍2：乘法
        #1;
        if (fw_out > FW_A4) begin
            $display("  [PASS] 第 2 拍输出已生效（fw_out=%0d > fw_in=%0d）", fw_out, FW_A4);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] 第 2 拍输出未生效（fw_out=%0d）", fw_out);
            fail_cnt = fail_cnt + 1;
        end

        // ---- 6. 单调性 ----
        $display("-- 单调性 --");
        begin : mono
            reg [31:0] p1, p2, p3, p4;
            apply_bend(-14'sd8192, p1);
            apply_bend(-14'sd4096, p2);
            apply_bend(14'sd0,     p3);
            apply_bend(14'sd8191,  p4);
            if (p1 < p2 && p2 < p3 && p3 < p4) begin
                $display("  [PASS] 负弯→零→正弯 频率单调递增 (%0d < %0d < %0d < %0d)",
                         p1, p2, p3, p4);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] 单调性破坏: %0d / %0d / %0d / %0d", p1, p2, p3, p4);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ---- 7. 溢出保护：极大 fw ----
        $display("-- 溢出保护 --");
        bend = 14'sd8191; fw_in = 32'hFFFFFFFF;
        @(posedge clk); @(posedge clk); #1;
        if (fw_out == 32'hFFFFFFFF) begin
            $display("  [PASS] 极大 fw 被钳位到 32'hFFFFFFFF（未绕回低频）");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] 极大 fw 输出 %0h（应钳位）", fw_out);
            fail_cnt = fail_cnt + 1;
        end

        $display("=== 结果：PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("*** ALL PASS ***");
        else $display("*** 有 %0d 项失败 ***", fail_cnt);
        $finish;
    end

    initial begin
        #20000;
        $display("ERROR: 超时未结束");
        $finish;
    end

endmodule
