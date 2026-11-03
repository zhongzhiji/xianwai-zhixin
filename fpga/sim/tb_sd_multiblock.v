`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_sd_multiblock.v —— SD 卡**跨扇区 / 跨簇**装载 255 事件长曲谱
//
//  为什么要单独测：
//    曲谱容量从 64 扩到 255 后，一首满曲的协议字节流是
//      4（装载头）+ 255*5（写事件）+ 2（提交） = 1281 字节
//    而 SD 卡一个扇区只有 512 字节 —— 旧版 64 事件（326 字节）**只占 1 个
//    扇区**，单块通路测试（tb_sd_score）根本覆盖不到"读第二块"。
//    本 TB 故意把 SecPerClus 设成 1，于是 1281 字节要跨 3 个扇区 **且**
//    跨 3 个簇（3→4→5→EOF），把 S_ADV / S_FAT_RD 两条分支一起压一遍。
//
//  卡映像（与 tb_sd_score 同构，data_start = 1 + 4 + 2*4 = 13）：
//    LBA0  MBR     LBA1  BPB      LBA5  FAT1
//    LBA13 根目录  LBA14/15/16 文件内容（簇 3/4/5）
//
//  运行：
//    iverilog -g2012 -o sim/out/sdmb.vvp -s tb_sd_multiblock -I rtl -y rtl \
//        -y sim sim/tb_sd_multiblock.v
//    vvp sim/out/sdmb.vvp
// ---------------------------------------------------------------------------
module tb_sd_multiblock;

    localparam integer N_EVENTS = 255;
    localparam integer FILE_LEN = 4 + N_EVENTS*5 + 2;   // 1281

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

    wire miso_drv;
    sd_card_model #(.NBLK(64)) u_card (
        .sclk(sd_sclk), .mosi(sd_mosi), .miso(miso_drv), .csn(sd_csn));
    assign sd_miso = (sd_csn) ? 1'bz : miso_drv;

    // =====================================================================
    //  拼装 FAT32 映像
    // =====================================================================
    integer k, base, i;
    reg [7:0] song [0:FILE_LEN-1];

    // 每簇扇区数。真实 FAT32 卡由 Windows 格式化时通常是 8（簇 4KB），
    // 而簇内扇区连续走的是 S_ADV 的 sec_in_clus 分支；spc=1 才会逼出
    // 沿 FAT 簇链跳簇的 S_FAT_RD 分支。两条分支都要覆盖，所以用 plusarg：
    //   vvp sim/out/tb_sd_multiblock.vvp +spc=8
    integer spc;
    integer nsec, nclus, c;
    initial begin
        spc = 1;
        $value$plusargs("spc=%d", spc);
        nsec  = (FILE_LEN + 511) / 512;      // 需要的扇区数
        nclus = (nsec + spc - 1) / spc;      // 需要的簇数（簇号 3 起连续）
        $display("[CFG ] SecPerClus=%0d  文件=%0d 字节  需 %0d 扇区 / %0d 簇",
                 spc, FILE_LEN, nsec, nclus);
    end

    initial begin
        #1;                                   // 避开模型 t=0 的 mem 清零
        // ---- 曲谱字节流：255 事件，note = 60 + (i%24)，len = 1 ----
        song[0] = 8'h55; song[1] = 8'h4C;
        song[2] = N_EVENTS[7:0]; song[3] = 8'd120;      // count=255 bpm=120
        for (i = 0; i < N_EVENTS; i = i + 1) begin
            song[4 + i*5 + 0] = 8'h55;
            song[4 + i*5 + 1] = 8'h57;
            song[4 + i*5 + 2] = i[7:0];
            song[4 + i*5 + 3] = 60 + (i % 24);
            song[4 + i*5 + 4] = 8'd1;
        end
        song[FILE_LEN-2] = 8'h55; song[FILE_LEN-1] = 8'h43;

        // ---- LBA 0：MBR，分区起始 LBA = 1 ----
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
        u_card.write_mem(base + 'h00D, spc[7:0]); // SecPerClus（1=逼出跨簇，8=真实卡）
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

        // ---- LBA 5：FAT1，簇链 3→4→5→EOF ----
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
        // FAT[3..2+nclus]：连续簇链，最后一簇 EOF
        // 注意：nclus 在另一个 initial 里赋值，两条 initial 都在 t=0 起跑，
        // 这里先 #1 等它（与上面写 mem 的 #1 同一拍，顺序确定）
        for (c = 3; c < 3 + nclus; c = c + 1) begin
            if (c == 3 + nclus - 1) begin                  // 链尾
                u_card.write_mem(base + c*4 + 0, 8'hFF);
                u_card.write_mem(base + c*4 + 1, 8'hFF);
                u_card.write_mem(base + c*4 + 2, 8'hFF);
                u_card.write_mem(base + c*4 + 3, 8'h0F);
            end else begin                                 // 指向下一簇
                u_card.write_mem(base + c*4 + 0, (c + 1) & 8'hFF);
                u_card.write_mem(base + c*4 + 1, 8'h00);
                u_card.write_mem(base + c*4 + 2, 8'h00);
                u_card.write_mem(base + c*4 + 3, 8'h00);
            end
        end

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
        u_card.write_mem(base + 20, 8'h00);      // 首簇高 16
        u_card.write_mem(base + 21, 8'h00);
        u_card.write_mem(base + 26, 8'h03);      // 首簇低 16 = 3
        u_card.write_mem(base + 27, 8'h00);
        // 文件长度 = 1281 = 0x501（小端）
        u_card.write_mem(base + 28, 8'h01);
        u_card.write_mem(base + 29, 8'h05);
        u_card.write_mem(base + 30, 8'h00);
        u_card.write_mem(base + 31, 8'h00);
        u_card.write_mem(base + 32, 8'h00);      // 第 1 项首字节 0 → 目录结束

        // ---- 文件内容：簇 3 起，LBA = data_start + (3-2)*spc ----
        // 簇链是连续的，所以整段文件在 LBA 空间上也连续，直接顺写即可
        for (k = 0; k < FILE_LEN; k = k + 1)
            u_card.write_mem((13 + spc) * 512 + k, song[k]);
    end

    // =====================================================================
    //  监视
    // =====================================================================
    integer we_cnt;
    integer we_addr [0:255];
    integer we_note [0:255];
    integer we_len  [0:255];
    integer commit_cnt;
    integer cap_count, cap_bpm;
    integer cycles;
    integer blk_cnt;

    // 统计实际读过几个数据块（每一次 WS_FILE 块的起始读请求 +1）
    reg [31:0] prev_lba;
    reg        prev_req;
    always @(posedge clk) begin
        if (load_we && we_cnt < 256) begin
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
        // 只数**文件数据块**（mode=1）读完的次数：spc=1 时中间会插 FAT 读，
        // 直接数总块数会让两种配置的期望值不一样，所以按 mode 过滤
        if (uut.u_sd.rd_done && uut.mode == 2'd1) begin
            blk_cnt = blk_cnt + 1;
            $display("     [BLK] 文件块 %0d 读完 lba=%0d", blk_cnt, uut.rd_lba);
        end
        prev_req <= uut.rd_req;
    end

    // =====================================================================
    //  主流程 + 判分
    // =====================================================================
    integer pass_n, fail_n;
    integer bad_addr, bad_note;

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

`ifdef SD_TRACE
    // 排障用轨迹：默认关闭（walk 每字节都换状态，会刷出几百万行）
    reg [3:0] prev_st;
    always @(posedge clk) begin
        if (uut.state !== prev_st) begin
            $display("[%0t] st=%0d mode=%0d lba=%0d bl=%0d clus=%0d sec=%0d fat=%0d",
                     $time, uut.state, uut.mode, uut.rd_lba, uut.bytes_left,
                     uut.cur_clus, uut.sec_in_clus, fat_err);
            prev_st <= uut.state;
        end
    end

    always @(posedge clk) begin
        if (uut.rd_req)
            $display("[%0t] RDREQ  lba=%0d sdst=%0d", $time, uut.rd_lba, uut.u_sd.state);
        if (uut.u_sd.rd_done)  $display("[%0t] RDDONE lba=%0d", $time, uut.rd_lba);
        if (uut.u_sd.rd_err)   $display("[%0t] RDERR  lba=%0d code=%0d", $time,
                                        uut.rd_lba, uut.u_sd.err_code);
    end
`endif

    initial begin
        pass_n = 0; fail_n = 0;
        we_cnt = 0; commit_cnt = 0; cap_count = 0; cap_bpm = 0;
        blk_cnt = 0; prev_lba = 32'hFFFFFFFF; prev_req = 1'b0;
        for (k = 0; k < 256; k = k + 1) begin
            we_addr[k] = -1; we_note[k] = -1; we_len[k] = -1;
        end
        rst_n = 1'b0;
        wait_cyc(20);
        rst_n = 1'b1;

        // ---- 1. 卡初始化 ----
        timeout = 0;
        while (!card_ready && timeout < 500000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        chk("SD 卡初始化完成 card_ready=1", card_ready === 1'b1);
        chk("SD 卡初始化无错误 card_err=0", card_err === 4'd0);

        // ---- 2. 触发装载 ----
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;

        timeout = 0;
        while (!load_done && !(|fat_err) && timeout < 2000000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        chk("装载完成 load_done 脉冲", load_done === 1'b1);
        chk("文件系统无错 fat_err=0", fat_err === 3'd0);
        chk("找到文件 file_found=1", file_found === 1'b1);
        chk("装载结束后 loading 回落", loading === 1'b0);

        wait_cyc(10);

        // ---- 3. 校验：跨块是否真的全读到了 ----
        $display("     DBG 读到 %0d 个写事件，共发起 %0d 次块读取", we_cnt, blk_cnt);
        chk("收到全部 255 个写事件（跨 3 扇区）", we_cnt == N_EVENTS);
        chk("文件数据块读了 3 个", blk_cnt == 3);
        chk("装载头 count=255", cap_count == N_EVENTS);
        chk("装载头 bpm=120", cap_bpm == 120);
        chk("提交恰好 1 次", commit_cnt == 1);

        // 逐个地址/音符核对：地址必须是 0..254 递增，音符 60+(i%24)
        bad_addr = 0; bad_note = 0;
        for (i = 0; i < N_EVENTS; i = i + 1) begin
            if (we_addr[i] !== i)                    bad_addr = bad_addr + 1;
            if (we_note[i] !== (60 + (i % 24)))      bad_note = bad_note + 1;
        end
        chk("255 个事件地址 0..254 严格递增", bad_addr == 0);
        chk("255 个事件音符 = 60+(i%24) 全对", bad_note == 0);
        chk("最后一个事件 addr=254", we_addr[N_EVENTS-1] == 254);
        chk("最后一个事件 note=74",  we_note[N_EVENTS-1] == 74);
        chk("协议无错 err_code=0", err_code === 3'd0);
        chk("协议错计数 err_count=0", err_count === 8'd0);

        $display("");
        $display("=============================================");
        $display("  SD 跨块装载 %0d 事件：%0d PASS / %0d FAIL", N_EVENTS, pass_n, fail_n);
        $display("=============================================");
        if (fail_n == 0) $display("  >>> 全部通过");
        else             $display("  >>> 存在失败项");
        $finish;
    end

    initial begin
        #300_000_000;
        $display("[TIMEOUT] 仿真超时，强制结束");
        $finish;
    end

endmodule
