`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_fsr_gate.v —— fsr_gate 两级判决流水线回归测试（N=16，与工程实际一致）
//   覆盖：首帧定基线 / 越阈起音 / 迟滞释音 / 小抖动不误触 / 多通道 / dev_max
//
//   ⚠ dev_max 是「多周期串行求最大值」，扫完 16 个点要 17 拍。
//     所以两帧之间必须留出 ≥17 拍，否则扫描被下一帧打断，dev_max 不准。
// ---------------------------------------------------------------------------
module tb_fsr_gate;

    localparam N = 16;

    reg                 clk = 1'b0;
    reg                 rst_n = 1'b0;
    reg                 new_frame = 1'b0;
    reg  [24*N-1:0]     vals;
    wire [N-1:0]        gate;
    wire [23:0]         dev_max;

    always #10 clk = ~clk;

    fsr_gate #(.N(N)) uut(
        .clk(clk), .rst_n(rst_n), .new_frame(new_frame), .vals(vals),
        .gate(gate), .dev_max(dev_max));

    integer errors = 0;
    integer i;

    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin $display("[FAIL] %0s", name); errors = errors + 1; end
        end
    endtask

    task set_all;                 // 把所有点设成同一个值
        input [23:0] v;
        begin
            for (i = 0; i < N; i = i + 1) vals[24*i +: 24] = v;
        end
    endtask

    task send_frame;              // 送一帧，等 20 拍让串行扫描跑完
        begin
            @(posedge clk); new_frame = 1'b1;
            @(posedge clk); new_frame = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    initial begin
        vals = {N*24{1'b0}};
        #200 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1. 首帧定静息基线 1000 ----
        // 首帧时 base_q 还是复位值 0，所以这一帧的 dev_max ≈ 1000（与原设计一致）；
        // 基线要等第二帧才体现出来。
        set_all(24'd1000); send_frame;
        chk("首帧不应触发（首帧只用于定基线）", gate == {N{1'b0}});
        chk("首帧 dev_max ≈ 1000（基线尚为 0）", dev_max >= 24'd990 && dev_max <= 24'd1010);
        send_frame;                                  // 再送一帧同样的值
        chk("第二帧基线已对齐，dev_max ≈ 0", dev_max < 24'd32);

        // ---- 2. 通道 0 压下 +200（> 阈值 32）----
        set_all(24'd1000); vals[24*0 +: 24] = 24'd1200; send_frame;
        chk("通道0 越阈起音", gate[0] === 1'b1);
        chk("其余通道仍松开", gate[15:1] == 15'd0);
        chk("dev_max 反映最大偏差 ≈200", dev_max >= 24'd190 && dev_max <= 24'd210);

        // ---- 3. 回到基线附近（偏差 5 < 迟滞 16）→ 释音 ----
        set_all(24'd1000); vals[24*0 +: 24] = 24'd1005; send_frame;
        chk("回到基线附近释音", gate[0] === 1'b0);

        // ---- 4. 微小抖动不应触发（阈值至少 32）----
        set_all(24'd1000); vals[24*0 +: 24] = 24'd1010; send_frame;
        chk("10 的抖动不触发（阈值 >= 32）", gate[0] === 1'b0);

        // ---- 5. 多通道同时触发 ----
        set_all(24'd1000);
        vals[24*3 +: 24] = 24'd1500;
        vals[24*2 +: 24] = 24'd1500;
        send_frame;
        chk("通道3/2 同时起音", gate[3] === 1'b1 && gate[2] === 1'b1);

        // ---- 6. 全部回基线 → 全松开 ----
        set_all(24'd1000); send_frame;
        chk("全部回到基线后全松开", gate == {N{1'b0}});

        #1000;
        $display("=====================================");
        if (errors == 0) $display("  fsr_gate: 全部用例通过");
        else             $display("  fsr_gate: 失败 %0d 项", errors);
        $display("=====================================");
        $finish;
    end

endmodule
