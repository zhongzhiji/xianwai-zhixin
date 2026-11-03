// ---------------------------------------------------------------------------
// key_matrix_scan.v —— 电子琴/钢琴键盘行列矩阵扫描 + 消抖
//
//  适用：把 61/49 键电子琴的键盘总成（或任何行列矩阵键盘）直接接到 FPGA。
//  入门电子琴的键盘本质就是「单触点行列矩阵」：61 个键用 8 行 × 8 列
//  （或 6 行 × 11 列）就扫完了，主控只用十几个 IO。拆掉原 COB 主控后，
//  把排线飞到 FPGA，本模块负责扫出 61 个键的按下/松开状态。
//
//  接线：
//    行 ROW[7:0] → FPGA 输出，推挽，同一时刻只拉低一根（ACTIVE_LOW=1）
//    列 COL[7:0] → FPGA 输入，PULL_MODE=UP；该行有键按下时对应列被拉低
//
//  ⚠ 串键（ghosting）：单触点矩阵同时按 3 键会产生虚假的第 4 键。
//     要么在每个键上串一个 1N4148（工作量大），要么软件上限制 ≤2 键。
//     本模块检测到 ≥3 键同时按下时拉高 ghost_warn，交由上层决策。
//
//  输出：
//    key_state   电平型，每个 bit = 一个键的当前稳定状态（1=按下）
//                （复音/和弦场景直接用它，延迟最小）
//    key_change  单拍脉冲，任一键状态发生变化
//    key_valid   单拍脉冲，有新键按下（同一帧多个时先报编号最小的）
//    key_index   新按下键的编号 0..ROWS*COLS-1（行优先：idx = row*COLS + col）
//
//  ⚠ 时序：消抖在「一帧扫完」的下一拍更新 key_state，事件提取又在其后一拍比较
//    key_state 与 state_prev，因此 key_valid / key_index / key_change 比
//    key_state 晚一个完整扫描周期（8 行 × ROW_US，默认 800 µs）。
//    人耳/人手完全无感；但写测试台时必须多等一帧再断言。
// ---------------------------------------------------------------------------
module key_matrix_scan #(
    parameter ROWS       = 8,
    parameter COLS       = 8,
    parameter KEYW       = 6,               // ceil(log2(ROWS*COLS))
    parameter CLK_HZ     = 50000000,
    parameter ROW_US     = 100,             // 每行扫描驻留时间（µs）
    parameter FRAMES     = 3,               // 连续几帧一致才认定状态变化
    parameter ACTIVE_LOW = 1                // 1=行低有效/列按下为低（常见接法）
)(
    input  wire                  clk,
    input  wire                  rst_n,

    output reg  [ROWS-1:0]       row_drv,     // 行驱动
    input  wire [COLS-1:0]       col_in,      // 列采样

    output reg  [ROWS*COLS-1:0]  key_state,   // 稳定后的全键状态
    output reg                   key_change,  // 单拍：状态有变化
    output reg                   key_valid,   // 单拍：有新键按下
    output reg  [KEYW-1:0]       key_index,
    output reg                   ghost_warn   // 同时按下 ≥3 键
);

    localparam KEYS = ROWS * COLS;

    // ========================================================================
    //  1. 行扫描时序
    // ========================================================================
    localparam [31:0] CLKS_PER_ROW = (CLK_HZ / 1000000) * ROW_US;

    reg [31:0] row_cnt;
    reg [4:0]  row_idx;                      // 支持到 32 行
    wire       row_tick = (row_cnt == CLKS_PER_ROW - 32'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin row_cnt <= 32'd0; row_idx <= 5'd0; end
        else if (row_tick) begin
            row_cnt <= 32'd0;
            row_idx <= (row_idx == ROWS[4:0] - 5'd1) ? 5'd0 : row_idx + 5'd1;
        end else row_cnt <= row_cnt + 32'd1;
    end

    // 行驱动：同一时刻只拉低（或只拉高）一根
    integer r;
    always @(*) begin
        for (r = 0; r < ROWS; r = r + 1) begin
            if (r == row_idx)
                row_drv[r] = ACTIVE_LOW ? 1'b0 : 1'b1;
            else
                row_drv[r] = ACTIVE_LOW ? 1'b1 : 1'b0;
        end
    end

    // 列采样：把「按下」统一成 1
    wire [COLS-1:0] col_pressed = ACTIVE_LOW ? ~col_in : col_in;

    // ========================================================================
    //  2. 采样锁存 + 消抖
    // ========================================================================
    reg [KEYS-1:0] sample;        // 本帧扫描到的原始快照
    reg [KEYS-1:0] last_sample;   // 上一次的快照（用于比较是否稳定）
    reg [3:0]      dcnt [0:KEYS-1];
    reg [KEYS-1:0] state_prev;
    reg            frame_done;

    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample      <= {KEYS{1'b0}};
            last_sample <= {KEYS{1'b0}};
            key_state   <= {KEYS{1'b0}};
            frame_done  <= 1'b0;
            for (k = 0; k < KEYS; k = k + 1) dcnt[k] <= 4'd0;
        end else begin
            frame_done  <= 1'b0;

            // --- 在每一行结束前的最后一拍采样该行所有列 ---
            if (row_tick) begin
                for (k = 0; k < COLS; k = k + 1)
                    sample[row_idx * COLS + k] <= col_pressed[k];
                if (row_idx == ROWS[4:0] - 5'd1) frame_done <= 1'b1;
            end

            // --- 一帧扫完：逐键消抖 ---
            if (frame_done) begin
                for (k = 0; k < KEYS; k = k + 1) begin
                    if (sample[k] == last_sample[k]) begin
                        if (dcnt[k] != 4'd15) dcnt[k] <= dcnt[k] + 4'd1;
                    end else begin
                        dcnt[k]       <= 4'd0;
                        last_sample[k] <= sample[k];
                    end
                    if (dcnt[k] >= FRAMES[3:0])
                        key_state[k] <= last_sample[k];
                end
            end
        end
    end

    // ========================================================================
    //  3. 事件提取（在 frame_done 的下一拍）
    //
    //     ⚠ key_change / key_valid / key_index 只由本块驱动。
    //       之前它们在消抖块里也有「每拍清零」的驱动，两个 always 块同时写同一个
    //       寄存器，Verilog 不保证 NBA 先后顺序 —— 仿真里清零把置位吃掉，
    //       上板则会变成多驱动不确定值。所有默认值统一收到本块。
    // ========================================================================
    wire [KEYS-1:0] newly = key_state & ~state_prev;

    integer pc, best;
    reg [31:0] pop;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_prev <= {KEYS{1'b0}};
            ghost_warn <= 1'b0;
            key_change <= 1'b0;
            key_valid  <= 1'b0;
            key_index  <= {KEYW{1'b0}};
        end else begin
            key_change <= 1'b0;
            key_valid  <= 1'b0;
            if (frame_done) begin
                // 统计同时按下的键数
                pop = 32'd0;
                for (pc = 0; pc < KEYS; pc = pc + 1)
                    if (key_state[pc]) pop = pop + 32'd1;
                ghost_warn <= (pop >= 32'd3);

                if (key_state != state_prev) key_change <= 1'b1;

                // 报编号最小的新按下键
                best = -1;
                for (pc = 0; pc < KEYS; pc = pc + 1)
                    if (newly[pc] && best < 0) best = pc;
                if (best >= 0) begin
                    key_valid <= 1'b1;
                    key_index <= best[KEYW-1:0];
                end
                state_prev <= key_state;
            end
        end
    end

endmodule
