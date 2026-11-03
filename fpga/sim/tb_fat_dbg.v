`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_fat_dbg.v —— 用层次化引用打印 sd_score_loader 内部解析出的 FAT32 字段
// ---------------------------------------------------------------------------
module tb_fat_dbg;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;

    always #10 clk <= ~clk;

    wire sd_sclk, sd_mosi, sd_miso, sd_csn;
    wire        card_ready;
    wire [3:0]  card_err;
    wire        loading, file_found, load_done;
    wire [2:0]  fat_err;
    wire        load_we, load_commit;
    wire [7:0]  load_addr;
    wire [6:0]  load_note;
    wire [7:0]  load_count;
    wire [3:0]  load_length;
    wire [7:0]  load_bpm;
    wire        frame_done, commit_accept;
    wire [2:0]  err_code;
    wire [7:0]  err_count, recv_count;

    sd_score_loader #(.SPI_DIV_INIT(4), .SPI_DIV_FAST(4)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_csn(sd_csn),
        .card_ready(card_ready), .card_err(card_err),
        .loading(loading), .file_found(file_found), .load_done(load_done),
        .fat_err(fat_err),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .frame_done(frame_done), .commit_accept(commit_accept),
        .err_code(err_code), .err_count(err_count), .recv_count(recv_count));

    wire miso_drv;
    sd_card_model #(.NBLK(64)) u_card (
        .sclk(sd_sclk), .mosi(sd_mosi), .miso(miso_drv), .csn(sd_csn));
    assign sd_miso = (sd_csn) ? 1'bz : miso_drv;

    integer k, base;
    reg [7:0] song [0:15];

    initial begin
        #1;
        song[ 0]=8'h55; song[ 1]=8'h4C; song[ 2]=8'h02; song[ 3]=8'h78;
        song[ 4]=8'h55; song[ 5]=8'h57; song[ 6]=8'h00; song[ 7]=8'h3C;
        song[ 8]=8'h02; song[ 9]=8'h55; song[10]=8'h57; song[11]=8'h01;
        song[12]=8'h3E; song[13]=8'h02; song[14]=8'h55; song[15]=8'h43;

        base = 0;
        u_card.write_mem(base+'h1BE, 8'h80);
        u_card.write_mem(base+'h1C2, 8'h0C);
        u_card.write_mem(base+'h1C6, 8'h01);
        u_card.write_mem(base+'h1C7, 8'h00);
        u_card.write_mem(base+'h1C8, 8'h00);
        u_card.write_mem(base+'h1C9, 8'h00);
        u_card.write_mem(base+'h1CA, 8'h00);
        u_card.write_mem(base+'h1CB, 8'h10);
        u_card.write_mem(base+'h1CC, 8'h00);
        u_card.write_mem(base+'h1CD, 8'h00);
        u_card.write_mem(base+'h1FE, 8'h55);
        u_card.write_mem(base+'h1FF, 8'hAA);

        base = 512;
        u_card.write_mem(base+'h00B, 8'h00);
        u_card.write_mem(base+'h00C, 8'h02);
        u_card.write_mem(base+'h00D, 8'h01);
        u_card.write_mem(base+'h00E, 8'h04);
        u_card.write_mem(base+'h00F, 8'h00);
        u_card.write_mem(base+'h010, 8'h02);
        u_card.write_mem(base+'h024, 8'h04);
        u_card.write_mem(base+'h025, 8'h00);
        u_card.write_mem(base+'h026, 8'h00);
        u_card.write_mem(base+'h027, 8'h00);
        u_card.write_mem(base+'h02C, 8'h02);
        u_card.write_mem(base+'h02D, 8'h00);
        u_card.write_mem(base+'h02E, 8'h00);
        u_card.write_mem(base+'h02F, 8'h00);
        u_card.write_mem(base+'h1FE, 8'h55);
        u_card.write_mem(base+'h1FF, 8'hAA);

        base = 5*512;
        u_card.write_mem(base+0, 8'hF8);
        u_card.write_mem(base+1, 8'hFF);
        u_card.write_mem(base+2, 8'hFF);
        u_card.write_mem(base+3, 8'h0F);
        u_card.write_mem(base+4, 8'hFF);
        u_card.write_mem(base+5, 8'hFF);
        u_card.write_mem(base+6, 8'hFF);
        u_card.write_mem(base+7, 8'hFF);
        u_card.write_mem(base+8, 8'h0F);
        u_card.write_mem(base+9, 8'hFF);
        u_card.write_mem(base+10, 8'hFF);
        u_card.write_mem(base+11, 8'hFF);
        u_card.write_mem(base+12, 8'h0F);

        // ---- LBA 13：根目录 ----
        base = 13*512;
        // 条目 0：SONG    BIN
        u_card.write_mem(base+ 0, "S");
        u_card.write_mem(base+ 1, "O");
        u_card.write_mem(base+ 2, "N");
        u_card.write_mem(base+ 3, "G");
        u_card.write_mem(base+ 4, " ");
        u_card.write_mem(base+ 5, " ");
        u_card.write_mem(base+ 6, " ");
        u_card.write_mem(base+ 7, "B");
        u_card.write_mem(base+ 8, "I");
        u_card.write_mem(base+ 9, "N");
        u_card.write_mem(base+10, 8'h20);
        u_card.write_mem(base+11, 8'h20);   // ATTR = 归档
        u_card.write_mem(base+20, 8'h00);   // ClusHigh
        u_card.write_mem(base+21, 8'h00);
        u_card.write_mem(base+26, 8'h03);   // ClusLow = 3
        u_card.write_mem(base+27, 8'h00);
        u_card.write_mem(base+28, 8'h10);   // Size = 16
        u_card.write_mem(base+29, 8'h00);
        u_card.write_mem(base+30, 8'h00);
        u_card.write_mem(base+31, 8'h00);

        // ---- LBA 14：文件数据（簇 3）----
        base = 14*512;
        for (k = 0; k < 16; k = k + 1) u_card.write_mem(base+k, song[k]);
    end

    // ---------------- 层次化探针 ----------------
    // sd_score_loader 内部实例化名需与实际一致
    wire [31:0] p_part   = uut.part_lba;
    wire [31:0] p_fatsz  = uut.fat_size;
    wire [31:0] p_root   = uut.root_clus;
    wire [31:0] p_dstart = uut.data_start;
    wire [15:0] p_resv   = uut.reserved;
    wire [7:0]  p_spc    = uut.sec_per_clus;
    wire [7:0]  p_nfats  = uut.num_fats;
    wire [31:0] p_rdlba  = uut.rd_lba;

    initial begin
        $dumpfile("sim/out/fat_dbg.vcd");
        $dumpvars(0, tb_fat_dbg);
    end

    reg [3:0] st_prev;
    always @(posedge clk) begin
        if (uut.state !== st_prev) begin
            st_prev <= uut.state;
            $display("[%0t] st=%0d part=%0d resv=%0d nfats=%0d fatsz=%0d spc=%0d root=%0d dstart=%0d rd=%0d ferr=%0d hit=%0b end=%0b",
                     $time, uut.state, p_part, p_resv, p_nfats, p_fatsz,
                     p_spc, p_root, p_dstart, p_rdlba, uut.fat_err_r,
                     uut.hit, uut.dir_end);
        end
    end

    initial begin
        #200  rst_n = 1'b1;
        wait (card_ready);
        $display("[%0t] CARD READY", $time);
        #200  start = 1'b1;
        #200  start = 1'b0;
        #4000000;
        $display("[%0t] done=%0b found=%0b fat_err=%0d", $time, load_done, file_found, fat_err);
        $finish;
    end

endmodule
