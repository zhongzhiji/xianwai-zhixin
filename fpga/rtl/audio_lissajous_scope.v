// ============================================================================
//  audio_lissajous_scope.v —— 双通道李萨如图的「音频侧」采样前端（sys_clk 域）
// ----------------------------------------------------------------------------
//  职责单一：把两路 48 kHz 的 PCM 流同拍抽稀成一对光栅坐标，打包成窄载荷
//  交给 bus_snapshot_cdc 跨到 pixel_clk 域。光栅位图本身放在渲染器（pixel 域），
//  这里绝不过整块位图——跨时钟只过 16 bit。
//
//  为什么必须是两路**真实**音频（不是单通道延迟伪造）：
//    李萨如图的物理含义就是"两个信号的相位关系"。把同一路信号延迟几拍再当
//    Y 轴，画出来一定是个圆/椭圆，看起来漂亮但没有任何信息量，属于造假。
//    这里 X = 主合成（32 复音 + 效果器之后）pcm_fx，Y = 伴奏层 acc_pcm，
//    两路都是各自相位累加器出来的独立信号；伴奏静音时 Y 恒在中线，
//    屏幕上就是一条水平线，并会显示 Y=ACC(OFF) 提示，不掩饰。
//
//  抽稀（DECIMATE=4 → 12 kHz）：
//    48 kHz 直接打点，位图会在几毫秒内被填满成一团实心块，看不出图形；
//    抽到 12 kHz 后，一个 440 Hz 的周期有 27 个点，图形轮廓干净，
//    同时配合渲染器的"按列轮转擦除"，稳态可见点数约 384 个，
//    刷新周期 ~32 ms，观感接近示波器余辉。
//
//  坐标映射（全程移位加减，无乘法器）：
//    u8 = pcm[15:8] ^ 8'h80          → 0..255（-32768→0，0→128，32767→255）
//    X  = (u8*96) >> 8                    → 0..95
//    Y  = (u8*96) >> 8 = (u8<<6 + u8<<5) >> 8 → 0..95
//
//  速率安全边界：
//    源侧点率 = 48000/4 = 12 kHz（周期 83 µs），mailbox 一次握手 ≈ 100 ns，
//    余量 800 倍以上，不会丢点。
// ============================================================================
`timescale 1ns / 1ps

module audio_lissajous_scope #(
    parameter integer DECIMATE = 4       // 48kHz/4 = 12 kHz 打点率
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_en,        // 48 kHz 采样节拍（frame_en）
    input  wire        enable,           // 静音时不打点
    input  wire signed [15:0] pcm_x,     // X 轴：主合成（效果器后）
    input  wire signed [15:0] pcm_y,     // Y 轴：伴奏层
    output reg  [6:0]  liss_x,           // 0..95
    output reg  [6:0]  liss_y,           // 0..95
    output reg         liss_quiet,       // 1 = Y 轴长时间无信号（伴奏关/静音）
    output reg         liss_toggle       // 每点翻转，强制 mailbox 传输
);
    // 参数先落到 localparam 再比较：直接对 parameter integer 做位选/比较
    // 在部分综合器上会被判成非常量。
    localparam [7:0] DEC_MAX = DECIMATE - 1;

    reg [7:0] dec_cnt;
    reg [7:0] quiet_cnt;

    // 16 bit 有符号 → 0..255 的无符号刻度（0 = 负满刻度，128 = 零，255 = 正满刻度）
    // Display-only per-axis gain. Peaks release slowly; each new sample is
    // included immediately in the gain decision so a louder onset cannot wrap.
    reg [7:0] peak_x,peak_y;
    reg [9:0] peak_release;
    wire signed [16:0] wide_x=pcm_x,wide_y=pcm_y;
    wire [16:0] abs_x=wide_x[16] ? -wide_x : wide_x;
    wire [16:0] abs_y=wide_y[16] ? -wide_y : wide_y;
    wire [7:0] mag_x=abs_x[15:8],mag_y=abs_y[15:8];
    wire [7:0] range_x=mag_x>peak_x ? mag_x : peak_x;
    wire [7:0] range_y=mag_y>peak_y ? mag_y : peak_y;
    function automatic [7:0] auto_coordinate;
        input signed [15:0] pcm;
        input [7:0] peak;
        reg [2:0] shift;
        reg signed [20:0] scaled;
        begin
            shift=peak<8 ? 4 : peak<16 ? 3 : peak<32 ? 2 : peak<64 ? 1 : 0;
            scaled=$signed({{5{pcm[15]}},pcm}) <<< shift;
            if(scaled>32767) auto_coordinate=255;
            else if(scaled < -32768) auto_coordinate=0;
            else auto_coordinate=scaled[15:8]^8'h80;
        end
    endfunction
    wire [7:0] ux=auto_coordinate(pcm_x,range_x);
    wire [7:0] uy=auto_coordinate(pcm_y,range_y);
    wire [7:0] uy_raw=pcm_y[15:8]^8'h80;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin peak_x<=0;peak_y<=0;peak_release<=0;end
        else if(!enable)begin peak_x<=0;peak_y<=0;peak_release<=0;end
        else if(sample_en)begin
            peak_release<=peak_release+1'b1;
            if(mag_x>peak_x)peak_x<=mag_x;
            else if(&peak_release && peak_x!=0)peak_x<=peak_x-1'b1;
            if(mag_y>peak_y)peak_y<=mag_y;
            else if(&peak_release && peak_y!=0)peak_y<=peak_y-1'b1;
        end
    end
    // Y 轴偏离中心的幅度（0..128），只用于"伴奏是否在响"的判断
    wire [7:0] dev = (uy_raw > 8'd128) ? (uy_raw - 8'd128) : (8'd128 - uy_raw);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dec_cnt     <= 8'd0;
            quiet_cnt   <= 8'd0;
            liss_x      <= 7'd0;
            liss_y      <= 7'd0;
            liss_quiet  <= 1'b0;
            liss_toggle <= 1'b0;
        end else if (!enable) begin
            // 静音：停止打点；渲染器独立像素时钟擦除旧轨迹
            dec_cnt    <= 8'd0;
            quiet_cnt  <= 8'd0;
            liss_quiet <= 1'b1;
        end else if (sample_en) begin
            // Y 轴静音检测：连续 255 个点幅度都不超过 ±256 才判定为"没信号"，
            // 避免伴奏的包络谷底被误判成关闭（255 点 ≈ 21 ms）。
            if (dev > 8'd1) begin
                if (quiet_cnt != 8'd0) quiet_cnt <= quiet_cnt - 8'd1;
                liss_quiet <= 1'b0;
            end else if (quiet_cnt == 8'd255) begin
                liss_quiet <= 1'b1;
            end else begin
                quiet_cnt <= quiet_cnt + 8'd1;
            end

            if (dec_cnt == 8'd0) begin
                liss_x      <= (({8'd0, ux} << 6) + ({8'd0, ux} << 5)) >> 8;
                liss_y      <= (({8'd0, uy} << 6) + ({8'd0, uy} << 5)) >> 8;
                liss_toggle <= ~liss_toggle;
            end
            dec_cnt <= (dec_cnt >= DEC_MAX) ? 8'd0 : dec_cnt + 8'd1;
        end
    end
endmodule
