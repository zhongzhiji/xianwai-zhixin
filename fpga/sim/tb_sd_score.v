`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_sd_score.v —— SD 卡曲谱导入（SPI + FAT32 + score_loader_core）自检测
//
//  被测：rtl/spi_master.v → rtl/sd_card_ctrl.v → rtl/sd_score_loader.v
//        → rtl/score_loader_core.v
//  激励：sim/sd_card_model.v（SD 卡 SPI 行为模型），卡内映像由本 TB 拼装：
//        MBR(LBA0) → BPB(LBA1) → FAT1(LBA5) → 根目录(LBA13) → 文件(LBA14)
//
//  曲谱文件内容（与蓝牙通道同一套协议）：
//    55 4C 02 78        装载头 count=2 bpm=120
//    55 57 00 3C 02     事件0 note=60 len=2
//    55 57 01 3E 02     事件1 note=62 len=2
//    55 43              提交
// ---------------------------------------------------------------------------
module tb_sd_score;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;

    always #10 clk <= ~clk;                       // 50 MHz

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

    // 仿真加速：把 SPI 分频开到最小，真实板级参数由 top 传入 280/8
    sd_score_loader #(
        .SPI_DIV_INIT(4),
        .SPI_DIV_FAST(4)
    ) uut (
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

    // ---------------- SD 卡模型 ----------------
    wire miso_drv;
    sd_card_model #(.NBLK(64)) u_card (
        .sclk(sd_sclk), .mosi(sd_mosi), .miso(miso_drv), .csn(sd_csn));
    assign sd_miso = (sd_csn) ? 1'bz : miso_drv;   // 真实卡：CS 无效时 MISO 高阻

    // =====================================================================
    //  拼装 FAT32 映像
    // =====================================================================
    integer k;
    integer base;
    reg [7:0] song [0:15];

    initial begin
        // 必须等模型自己的 mem 清零 initial 跑完再写，否则会被覆盖（两条
        // initial 都在 t=0，执行顺序未定义）。
        #1;
        // ---- 曲谱字节流 ----
        song[ 0] = 8'h55; song[ 1] = 8'h4C; song[ 2] = 8'h02; song[ 3] = 8'h78;
        song[ 4] = 8'h55; song[ 5] = 8'h57; song[ 6] = 8'h00; song[ 7] = 8'h3C;
        song[ 8] = 8'h02; song[ 9] = 8'h55; song[10] = 8'h57; song[11] = 8'h01;
        song[12] = 8'h3E; song[13] = 8'h02; song[14] = 8'h55; song[15] = 8'h43;

        // ---- LBA 0：MBR，分区 1 起始 LBA = 1 ----
        base = 0;
        u_card.write_mem(base + 'h1BE, 8'h80);
        u_card.write_mem(base + 'h1C2, 8'h0C);
        u_card.write_mem(base + 'h1C6, 8'h01);
        u_card.write_mem(base + 'h1C7, 8'h00);
        u_card.write_mem(base + 'h1C8, 8'h00);
        u_card.write_mem(base + 'h1C9, 8'h00);
        u_card.write_mem(base + 'h1CA, 8'h00);
        u_card.write_mem(base + 'h1CB, 8'h10);
        u_card.write_mem(base + 'h1CC, 8'h00);
        u_card.write_mem(base + 'h1CD, 8'h00);
        u_card.write_mem(base + 'h1FE, 8'h55);
        u_card.write_mem(base + 'h1FF, 8'hAA);

        // ---- LBA 1：BPB（FAT32）----
        base = 512;
        u_card.write_mem(base + 'h00B, 8'h00);   // BytesPerSec = 512
        u_card.write_mem(base + 'h00C, 8'h02);
        u_card.write_mem(base + 'h00D, 8'h01);   // SecPerClus = 1
        u_card.write_mem(base + 'h00E, 8'h04);   // ReservedSec = 4
        u_card.write_mem(base + 'h00F, 8'h00);
        u_card.write_mem(base + 'h010, 8'h02);   // NumFATs = 2
        u_card.write_mem(base + 'h024, 8'h04);   // FATSz32 = 4
        u_card.write_mem(base + 'h025, 8'h00);
        u_card.write_mem(base + 'h026, 8'h00);
        u_card.write_mem(base + 'h027, 8'h00);
        u_card.write_mem(base + 'h02C, 8'h02);   // RootClus = 2
        u_card.write_mem(base + 'h02D, 8'h00);
        u_card.write_mem(base + 'h02E, 8'h00);
        u_card.write_mem(base + 'h02F, 8'h00);
        u_card.write_mem(base + 'h1FE, 8'h55);
        u_card.write_mem(base + 'h1FF, 8'hAA);
        // data_start = 1 + 4 + 2*4 = 13

        // ---- LBA 5：FAT1 ----
        base = 5 * 512;
        u_card.write_mem(base +  0, 8'hF8);      // FAT[0]
        u_card.write_mem(base +  1, 8'hFF);
        u_card.write_mem(base +  2, 8'hFF);
        u_card.write_mem(base +  3, 8'h0F);
        u_card.write_mem(base +  4, 8'hFF);      // FAT[1]
        u_card.write_mem(base +  5, 8'hFF);
        u_card.write_mem(base +  6, 8'hFF);
        u_card.write_mem(base +  7, 8'h0F);
        u_card.write_mem(base +  8, 8'hFF);      // FAT[2] 根目录，链尾
        u_card.write_mem(base +  9, 8'hFF);
        u_card.write_mem(base + 10, 8'hFF);
        u_card.write_mem(base + 11, 8'h0F);
        u_card.write_mem(base + 12, 8'hFF);      // FAT[3] 文件，链尾
        u_card.write_mem(base + 13, 8'hFF);
        u_card.write_mem(base + 14, 8'hFF);
        u_card.write_mem(base + 15, 8'h0F);

        // ---- LBA 13：根目录，第 0 项 = SONG.BIN ----
        base = 13 * 512;
        u_card.write_mem(base +  0, 8'h53);      // S
        u_card.write_mem(base +  1, 8'h4F);      // O
        u_card.write_mem(base +  2, 8'h4E);      // N
        u_card.write_mem(base +  3, 8'h47);      // G
        u_card.write_mem(base +  4, 8'h20);
        u_card.write_mem(base +  5, 8'h20);
        u_card.write_mem(base +  6, 8'h20);
        u_card.write_mem(base +  7, 8'h20);
        u_card.write_mem(base +  8, 8'h42);      // B
        u_card.write_mem(base +  9, 8'h49);      // I
        u_card.write_mem(base + 10, 8'h4E);      // N
        u_card.write_mem(base + 11, 8'h20);      // attr = ARCHIVE
        u_card.write_mem(base + 20, 8'h00);      // 首簇高 16 位
        u_card.write_mem(base + 21, 8'h00);
        u_card.write_mem(base + 26, 8'h03);      // 首簇低 16 位 = 3
        u_card.write_mem(base + 27, 8'h00);
        u_card.write_mem(base + 28, 8'h10);      // 文件长度 = 16
        u_card.write_mem(base + 29, 8'h00);
        u_card.write_mem(base + 30, 8'h00);
        u_card.write_mem(base + 31, 8'h00);
        u_card.write_mem(base + 32, 8'h00);      // 第 1 项首字节 0 → 目录结束

        // ---- LBA 14：文件内容 ----
        base = 14 * 512;
        for (k = 0; k < 16; k = k + 1)
            u_card.write_mem(base + k, song[k]);
    end

    // =====================================================================
    //  监视
    // =====================================================================
    integer we_cnt;
    integer we_addr [0:7];
    integer we_note [0:7];
    integer we_len  [0:7];
    integer commit_cnt;
    integer cap_count, cap_bpm;
    integer cycles;

    initial begin
        we_cnt = 0; commit_cnt = 0; cap_count = 0; cap_bpm = 0;
        for (k = 0; k < 8; k = k + 1) begin
            we_addr[k] = -1; we_note[k] = -1; we_len[k] = -1;
        end
    end

    always @(posedge clk) begin
        if (load_we && we_cnt < 8) begin
            we_addr[we_cnt] = load_addr;
            we_note[we_cnt] = load_note;
            we_len[we_cnt]  = load_length;
            we_cnt          = we_cnt + 1;
        end
        if (load_commit) begin
            commit_cnt = commit_cnt + 1;
            cap_count  = load_count;
            cap_bpm    = load_bpm;
        end
    end

    // =====================================================================
    //  主流程 + 判分
    // =====================================================================
    integer pass_n, fail_n;

    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) begin
                pass_n = pass_n + 1;
                $display("[PASS] %0s", name);
            end else begin
                fail_n = fail_n + 1;
                $display("[FAIL] %0s", name);
            end
        end
    endtask

    task wait_cyc;
        input integer n;
        begin
            cycles = 0;
            while (cycles < n) begin @(posedge clk); cycles = cycles + 1; end
        end
    endtask

    integer timeout;

    reg [3:0] prev_st;
    always @(posedge clk) begin
        if (uut.state !== prev_st) begin
            $display("[%0t] st=%0d mode=%0d lba=%0d hit=%b end=%b fat=%0d",
                     $time, uut.state, uut.mode, uut.rd_lba, uut.hit, uut.dir_end, fat_err);
            prev_st <= uut.state;
        end
    end

    initial begin
        pass_n = 0; fail_n = 0;
        rst_n = 1'b0;
        wait_cyc(20);
        rst_n = 1'b1;

        // ---- 1. 等卡初始化完成 ----
        timeout = 0;
        while (!card_ready && timeout < 200000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        chk("SD 卡初始化完成 card_ready=1", card_ready === 1'b1);
        chk("SD 卡初始化无错误 card_err=0", card_err === 4'd0);

        // ---- 2. 触发装载，等 load_done ----
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;

        timeout = 0;
        while (!load_done && !(|fat_err) && timeout < 400000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        chk("装载完成 load_done 脉冲", load_done === 1'b1);
        chk("文件系统无错 fat_err=0", fat_err === 3'd0);
        chk("找到文件 file_found=1", file_found === 1'b1);
        chk("装载结束后 loading 回落", loading === 1'b0);

        wait_cyc(10);

        // ---- 3. 校验装载内容 ----
        chk("收到 2 个音符写事件", we_cnt == 2);
        chk("事件0 addr=0",    we_addr[0] == 0);
        chk("事件0 note=60",   we_note[0] == 60);
        chk("事件0 len=2",     we_len[0]  == 2);
        chk("事件1 addr=1",    we_addr[1] == 1);
        chk("事件1 note=62",   we_note[1] == 62);
        chk("事件1 len=2",     we_len[1]  == 2);
        chk("提交恰好 1 次",   commit_cnt == 1);
        chk("装载头 count=2",  cap_count == 2);
        chk("装载头 bpm=120",  cap_bpm == 120);
        chk("协议无错 err_code=0", err_code === 3'd0);
        chk("协议错计数 err_count=0", err_count === 8'd0);
        chk("收到 16 字节 recv_count=16", recv_count === 8'd16);

        $display("");
        $display("=============================================");
        $display("  SD 卡曲谱导入仿真：%0d PASS / %0d FAIL", pass_n, fail_n);
        $display("=============================================");
        if (fail_n == 0) $display("  >>> 全部通过");
        else             $display("  >>> 存在失败项");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("[TIMEOUT] 仿真超时，强制结束");
        $finish;
    end

    initial begin
        $dumpfile("sim/out/sd_score.vcd");
        $dumpvars(0, tb_sd_score);
    end

endmodule
