`timescale 1ns/1ps
// ============================================================================
//  tb_touch_carrier.v
//
//  双 MPR121 共享总线的线级仿真。两个从机模型各自只应答自己的地址，
//  DUT 内部任何信号都不强制、不窥探 —— 全部结论从 SCL/SDA 与输出端口观察。
//
//  覆盖：
//    1. 两颗都在线（online 拉高）
//    2. MPR_A ELE0  → keys[0]
//    3. MPR_A ELE11 → keys[11]
//    4. MPR_B ELE0  → keys[12]
//    5. MPR_B ELE3  → keys[15]
//    6. MPR_B ELE4  → strings[0]（琴弦1）
//    7. MPR_B ELE10 → bend
//    8. MPR_B ELE11 → vib
//    9. 多键同时按下
//   10. 掉线（present=0）→ clear_event 且 keys 清零
//
//  仿真加速：POWER_WAIT_MS/SETTLE_MS 调到 2ms，不影响逻辑等价性。
// ============================================================================
module tb_touch_carrier;
    reg        clk = 1'b0;
    reg        reset_n = 1'b0;
    wire       scl, sda;
    wire       irq_n;
    reg        present_a = 1'b0, present_b = 1'b0;
    reg [15:0] status_a = 16'd0, status_b = 16'd0;
    // 两颗 MPR121 的 IRQ 开漏并联，任一颗有触摸就拉低
    assign irq_n = ~((status_a != 16'd0) || (status_b != 16'd0));

    wire [15:0] keys, key_press, key_release;
    wire [5:0]  strings, string_press;
    wire        bend, vib, online, fault, clear_event, error_event, sample_valid;
    wire [2:0]  fault_code;

    integer errors = 0;
    integer wa, ra, sa, pa, raa, rna;
    integer wb, rb, sb, pb, rab, rnb;

    // 50 MHz
    always #10 clk = ~clk;

    pullup(scl);
    pullup(sda);

    touch_carrier #(
        .CLK_HZ(50000000), .I2C_HZ(100000),
        .POLL_US(2000), .POWER_WAIT_MS(2), .RESET_WAIT_MS(1),
        .SETTLE_MS(2), .RETRY_MS(20)
    ) dut (
        .clk(clk), .reset_n(reset_n), .scl(scl), .sda(sda), .irq_n(irq_n),
        .keys(keys), .key_press(key_press), .key_release(key_release),
        .strings(strings), .string_press(string_press),
        .bend(bend), .vib(vib),
        .online(online), .fault(fault), .fault_code(fault_code),
        .clear_event(clear_event), .error_event(error_event),
        .sample_valid(sample_valid));

    mpr121_slave_model #(.ADDRESS(7'h5a)) slave_a (
        .scl(scl), .sda(sda), .present(present_a), .nack_read_address(1'b0),
        .touch_status(status_a), .hold_scl_low(1'b0), .hold_sda_low(1'b0),
        .writes(wa), .reads(ra), .starts(sa), .stops(pa),
        .read_acks(raa), .read_nacks(rna));

    mpr121_slave_model #(.ADDRESS(7'h5b)) slave_b (
        .scl(scl), .sda(sda), .present(present_b), .nack_read_address(1'b0),
        .touch_status(status_b), .hold_scl_low(1'b0), .hold_sda_low(1'b0),
        .writes(wb), .reads(rb), .starts(sb), .stops(pb),
        .read_acks(rab), .read_nacks(rnb));

    task check;
        input [255:0] name;
        input         cond;
        begin
            if (!cond) begin
                $display("  FAIL: %0s", name);
                errors = errors + 1;
            end else begin
                $display("  PASS: %0s", name);
            end
        end
    endtask

    // 等 n 次成功采样（用 sample_valid 计数，不窥探内部）
    integer seen;
    task wait_samples;
        input integer n;
        begin
            seen = 0;
            while (seen < n) begin
                @(posedge clk);
                if (sample_valid) seen = seen + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_touch_carrier: dual MPR121 bus arbitration ===");
        reset_n = 1'b0;
        #1000;
        reset_n = 1'b1;
        present_a = 1'b1;
        present_b = 1'b1;

        // 1. 等待两颗都在线
        wait(online === 1'b1);
        #100000;
        check("both MPR121 online", online === 1'b1);
        check("slave A got writes",  wa > 40);
        check("slave B got writes",  wb > 40);
        check("no fault after init", fault === 1'b0);

        // 2. MPR_A ELE0 -> keys[0]
        status_a = 16'h0001;
        wait_samples(3);
        check("MPR_A ELE0 -> keys[0]", keys[0] === 1'b1);

        // 3. MPR_A ELE11 -> keys[11]
        status_a = 16'h0800;
        wait_samples(3);
        check("MPR_A ELE11 -> keys[11]", keys[11] === 1'b1);
        check("keys[0] released",        keys[0] === 1'b0);

        // 4. MPR_B ELE0 -> keys[12]
        status_a = 16'h0000;
        status_b = 16'h0001;
        wait_samples(3);
        check("MPR_B ELE0 -> keys[12]", keys[12] === 1'b1);

        // 5. MPR_B ELE3 -> keys[15]
        status_b = 16'h0008;
        wait_samples(3);
        check("MPR_B ELE3 -> keys[15]", keys[15] === 1'b1);

        // 6. MPR_B ELE4 -> strings[0]
        status_b = 16'h0010;
        wait_samples(3);
        check("MPR_B ELE4 -> strings[0]", strings[0] === 1'b1);
        check("keys[12] released",        keys[12] === 1'b0);

        // 7. MPR_B ELE10 -> bend
        status_b = 16'h0400;
        wait_samples(3);
        check("MPR_B ELE10 -> bend", bend === 1'b1);

        // 8. MPR_B ELE11 -> vib
        status_b = 16'h0800;
        wait_samples(3);
        check("MPR_B ELE11 -> vib", vib === 1'b1);
        check("bend released",      bend === 1'b0);

        // 9. 多键同时：A 的 ELE0..3 + B 的 ELE0..1
        status_a = 16'h000F;
        status_b = 16'h0003;
        wait_samples(3);
        check("multi-key A[3:0]",    keys[3:0]   === 4'hF);
        check("multi-key [13:12]",   keys[13:12] === 2'h3);
        check("16 keys total map",   keys        === 16'h300F);

        // 10. 掉线 → clear_event 且清键
        status_a = 16'h000F;
        status_b = 16'h0003;
        wait_samples(2);
        present_a = 1'b0;
        present_b = 1'b0;
        begin : drop
            integer t;
            t = 0;
            while (t < 4000000 && clear_event !== 1'b1) begin
                @(posedge clk); t = t + 1;
            end
        end
        // clear_event 只来自先失败的那颗，另一颗要等它自己的下一次轮询
        // 才失败清键（2ms 轮询 + 仲裁交替）。这里等到 keys 真的归零。
        begin : drain
            integer t2;
            t2 = 0;
            while (t2 < 4000000 && keys !== 16'd0) begin
                @(posedge clk); t2 = t2 + 1;
            end
        end
        check("keys cleared after drop", keys === 16'd0);
        check("strings cleared after drop", strings === 6'd0);
        check("bend/vib cleared", bend === 1'b0 && vib === 1'b0);

        $display("=== errors = %0d ===", errors);
        if (errors == 0) $display("TOUCH CARRIER CHECK PASS");
        else             $display("TOUCH CARRIER CHECK FAIL");
        $finish;
    end

    // 总时限保护
    initial begin
        #400000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
