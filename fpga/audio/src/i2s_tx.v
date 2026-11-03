// ============================================================================
//  i2s_tx.v  —  PT8211-S 串行音频发送器（单时钟域版）
// ----------------------------------------------------------------------------
//  ⚠️ 本模块是 Sipeed 官方 **Pro 版**驱动
//     TangMega-138KPro-example / audio / audio_sinewave / src / audio_driver.v
//     的**逐拍等价重写**。官方那版把 BCK 当成真实时钟（always @(posedge BCK)），
//     会多出第二个时钟域；这里改成「一切寄存器都挂在 50MHz 的 clk 上，
//     用 bck_rise 脉冲代替 posedge BCK」，于是：
//       · 全设计单时钟域 → 时序约束简单，不会有跨域亚稳态
//       · iverilog 里可以完整仿真（BCK 是生成的，不是外部时钟）
//       · 对外行为与官方件一致（对应关系见下面 AUDIO_DRIVE_EQUIV）
//
//  AUDIO_DRIVE_EQUIV（官方件 → 本模块）
//     always @(posedge clk_1p536m ...)   →   always @(posedge clk) if (bck_rise)
//     b_cnt        <= b_cnt + 1        →   同
//     req_r        <= (b_cnt==0)||(b_cnt==16)
//     req_r1       <= req_r
//     idata_r      <= req_r1 ? idata : idata_r<<1
//     HP_DIN_r     <= idata_r[15]
//     HP_WS_r      <= (b_cnt==3)?0:((b_cnt==19)?1:HP_WS_r)
//     assign HP_BCK = clk_1p536m        →   assign HP_BCK = bck
//  唯一新增的是把「选左声道还是右声道」显式化成 ch_r（官方是把 idata 的两路
//  数据源在外部按 req 时刻切换，等价但更难读）。
//
//  PT8211-S 时序（已由官方件实测过的对齐，别自己改）：
//     · HP_BCK 就是位时钟，一帧 32 个 BCK（左右声道各 16 bit）
//     · HP_WS 低 = 左声道，高 = 右声道
//     · HP_DIN 在 BCK **上升沿**更新（MSB 先出）
//     · DAC 在 BCK **下降沿**锁存 → 数据建立时间有半个位周期，很宽松
//     · 因此 L/R 两声道原始上都来自 idata；本项目 mono 合成，
//       sample_l 与 sample_r 通常接同一根 mix_out（要立体声就把它们分开送）
//
//  数据请求：req 每 16 个 BCK 拉高一次（一帧两次），语义与官方件一致，
//  将来接 FIFO 时用 `fifo_rd = req & ~fifo_empty` 即可（官方注释也这么说）。
//  帧同步用 frame_en（每 32 个 BCK 一个 clk 脉冲，b_cnt==31 时给出），
//  合成引擎用它作为 sample_en → 采样率恒等于 BCK/32。
//
//  ⭐⭐ 为什么要有 hold_l / hold_r 这两个快照寄存器 ⭐⭐
//  官方例程的数据源是**常数**（一个正弦表），所以它直接在加载点采 sample_l 就行。
//  我们不一样：sample_l 接的是**合成引擎的输出**，而引擎收到 frame_en 后要花
//  3N+8 拍才算完（N=32 时 104 拍）。时序上：
//        frame_en 在 b_cnt 31→0 的边沿
//        左声道加载点 b_cnt==2   ≈ frame_en + 65 clk     ← 引擎还没算完！
//        右声道加载点 b_cnt==18  ≈ frame_en + 586 clk    ← 引擎早算完了
//  直接采样的话左声道会拿到**上一帧**的样本、右声道拿本帧的 → 左右差一个采样。
//  （tb_i2s 抓不出来，因为它的 sample_l 在一帧之内是常数，左右本来就相同。）
//  解法：在**帧边界**（b_cnt==31）把 sample_l/sample_r 一起快照进 hold_l/hold_r，
//  整帧都从快照取数。这样两个加载点必然看到同一个样本，代价是统一的 1 帧
//  （20.8us）延迟 —— 引擎输出在 b_cnt==31 时早就稳定了。
// ============================================================================
`timescale 1ns / 1ps

module i2s_tx (
    input  wire        clk,        // 50MHz 主时钟（所有寄存器都挂这个域）
    input  wire        rst_n,      // 异步低有效复位
    input  wire        bck,        // 来自 clk_gen：1.536MHz
    input  wire        bck_rise,   // 来自 clk_gen：bck 0→1 的 clk 脉冲

    input  wire [15:0] sample_l,   // 左声道样本（mono 时与 sample_r 同源）
    input  wire [15:0] sample_r,   // 右声道样本

    output wire        HP_BCK,     // → FPGA 引脚 E22
    output reg         HP_WS,      // → FPGA 引脚 F24
    output reg         HP_DIN,     // → FPGA 引脚 G24

    output reg         req,        // 数据请求（每 16 个 BCK 一次）
    output reg         frame_en    // 48kHz 帧脉冲，作合成引擎的 sample_en
);

    assign HP_BCK = bck;

    reg [4:0]  b_cnt;      // 0..31 自由回绕，一帧 = 32 个 BCK
    reg        req_r1;     // req 延迟一拍
    reg [15:0] idata_r;    // 并串转换移位寄存器
    reg        ch_r;       // 0 = 正在送左声道，1 = 右声道
    reg [15:0] hold_l;     // 帧边界快照（见文件头 ⭐⭐ 说明）
    reg [15:0] hold_r;

    // 官方件里 idata 由外部按 req 时刻切到对应声道；这里显式化：
    // ch_r 在 b_cnt==0 时清 0、b_cnt==16 时置 1，恰好在 b_cnt==2 / ==18
    // 的加载时刻分别给出左 / 右数据。数据源是**帧边界快照**，不是原始输入。
    wire [15:0] idata = ch_r ? hold_r : hold_l;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_cnt   <= 5'd0;
            req     <= 1'b0;
            req_r1  <= 1'b0;
            idata_r <= 16'd0;
            ch_r    <= 1'b0;
            hold_l  <= 16'd0;
            hold_r  <= 16'd0;
            HP_WS   <= 1'b0;
            HP_DIN  <= 1'b0;
            frame_en<= 1'b0;
        end else begin
            // ⚠️ frame_en 必须先无条件拉低，否则它会在 bck_rise 之间**保持一整
            //   个 BCK 周期**（≈32 个 clk），合成引擎一帧会被推进 ~32 次 ——
            //   采样率直接变成 1.5MHz。这个坑由 tb_i2s 第一次运行抓出来。
            frame_en <= 1'b0;

            if (bck_rise) begin
                // ---- 与官方 audio_drive.v 逐拍等价的数据通路 ----
                b_cnt   <= b_cnt + 5'd1;
                req     <= (b_cnt == 5'd0) || (b_cnt == 5'd16);
                req_r1  <= req;
                idata_r <= req_r1 ? idata : (idata_r << 1);
                HP_DIN  <= idata_r[15];
                HP_WS   <= (b_cnt == 5'd3) ? 1'b0 : ((b_cnt == 5'd19) ? 1'b1 : HP_WS);

                // ---- 声道选择（新增的显式化，见文件头说明）----
                if (b_cnt == 5'd0)  ch_r <= 1'b0;
                if (b_cnt == 5'd16) ch_r <= 1'b1;

                // ---- 帧同步 + 左右声道快照 ----
                //      frame_en 放在 b_cnt==31（帧的最末尾），它同时是：
                //        · 合成引擎的 sample_en（→ 采样率恒等于 BCK/32 = 48.000kHz）
                //        · 左右声道的共同快照时刻（→ 两声部必然拿到同一个样本）
                if (b_cnt == 5'd31) begin
                    frame_en <= 1'b1;
                    hold_l   <= sample_l;
                    hold_r   <= sample_r;
                end
            end
        end
    end

endmodule
