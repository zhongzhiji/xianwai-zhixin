`timescale 1ns/1ps
// 只用来调 sd_card_ctrl 的初始化流程，判分不是目的
module tb_sd_dbg;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk <= ~clk;

    reg        rd_req = 1'b0;
    reg [31:0] rd_lba = 0;
    wire       rd_busy, rd_done, rd_err;
    wire [7:0] buf_data;
    wire       card_ready, card_hc;
    wire [3:0] err_code;
    wire       sclk, mosi, miso, csn;
    reg  [8:0] buf_addr = 0;

    sd_card_ctrl #(.SPI_DIV_INIT(4), .SPI_DIV_FAST(4)) u_sd (
        .clk(clk), .rst_n(rst_n),
        .rd_req(rd_req), .rd_lba(rd_lba),
        .rd_busy(rd_busy), .rd_done(rd_done), .rd_err(rd_err),
        .buf_addr(buf_addr), .buf_data(buf_data),
        .card_ready(card_ready), .card_hc(card_hc), .err_code(err_code),
        .sd_sclk(sclk), .sd_mosi(mosi), .sd_miso(miso), .sd_csn(csn));

    wire miso_drv;
    sd_card_model #(.NBLK(64)) u_card (.sclk(sclk), .mosi(mosi), .miso(miso_drv), .csn(csn));
    assign miso = csn ? 1'bz : miso_drv;

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (400000) @(posedge clk);
        $display("TIMEOUT: card_ready=%b err=%0d hc=%b", card_ready, err_code, card_hc);
        $finish;
    end

    always @(posedge clk) begin
        if (card_ready) begin
            $display("[%0t] CARD READY  hc=%b", $time, card_hc);
            $finish;
        end
        if (err_code != 0) begin
            $display("[%0t] ERR code=%0d", $time, err_code);
            $finish;
        end
    end

    // 打印状态迁移
    reg [4:0] prev_state;
    initial prev_state = 0;
    always @(posedge clk) begin
        if (u_sd.state !== prev_state) begin
            $display("[%0t] state %0d -> %0d", $time, prev_state, u_sd.state);
            prev_state <= u_sd.state;
        end
    end

    // 打印每个 SPI 字节
    always @(posedge clk) begin
        if (u_sd.spi_done)
            $display("        [%0t] MOSI=%02h MISO=%02h", $time, u_sd.spi_tx, u_sd.spi_rx);
    end

endmodule
