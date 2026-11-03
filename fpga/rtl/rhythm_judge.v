// ---------------------------------------------------------------------------
// rhythm_judge.v —— 音游模式判定核心（PERFECT / GOOD / MISS + 连击 + 计分）
//
// 为什么需要它：现有 score_note_matcher 只做"按下正确音高就 advance"，
// 没有时间概念 —— 先按后按都一样，这不是音游。本模块在它之上加时间窗判定。
//
// 时基：与 score_transport 同域的 frame_tick（本工程约 55.09 Hz，1 帧 ≈ 18.1 ms）
//   PERFECT_FRAMES=2 → 命中在目标出现后 0..1 帧（0..18 ms）
//   GOOD_FRAMES=5    → 2..4 帧（36..72 ms）
//   MISS_FRAMES=8    → 目标出现 8 帧（145 ms）仍未命中即判漏
//   这三个数按 BPM240 的 12 tick 制最坏情况留了余量，可在顶层按手感改参数。
//
// 输入 target_mask 直接复用 score_note_matcher 已有的 target_mask 输出，
// 因此音高到琴键的映射不必在这里重做一遍，避免与既有映射产生分歧。
// ---------------------------------------------------------------------------
module rhythm_judge #(
    parameter [4:0] PERFECT_FRAMES = 5'd2,
    parameter [4:0] GOOD_FRAMES    = 5'd5,
    parameter [4:0] MISS_FRAMES    = 5'd8
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        frame_tick,          // 单拍脉冲，节拍时基
    input  wire        enable,              // 1=音游模式开
    input  wire        clear_stats,

    input  wire        target_ready,        // 当前有目标音
    input  wire [6:0]  target_midi_note,
    input  wire [10:0] event_token,         // 事件变化即视为新目标
    input  wire [31:0] pressed,             // 琴键/压力通道按下掩码
    input  wire [31:0] target_mask,         // 来自 score_note_matcher
    input  wire        wrong_note,          // 按错音（1 拍）
    input  wire        advance,             // 事件推进（1 拍）

    output reg  [1:0]  judge_code,          // 1=PERFECT 2=GOOD 3=MISS
    output reg         judge_pulse,         // 判定产生（1 拍，供 UI 做打击特效）
    output reg  [7:0]  combo,
    output reg  [7:0]  best_combo,
    output reg  [23:0] score,
    output reg  [15:0] cnt_perfect,
    output reg  [15:0] cnt_good,
    output reg  [15:0] cnt_miss
);
    localparam J_NONE = 2'd0, J_PERFECT = 2'd1, J_GOOD = 2'd2, J_MISS = 2'd3;

    reg [10:0] token_d;
    reg [7:0]  w_cnt;        // 目标已等待的帧数
    reg        pending;      // 当前目标尚未判定
    wire       token_changed = (event_token != token_d);
    wire       hit_now = (pressed & target_mask) != 32'd0;

    reg [23:0] add_score;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            token_d <= 11'd0; w_cnt <= 8'd0; pending <= 1'b0;
            judge_code <= J_NONE; judge_pulse <= 1'b0;
            combo <= 8'd0; best_combo <= 8'd0; score <= 24'd0;
            cnt_perfect <= 16'd0; cnt_good <= 16'd0; cnt_miss <= 16'd0;
        end else begin
            judge_pulse <= 1'b0;
            token_d <= event_token;

            if (clear_stats) begin
                combo <= 8'd0; best_combo <= 8'd0; score <= 24'd0;
                cnt_perfect <= 16'd0; cnt_good <= 16'd0; cnt_miss <= 16'd0;
                pending <= 1'b0; w_cnt <= 8'd0;
            end else if (enable) begin
                // 新目标出现：重置等待计时，允许判定
                if (token_changed && target_ready) begin
                    w_cnt <= 8'd0;
                    pending <= 1'b1;
                end

                if (frame_tick && pending && w_cnt != 8'hFF)
                    w_cnt <= w_cnt + 8'd1;

                // 1) 命中判定：优先于超时，按等待帧数分级
                if (pending && target_ready && hit_now) begin
                    pending <= 1'b0;
                    judge_pulse <= 1'b1;
                    if (w_cnt < PERFECT_FRAMES) begin
                        judge_code <= J_PERFECT;
                        cnt_perfect <= cnt_perfect + 16'd1;
                        add_score <= 24'd100 + {16'd0, combo} * 24'd2;
                    end else if (w_cnt < GOOD_FRAMES) begin
                        judge_code <= J_GOOD;
                        cnt_good <= cnt_good + 16'd1;
                        add_score <= 24'd50 + {16'd0, combo};
                    end else begin
                        judge_code <= J_MISS;          // 迟到超窗
                        cnt_miss <= cnt_miss + 16'd1;
                        add_score <= 24'd0;
                        combo <= 8'd0;
                    end
                    if (w_cnt < GOOD_FRAMES) begin
                        score <= score + add_score;
                        combo <= (combo == 8'hFF) ? 8'hFF : combo + 8'd1;
                        if (combo + 8'd1 > best_combo) best_combo <= combo + 8'd1;
                    end
                end
                // 2) 超时判漏
                else if (pending && w_cnt >= MISS_FRAMES) begin
                    pending <= 1'b0;
                    judge_code <= J_MISS;
                    judge_pulse <= 1'b1;
                    cnt_miss <= cnt_miss + 16'd1;
                    combo <= 8'd0;
                end
                // 3) 事件推进仍未命中（自动播放/步进模式下漏掉）
                else if (advance && pending) begin
                    pending <= 1'b0;
                    judge_code <= J_MISS;
                    judge_pulse <= 1'b1;
                    cnt_miss <= cnt_miss + 16'd1;
                    combo <= 8'd0;
                end

                // 4) 错音：断连击，不计入漏
                if (wrong_note) combo <= 8'd0;
            end
        end
    end
endmodule
