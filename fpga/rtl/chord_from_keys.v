// ---------------------------------------------------------------------------
// chord_from_keys.v —— 把「当前按住的音符集合」压成复音引擎能吃的和弦
//
//  为什么需要它：fsr32_engine 的 ext_gate/ext_freq_word 接口是「根音 + 相对音程
//  掩码」结构（16 位 = 根音之上 0..15 半音）。钢琴/ MIDI 键盘弹下的多个键天然
//  就是一个和弦，正好可以直接喂进去，不必为每个键单独分配声部。
//
//  规则：
//    - 根音 = 当前按住的最低音符（和弦转位时听感最稳，也和 bt 链路一致）
//    - interval_mask[j] = 根音之上第 j 个半音是否按下（j=0 恒为 1）
//    - 超过根音 15 半音的键会被忽略 —— 这是引擎接口上限，不是 bug
//
//  ★ 为什么用「逐次折半」而不是「for 循环优先级编码器 + 可变右移」：
//    v1 写法是
//        for (i=0;i<128;i++) if (!found && key_state[i]) begin low=i; found=1; end
//        shifted = key_state >> low;
//    综合出来是 **128 级串行的优先级链 + 128 位桶形移位器**，实测在 50MHz 下
//    数据延迟 21.4ns（周期只有 20ns），一个模块就炸出 ~18 个 setup 违例端点。
//
//    v2 改成「每拍把候选区间折半」：判断低半区是否非零，非零就取低半区、
//    否则取高半区并把索引加上半区宽度。128 → 64 → 32 → … → 1，共 7 拍，
//    每拍只有「一个 64 位归约或 + 一个 2:1 选择器」，延迟极小。
//    折半结束后最低按下位已经落在 cur_r[0]，cur_r[15:0] 直接就是音程掩码。
//    代价：结果晚 9 拍（180ns）才更新 —— 人手按键最短也有几十毫秒，无感。
// ---------------------------------------------------------------------------
module chord_from_keys #(
    parameter KEYS = 128,                  // 音符状态位宽（本工程固定 128）
    parameter IDXW = 7                     // ceil(log2(KEYS))
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [KEYS-1:0]  key_state,

    output reg  [6:0]       root_note,     // 最低按住音符的 MIDI 编号
    output reg  [15:0]      interval_mask, // 相对根音的半音掩码
    output reg              active         // 至少有一个键按下
);

    reg [3:0]    st;                       // 0=装载 1..7=折半 8=锁存结果
    reg [6:0]    idx_r;
    reg [127:0]  cur_r;
    reg          found_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= 4'd0;
            idx_r         <= 7'd0;
            cur_r         <= 128'd0;
            found_r       <= 1'b0;
            root_note     <= 7'd0;
            interval_mask <= 16'd0;
            active        <= 1'b0;
        end else begin
            case (st)
                // ---- 装载：开始新一轮检索 ----
                4'd0: begin
                    cur_r   <= key_state;
                    idx_r   <= 7'd0;
                    found_r <= |key_state;
                    st      <= 4'd1;
                end

                // ---- 逐次折半：每拍只看一次归约或 + 一个右移 ----
                //     ★ 低半区非零时**整体不动**（不能把高半区清零！）：
                //       音程掩码要的是最低位之上 0..15 半音，高半区里可能正好有
                //       落在窗口内的音（例如最低位在 60，64/67 就在 [127:64] 里）。
                //       只有确认最低位在高半区时，才整体右移把窗口拉下来。
                4'd1: begin
                    if (!(|cur_r[63:0])) begin
                        cur_r <= {64'd0, cur_r[127:64]}; idx_r <= idx_r + 7'd64;
                    end
                    st <= 4'd2;
                end
                4'd2: begin
                    if (!(|cur_r[31:0])) begin
                        cur_r <= {32'd0, cur_r[127:32]}; idx_r <= idx_r + 7'd32;
                    end
                    st <= 4'd3;
                end
                4'd3: begin
                    if (!(|cur_r[15:0])) begin
                        cur_r <= {16'd0, cur_r[127:16]}; idx_r <= idx_r + 7'd16;
                    end
                    st <= 4'd4;
                end
                4'd4: begin
                    if (!(|cur_r[7:0])) begin
                        cur_r <= {8'd0, cur_r[127:8]};   idx_r <= idx_r + 7'd8;
                    end
                    st <= 4'd5;
                end
                4'd5: begin
                    if (!(|cur_r[3:0])) begin
                        cur_r <= {4'd0, cur_r[127:4]};   idx_r <= idx_r + 7'd4;
                    end
                    st <= 4'd6;
                end
                4'd6: begin
                    if (!(|cur_r[1:0])) begin
                        cur_r <= {2'd0, cur_r[127:2]};   idx_r <= idx_r + 7'd2;
                    end
                    st <= 4'd7;
                end
                4'd7: begin
                    if (!cur_r[0]) begin
                        cur_r <= {1'b0, cur_r[127:1]};   idx_r <= idx_r + 7'd1;
                    end
                    st <= 4'd8;
                end

                // ---- 锁存：此时最低按下位已落在 cur_r[0] ----
                default: begin
                    root_note     <= idx_r;
                    interval_mask <= cur_r[15:0];
                    active        <= found_r;
                    st            <= 4'd0;
                end
            endcase
        end
    end

endmodule
