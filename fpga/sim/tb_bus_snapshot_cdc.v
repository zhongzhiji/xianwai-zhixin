`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_bus_snapshot_cdc.v —— bundled-data 快照邮箱跨时钟域回归
//
//   目的：验证「把 src_data != previous 的比较结果单独寄存成 neq_r」之后，
//         握手语义没有被破坏：
//           (1) 每次源端换值，目的端最终一定能拿到新值（不丢）
//           (2) 目的端拿到的永远是一个**完整**的源端快照（不撕裂）
//
//   撕裂检测：源端发送 {tag, ~tag}，目的端只要出现 high != ~low 就是撕裂。
//   两时钟取 20ns / 29ns（非整数倍，相位关系最恶劣）。
// ---------------------------------------------------------------------------
module tb_bus_snapshot_cdc;

    localparam W = 16;

    reg             src_clk = 1'b0;
    reg             dst_clk = 1'b0;
    reg             src_reset_n = 1'b0;
    reg             dst_reset_n = 1'b0;
    reg  [W-1:0]    src_data = {W{1'b0}};
    wire [W-1:0]    dst_data;

    always #10   src_clk = ~src_clk;      // 50 MHz
    always #14.5 dst_clk = ~dst_clk;      // ≈34.5 MHz（与 50MHz 非整数倍）

    bus_snapshot_cdc #(.WIDTH(W)) uut(
        .src_clk(src_clk), .src_reset_n(src_reset_n), .src_data(src_data),
        .dst_clk(dst_clk), .dst_reset_n(dst_reset_n), .dst_data(dst_data));

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

    // 撕裂监视：目的端每一拍都要满足 high == ~low
    // （dst_data==0 是复位初值，还没开始传，不算撕裂）
    always @(posedge dst_clk) begin
        if (dst_reset_n && dst_data !== {W{1'b0}} &&
            dst_data[W-1:W/2] !== ~dst_data[W/2-1:0]) begin
            $display("[FAIL] 撕裂！dst_data=%h (high=%h ~low=%h)",
                     dst_data, dst_data[W-1:W/2], ~dst_data[W/2-1:0]);
            errors = errors + 1;
        end
    end

    task send;                      // 换一个值，然后等足够长时间让握手完成
        input [7:0] tag;
        begin
            src_data <= {tag, ~tag};
            repeat (60) @(posedge src_clk);      // 60 个 src 周期 >> 握手往返
            if (dst_data !== {tag, ~tag}) begin
                $display("[FAIL] 第 %0d 次未送达：期望 %h 实到 %h", i, {tag, ~tag}, dst_data);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #100 src_reset_n = 1'b1; dst_reset_n = 1'b1;
        repeat (20) @(posedge src_clk);

        chk("复位后目的端为 0", dst_data == {W{1'b0}});

        for (i = 1; i <= 24; i = i + 1) begin
            send(i[7:0] ^ 8'h5A);               // 走遍各种位型，含相邻位同时翻转
        end

        // ---- 连续快速换值：验证不会卡死在握手里 ----
        for (i = 0; i < 8; i = i + 1) begin
            src_data <= {8'hF0 + i[7:0], ~(8'hF0 + i[7:0])};
            repeat (3) @(posedge src_clk);       // 只等 3 拍就换下一个（会被合并）
        end
        repeat (200) @(posedge src_clk);
        chk("快速连续换值后仍能收敛到最后一个值",
            dst_data[W-1:W/2] === (8'hF0 + 8'd7));

        #1000;
        $display("=====================================");
        if (errors == 0) $display("  bus_snapshot_cdc: 全部用例通过（无丢失、无撕裂）");
        else             $display("  bus_snapshot_cdc: 失败 %0d 项", errors);
        $display("=====================================");
        $finish;
    end

endmodule
