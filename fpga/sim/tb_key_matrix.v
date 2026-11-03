`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_key_matrix.v —— 8×8 键盘矩阵扫描自校验
//   列模型：只有当行驱动拉低选中该行、且该键在 pressed 表里的对应位为 1 时，
//   对应列才被拉低（等价于真实键盘的单触点 + 上拉）。
// ---------------------------------------------------------------------------
module tb_key_matrix;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    wire [7:0] row_drv;
    reg  [7:0] col_in;
    wire [63:0] key_state;
    wire        key_change, key_valid, ghost_warn;
    wire [5:0]  key_index;

    localparam ROW_US = 1;                       // 仿真用短驻留
    localparam CLKS_PER_ROW = 50 * ROW_US;
    localparam FRAME = CLKS_PER_ROW * 8;

    always #10 clk = ~clk;                       // 50 MHz

    key_matrix_scan #(
        .ROWS(8), .COLS(8), .KEYW(6),
        .CLK_HZ(50000000), .ROW_US(ROW_US), .FRAMES(3), .ACTIVE_LOW(1)
    ) uut(
        .clk(clk), .rst_n(rst_n),
        .row_drv(row_drv), .col_in(col_in),
        .key_state(key_state), .key_change(key_change),
        .key_valid(key_valid), .key_index(key_index),
        .ghost_warn(ghost_warn));

    reg [63:0] pressed;
    integer r, c;
    reg [7:0] col_r;

    always @(*) begin
        col_r = 8'hFF;
        for (r = 0; r < 8; r = r + 1) begin
            if (row_drv[r] == 1'b0) begin
                for (c = 0; c < 8; c = c + 1) begin
                    if (pressed[r*8 + c]) col_r[c] = 1'b0;
                end
            end
        end
        col_in = col_r;
    end

    integer errors = 0;
    integer i;
    reg     saw_valid;
    reg [5:0] valid_idx;

    always @(posedge clk) if (key_valid) begin saw_valid <= 1'b1; valid_idx <= key_index; end

    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin $display("[FAIL] %0s", name); errors = errors + 1; end
        end
    endtask

    task wait_frames;
        input integer n;
        begin
            repeat (n * FRAME + 10) @(posedge clk);
        end
    endtask

    initial begin
        pressed = 64'd0;
        saw_valid = 1'b0;
        #200 rst_n = 1'b1;
        wait_frames(2);

        // ---- 1. 空闲：不应有任何键 ----
        chk("空闲时无键按下", key_state == 64'd0);

        // ---- 2. 单键 key0 (row0,col0) ----
        pressed = 64'd1;
        wait_frames(9);   // 消抖 3~5 帧 + 事件提取再晚 1 帧
        chk("按下 key0 后 key_state[0]=1", key_state[0] === 1'b1);
        chk("其余键仍为 0", key_state[63:1] == 63'd0);
        chk("产生过 key_valid", saw_valid === 1'b1);
        chk("key_index 报的是 0", valid_idx == 6'd0);

        // ---- 3. 再加两键构成和弦 ----
        pressed = 64'd1 | (64'd1 << 9) | (64'd1 << 16);
        wait_frames(9);
        chk("三键和弦：key0/9/16 全为 1",
            key_state[0] === 1'b1 && key_state[9] === 1'b1 && key_state[16] === 1'b1);
        chk("三键同时按下时 ghost_warn=1", ghost_warn === 1'b1);

        // ---- 4. 松开中间键 ----
        pressed = 64'd1 | (64'd1 << 16);
        wait_frames(6);
        chk("松开 key9 后该位清零", key_state[9] === 1'b0);
        chk("key0 与 key16 仍保持", key_state[0] === 1'b1 && key_state[16] === 1'b1);

        // ---- 5. 全部松开 ----
        pressed = 64'd0;
        wait_frames(6);
        chk("全部松开后 key_state 归零", key_state == 64'd0);
        chk("ghost_warn 随之清除", ghost_warn === 1'b0);

        // ---- 6. 行驱动恒为「只有一根拉低」----
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk);
            // 低有效 one-hot：取反后应恰好只有 1 个 bit 为 1
            if ((~row_drv & ((~row_drv) - 8'd1)) != 8'd0) begin
                $display("[FAIL] 行驱动不是单根低有效 row_drv=%b", row_drv);
                errors = errors + 1;
            end
        end
        $display("[PASS] 行驱动恒为单根低有效");

        #1000;
        $display("=====================================");
        if (errors == 0) $display("  key_matrix_scan: 全部用例通过");
        else             $display("  key_matrix_scan: 失败 %0d 项", errors);
        $display("=====================================");
        $finish;
    end

endmodule
