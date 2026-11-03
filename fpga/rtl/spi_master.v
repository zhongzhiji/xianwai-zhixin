// ---------------------------------------------------------------------------
// spi_master.v —— 字节级 SPI 主机（Mode 0：CPOL=0, CPHA=0）
//
//  时序（Mode 0）：
//    sclk 空闲为低；主机在下降沿更新 MOSI，从机在上升沿锁存 MOSI 并在
//    上升沿之后给出 MISO，主机在 sclk 为高的中点采样 MISO。
//
//  分频：SPI_DIV 决定半周期长度，sclk = clk / SPI_DIV。
//    初始化阶段 SD 卡要求 100k..400kHz → 50MHz / 400 = 125 kHz
//    识别完成后可提速          → 50MHz / 8   = 6.25 MHz
//  SPI_DIV 必须是偶数。fast 端口只在空闲时生效，绝不产生毛刺时钟。
//
//  发 0xFF 即"读一个字节"：SD 卡 SPI 模式靠主机发空字节换回数据。
// ---------------------------------------------------------------------------
module spi_master #(
    parameter integer SPI_DIV_INIT = 400,     // 初始化用，125 kHz @50MHz
    parameter integer SPI_DIV_FAST = 8        // 数据用，6.25 MHz @50MHz
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] tx_byte,
    input  wire       start,                  // 单拍脉冲，busy=0 时才受理
    input  wire       fast,                   // 1=快速 0=慢速（仅空闲时生效）
    input  wire       csn_override,           // 1=强制片选无效（发空时钟/复位用）
    input  wire       csn_hold,               // 1=事务期间保持片选有效

    output reg  [7:0] rx_byte,
    output reg        busy,
    output reg        done,                   // 单拍脉冲

    output reg        sclk,
    output reg        mosi,
    input  wire       miso,
    output reg        csn
);

    reg [9:0] half, cnt;
    reg [2:0] bit_idx;
    reg       level;        // 当前 sclk 电平
    reg [7:0] shifter;

    always @(*) begin
        half = (fast ? SPI_DIV_FAST : SPI_DIV_INIT) >> 1;
        if (half < 10'd1) half = 10'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk <= 1'b0; mosi <= 1'b1; csn <= 1'b1;
            busy <= 1'b0; done <= 1'b0; rx_byte <= 8'd0;
            cnt <= 10'd0; bit_idx <= 3'd0; level <= 1'b0; shifter <= 8'hFF;
        end else begin
            done <= 1'b0;
            // SD 卡要求"命令 + 响应 + 数据"整段事务里 CS 一直有效。
            // 只按 busy 拉低会导致每字节之间 CS 弹高一次，卡会把命令当成
            // 被中止（实测 MISO 永远停在 0xFF）。csn_hold 用来把 CS 钉住。
            csn  <= csn_override ? 1'b1 : ((busy || csn_hold) ? 1'b0 : 1'b1);

            if (!busy) begin
                sclk <= 1'b0;
                level <= 1'b0;
                cnt <= 10'd0;
                if (start) begin
                    shifter <= tx_byte;
                    bit_idx <= 3'd7;
                    mosi    <= tx_byte[7];      // Mode0：首位在第一个上升沿前就位
                    busy    <= 1'b1;
                end
            end else begin
                if (cnt != half - 1) begin
                    cnt <= cnt + 1'b1;
                end else begin
                    cnt   <= 10'd0;
                    level <= ~level;
                    sclk  <= ~level;            // level 翻转后 sclk 取反 → 新电平
                    if (!level) begin
                        // 0 → 1：上升沿，主机采样 MISO
                        rx_byte <= {rx_byte[6:0], miso};
                    end else begin
                        // 1 → 0：下降沿，主机给出下一位
                        if (bit_idx == 3'd0) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            sclk <= 1'b0;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            mosi    <= shifter[bit_idx - 1'b1];
                        end
                    end
                end
            end
        end
    end

endmodule
