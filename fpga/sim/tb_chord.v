`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_chord.v —— chord_from_keys 自校验：音符集合 → 根音 + 音程掩码
// ---------------------------------------------------------------------------
module tb_chord;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [127:0] key_state = 128'd0;
    wire [6:0]   root_note;
    wire [15:0]  interval_mask;
    wire         active;

    always #10 clk = ~clk;

    chord_from_keys #(.KEYS(128), .IDXW(7)) uut(
        .clk(clk), .rst_n(rst_n), .key_state(key_state),
        .root_note(root_note), .interval_mask(interval_mask), .active(active));

    integer errors = 0;

    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin $display("[FAIL] %0s", name); errors = errors + 1; end
        end
    endtask

    task step;                 // 折半流水线 9 拍一轮，等两轮确保结果已锁存
        begin
            repeat (20) @(posedge clk);
            #2;
        end
    endtask

    initial begin
        #200 rst_n = 1'b1;
        step;

        // ---- 1. 空表 ----
        key_state = 128'd0; step;
        chk("空表：active=0", active === 1'b0);
        chk("空表：掩码为 0", interval_mask === 16'd0);

        // ---- 2. 单音 C4(60) ----
        key_state = (128'd1 << 60); step;
        chk("单音：active=1", active === 1'b1);
        chk("单音：根音 = 60", root_note == 7'd60);
        chk("单音：只有 bit0 亮", interval_mask === 16'h0001);

        // ---- 3. 大三和弦 C-E-G (60,64,67) ----
        key_state = (128'd1 << 60) | (128'd1 << 64) | (128'd1 << 67); step;
        chk("大三和弦：根音 = 60", root_note == 7'd60);
        chk("大三和弦：掩码 = 0x0091 (0/4/7 半音)",
            interval_mask === 16'h0091);

        // ---- 4. 换根音：同样形状移到 D ----
        key_state = (128'd1 << 62) | (128'd1 << 66) | (128'd1 << 69); step;
        chk("换根音：根音 = 62", root_note == 7'd62);
        chk("换根音：掩码形状不变", interval_mask === 16'h0091);

        // ---- 5. 超过 15 半音的键被接口上限裁掉 ----
        key_state = (128'd1 << 40) | (128'd1 << 56); step;   // 相差 16 半音
        chk("超 15 半音：根音 = 40", root_note == 7'd40);
        chk("超 15 半音：只保留 bit0", interval_mask === 16'h0001);

        // ---- 6. 最低音做根音（手弹和弦时先按低音）----
        key_state = (128'd1 << 48) | (128'd1 << 52) | (128'd1 << 55) | (128'd1 << 60); step;
        chk("四音：根音取最低 48", root_note == 7'd48);
        chk("四音：掩码 = 0x1091 (0/4/7/12 半音)", interval_mask === 16'h1091);
        chk("四音：bit12 对应 60-48=12", interval_mask[12] === 1'b1);

        // ---- 7. 边界：最高音 127 ----
        key_state = (128'd1 << 127); step;
        chk("最高音：active=1 且根音=127", active === 1'b1 && root_note == 7'd127);
        chk("最高音：掩码 bit0=1", interval_mask[0] === 1'b1);

        #1000;
        $display("=====================================");
        if (errors == 0) $display("  chord_from_keys: 全部用例通过");
        else             $display("  chord_from_keys: 失败 %0d 项", errors);
        $display("=====================================");
        $finish;
    end

endmodule
