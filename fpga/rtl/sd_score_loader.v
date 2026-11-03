// ---------------------------------------------------------------------------
// sd_score_loader.v —— 从 SD 卡（FAT32）读出曲谱文件并装载到 score_transport
//
//  设计要点
//   1. 与蓝牙通道共用 score_loader_core.v：协议与校验完全一致。
//      所以"曲谱文件"就是同一串 0x55 帧字节，
//      tools/send_score.py 生成的 .bin 直接拷进 SD 卡即可，不需要新格式。
//   2. 跑在 pixel_clk(35MHz) 域 —— 与 score_display_core 同域。
//      load_we / load_commit 是**单拍事件脉冲**，跨时钟会丢；放在目的同域
//      是唯一干净解法（与蓝牙通道同一个理由）。
//      SPI 分频按 35MHz 算：280 → 125 kHz（初始化），8 → 4.375 MHz（数据）。
//   3. 目录解析用**单遍顺序扫描**而不是随机访问：
//      读出整块后从字节 0 走到 511，按 ent_byte = byte_ptr[4:0] 判位，
//      一次线性扫描就把"首字节 / 属性 / 11 字节名 / 首簇 / 长度"全取到。
//      这样不需要可重入的"读 N 字节"子程序，也就没有返回状态打架的问题。
//   4. FAT32 流程：MBR → 分区起始 LBA → BPB → 根目录簇 → 匹配 8.3 名
//      → 首簇与长度 → 逐扇区读 → 跟随 FAT 簇链 → 字节流喂给 core。
//   5. 容错：MBR 签名不对 → 当作无分区表（文件系统从 LBA 0 开始）；
//      BPB 签名不对 → 报"非 FAT32"；根目录扫完没找到 → 报"找不到文件"。
//
//  文件名默认 "SONG    BIN"（8.3 大写）。改 FILE_NAME 即可换。
// ---------------------------------------------------------------------------
module sd_score_loader #(
    parameter [87:0] FILE_NAME = {8'h53, 8'h4F, 8'h4E, 8'h47,   // S O N G
                                  8'h20, 8'h20, 8'h20, 8'h20,   // 四个空格
                                  8'h42, 8'h49, 8'h4E},         // B I N
    parameter integer SPI_DIV_INIT = 280,   // 35MHz / 280 = 125 kHz
    parameter integer SPI_DIV_FAST = 8,     // 35MHz / 8   = 4.375 MHz
    parameter integer DIR_SEC_CAP  = 8      // 根目录最多扫 8 个扇区（128 项）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,               // 单拍脉冲：开始/重新装载

    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_csn,

    output wire        card_ready,
    output wire [3:0]  card_err,
    output wire        loading,             // 1=正在装载（用于门控蓝牙通道）
    output wire        file_found,
    output wire        load_done,           // 单拍脉冲
    output wire [2:0]  fat_err,             // 1=非FAT32 2=找不到文件 3=簇链异常

    output wire        load_we,
    output wire [7:0]  load_addr,
    output wire [6:0]  load_note,
    output wire [3:0]  load_length,
    output wire        load_commit,
    output wire [7:0]  load_count,
    output wire [7:0]  load_bpm,
    output wire        frame_done,
    output wire        commit_accept,
    output wire [2:0]  err_code,
    output wire [7:0]  err_count,
    output wire [7:0]  recv_count
);

    // ------------------------------------------------------------------
    // SD 卡控制器（块 RAM 为同步读出：设地址后需等 2 拍才能取数）
    // ------------------------------------------------------------------
    reg        rd_req;
    reg [31:0] rd_lba;
    wire       rd_busy, rd_done, rd_err;
    reg  [8:0] buf_addr;
    wire [7:0] buf_data;

    sd_card_ctrl #(.SPI_DIV_INIT(SPI_DIV_INIT), .SPI_DIV_FAST(SPI_DIV_FAST)) u_sd(
        .clk(clk), .rst_n(rst_n),
        .rd_req(rd_req), .rd_lba(rd_lba),
        .rd_busy(rd_busy), .rd_done(rd_done), .rd_err(rd_err),
        .buf_addr(buf_addr), .buf_data(buf_data),
        .card_ready(card_ready), .card_hc(), .err_code(card_err),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_csn(sd_csn));

    // ------------------------------------------------------------------
    // 字节流 → 装载核心（与蓝牙通道同一份实现）
    // ------------------------------------------------------------------
    reg [7:0] push_byte;
    reg       push_valid;

    score_loader_core u_core(
        .clk(clk), .rst_n(rst_n),
        .byte_data(push_byte), .byte_valid(push_valid),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .frame_done(frame_done), .commit_accept(commit_accept),
        .err_code(err_code), .err_count(err_count), .recv_count(recv_count));

    // ------------------------------------------------------------------
    // 解析寄存器
    // ------------------------------------------------------------------
    reg [31:0] part_lba, fat_size, root_clus, data_start;
    reg [31:0] cur_clus, file_clus, file_size, bytes_left;
    reg [15:0] reserved;
    reg [7:0]  sec_per_clus, num_fats;
    reg [7:0]  sec_in_clus, dir_sec_idx;
    reg [8:0]  byte_ptr;
    reg [3:0]  entry_idx;
    reg [4:0]  ent_byte;
    reg [7:0]  d_first, d_attr;
    reg        name_match, dir_end, hit;
    reg [31:0] clus_tmp, size_tmp;

    // ------------------------------------------------------------------
    // 状态机
    // ------------------------------------------------------------------
    localparam S_IDLE=0, S_MBR_RD=1, S_BPB_RD=2, S_DIR_RD=3, S_FAT_RD=4,
               S_FILE_RD=5,
               S_WAIT_BLK=6,                  // 等 rd_done / rd_err
               S_WALK=7, S_WALK2=8, S_WALK3=9, // 顺序走完 512 字节
               S_ADV=10, S_DONE=11, S_ERR=12;
    reg [3:0] state;
    reg [1:0] mode;                            // 0=扫目录 1=读文件 2=读 FAT
    reg [3:0] next_after_walk;                 // 走完一块后去哪

    // 本次扫描的是哪一种扇区。MBR/BPB 与目录项共用同一条 512 字节扫描通路，
    // 若不区分，扫 BPB 时 0x1C6 处的 0x00 会把 part_lba 清零、目录解析器又会
    // 把 BPB 首字节当成目录结束标志 —— 这就是 data_start 算出 12 而不是 13
    // 的根因。必须严格分块。
    localparam WS_MBR=3'd0, WS_BPB=3'd1, WS_DIR=3'd2, WS_FILE=3'd3, WS_FAT=3'd4;
    reg [2:0] walk_sel;

    reg       loading_r, found_r, done_r;
    reg [2:0] fat_err_r;
    assign loading    = loading_r;
    assign file_found = found_r;
    assign load_done  = done_r;
    assign fat_err    = fat_err_r;

    // 数据区 LBA 计算
    wire [31:0] clus_to_lba = data_start
                            + ((cur_clus - 32'd2) * {24'd0, sec_per_clus})
                            + {23'd0, sec_in_clus};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; rd_req <= 1'b0; rd_lba <= 32'd0; buf_addr <= 9'd0;
            part_lba <= 32'd0; fat_size <= 32'd0; root_clus <= 32'd0;
            data_start <= 32'd0; cur_clus <= 32'd0; file_clus <= 32'd0;
            file_size <= 32'd0; bytes_left <= 32'd0; reserved <= 16'd0;
            sec_per_clus <= 8'd1; num_fats <= 8'd0;
            sec_in_clus <= 8'd0; dir_sec_idx <= 8'd0; byte_ptr <= 9'd0;
            entry_idx <= 4'd0; ent_byte <= 5'd0;
            d_first <= 8'd0; d_attr <= 8'd0;
            name_match <= 1'b0; dir_end <= 1'b0; hit <= 1'b0;
            clus_tmp <= 32'd0; size_tmp <= 32'd0;
            push_byte <= 8'd0; push_valid <= 1'b0;
            mode <= 2'd0; next_after_walk <= 4'd0; walk_sel <= WS_MBR;
            loading_r <= 1'b0; found_r <= 1'b0; done_r <= 1'b0; fat_err_r <= 3'd0;
        end else begin
            rd_req     <= 1'b0;
            done_r     <= 1'b0;
            push_valid <= 1'b0;

            case (state)

                // ==================== 空闲 ====================
                S_IDLE: begin
                    loading_r <= 1'b0;
                    if (start && card_ready) begin
                        loading_r <= 1'b1; found_r <= 1'b0; fat_err_r <= 3'd0;
                        hit <= 1'b0; dir_end <= 1'b0;
                        rd_lba <= 32'd0; rd_req <= 1'b1;
                        mode <= 2'd0; walk_sel <= WS_MBR;
                        state <= S_WAIT_BLK; next_after_walk <= S_MBR_RD;
                    end
                end

                // ==================== 等块读完 ====================
                S_WAIT_BLK:
                    if (rd_done) begin
                        byte_ptr <= 9'd0; entry_idx <= 4'd0; ent_byte <= 5'd0;
                        name_match <= 1'b0;
                        state <= S_WALK;
                    end else if (rd_err) begin
                        fat_err_r <= (mode == 2'd1) ? 3'd3 : 3'd1;
                        state <= S_ERR;
                    end

                // ==================== 单遍顺序扫描 512 字节 ====================
                S_WALK:  begin buf_addr <= byte_ptr; state <= S_WALK2; end
                S_WALK2: begin state <= S_WALK3; end        // 块 RAM 同步读出延迟
                S_WALK3: begin
                    entry_idx <= byte_ptr[8:5];
                    ent_byte  <= byte_ptr[4:0];
                    case (walk_sel)
                        // ---------- 扫目录 ----------
                        WS_DIR: begin
                            case (byte_ptr[4:0])
                                5'd0: begin
                                    d_first <= buf_data;
                                    name_match <= (buf_data != 8'h00) &&
                                                  (buf_data != 8'hE5);
                                    if (buf_data == 8'h00) dir_end <= 1'b1;
                                end
                                5'd1,5'd2,5'd3,5'd4,5'd5,
                                5'd6,5'd7,5'd8,5'd9,5'd10: begin
                                    if (buf_data != FILE_NAME[(87 - ({3'd0,byte_ptr[4:0]}*8)) -: 8])
                                        name_match <= 1'b0;
                                end
                                5'd11: begin
                                    d_attr <= buf_data;
                                    // LFN 长名项不是真正的文件项
                                    if ((buf_data & 8'h0F) == 8'h0F) name_match <= 1'b0;
                                end
                                // FAT32 目录项字段都是小端：
                                //   20/21 = 首簇高 16 位（20 是低字节）
                                //   26/27 = 首簇低 16 位（26 是低字节）
                                //   28..31 = 文件长度（28 是低字节）
                                // 之前按大端拼，簇号 3 会被读成 0x300=768，
                                // 长度 16 会被读成 0x10000000，直接跑飞。
                                5'd20: clus_tmp[23:16] <= buf_data;
                                5'd21: clus_tmp[31:24] <= buf_data;
                                5'd26: clus_tmp[7:0]   <= buf_data;
                                5'd27: clus_tmp[15:8]  <= buf_data;
                                5'd28,5'd29,5'd30,5'd31:
                                        size_tmp <= {buf_data, size_tmp[31:8]};
                                default: ;
                            endcase
                            // 目录项最后一个字节：判定是否命中
                            if (byte_ptr[4:0] == 5'd31 && name_match) begin
                                // 必须与上面 size_tmp 的赋值用同一个表达式：
                                // 非阻塞赋值下此刻 size_tmp 还是「少了最后一字节」的值，
                                // 直接取会把 16 读成 4096。
                                file_clus  <= clus_tmp;
                                file_size  <= {buf_data, size_tmp[31:8]};
                                hit        <= 1'b1;
                                found_r    <= 1'b1;
                                name_match <= 1'b0;
                            end
                        end
                        // ---------- 读文件数据 ----------
                        WS_FILE: begin
                            if (bytes_left != 32'd0) begin
                                push_byte  <= buf_data;
                                push_valid <= 1'b1;
                                bytes_left <= bytes_left - 1'b1;
                            end
                        end
                        // ---------- 读 FAT ----------
                        WS_FAT: begin
                            // 每扇区 128 个 32-bit FAT 项；本簇的项在 byte_ptr[8:2]
                            // FAT32 的 FAT 项同样是小端
                            if (byte_ptr[8:2] == cur_clus[6:0]) begin
                                case (byte_ptr[1:0])
                                    2'd0: clus_tmp[7:0]   <= buf_data;
                                    2'd1: clus_tmp[15:8]  <= buf_data;
                                    2'd2: clus_tmp[23:16] <= buf_data;
                                    default: clus_tmp[31:24] <= buf_data;
                                endcase
                            end
                        end
                        // ---------- MBR / BPB：不做目录解析 ----------
                        default: ;
                    endcase

                    if (byte_ptr == 9'd511) begin
                        state <= next_after_walk;
                    end else begin
                        byte_ptr <= byte_ptr + 1'b1;
                        state <= S_WALK;
                    end
                end

                // ==================== MBR 解析完 → 读 BPB ====================
                S_MBR_RD: begin
                    // 0x1FE/0x1FF 应为 55 AA；分区起始 LBA 在 0x1C6（0x1BE+8）
                    if (buf_data != 8'hAA) begin
                        part_lba <= 32'd0;                 // 无 MBR：文件系统从 LBA0 起
                    end
                    // 注意：走到 511 时 buf_data 是 0x1FF = 0xAA
                    rd_lba <= (buf_data == 8'hAA) ? part_lba : 32'd0;
                    // part_lba 在上一步已经由 0x1C6..0x1C9 顺次拼好
                    rd_req <= 1'b1; mode <= 2'd0; walk_sel <= WS_BPB;
                    state <= S_WAIT_BLK; next_after_walk <= S_BPB_RD;
                end

                // ==================== BPB 解析完 → 读根目录 ====================
                S_BPB_RD: begin
                    if (buf_data != 8'hAA) begin          // 0x1FF != 0xAA → 不是 FAT32
                        fat_err_r <= 3'd1; state <= S_ERR;
                    end else begin
                        if (sec_per_clus == 8'd0) sec_per_clus <= 8'd1;
                        data_start <= part_lba + {16'd0, reserved}
                                    + ({24'd0, num_fats} * fat_size);
                        cur_clus    <= root_clus;
                        sec_in_clus <= 8'd0;
                        dir_sec_idx <= 8'd0;
                        rd_lba      <= part_lba + {16'd0, reserved}
                                    + ({24'd0, num_fats} * fat_size)
                                    + ((root_clus - 32'd2) * {24'd0, sec_per_clus});
                        rd_req      <= 1'b1;
                        mode        <= 2'd0; walk_sel <= WS_DIR;
                        state       <= S_WAIT_BLK;
                        next_after_walk <= S_DIR_RD;
                    end
                end

                // ==================== 目录扇区走完 ====================
                S_DIR_RD: begin
                    if (hit) begin
                        cur_clus    <= file_clus;
                        sec_in_clus <= 8'd0;
                        bytes_left  <= file_size;
                        rd_lba      <= data_start
                                    + ((file_clus - 32'd2) * {24'd0, sec_per_clus});
                        rd_req      <= 1'b1;
                        mode        <= 2'd1; walk_sel <= WS_FILE;
                        state       <= S_WAIT_BLK;
                        next_after_walk <= S_ADV;
                    end else if (dir_end) begin
                        fat_err_r <= 3'd2; state <= S_ERR;         // 后面没有了
                    end else if (dir_sec_idx + 1 >= DIR_SEC_CAP ||
                                 dir_sec_idx + 1 >= sec_per_clus) begin
                        fat_err_r <= 3'd2; state <= S_ERR;         // 扫够上限仍没找到
                    end else begin
                        dir_sec_idx <= dir_sec_idx + 1'b1;
                        rd_lba      <= data_start
                                    + ((cur_clus - 32'd2) * {24'd0, sec_per_clus})
                                    + {23'd0, (dir_sec_idx + 8'd1)};
                        rd_req      <= 1'b1;
                        mode        <= 2'd0; walk_sel <= WS_DIR;
                        state       <= S_WAIT_BLK;
                        next_after_walk <= S_DIR_RD;
                    end
                end

                // ==================== 数据块走完 → 下一块/下一簇/结束 ====================
                S_ADV: begin
                    if (bytes_left == 32'd0) begin
                        state <= S_DONE;
                    end else if (sec_in_clus + 1'b1 >= sec_per_clus) begin
                        // 需要 FAT 里的下一簇
                        rd_lba <= part_lba + {16'd0, reserved} + (cur_clus >> 7);
                        rd_req <= 1'b1; mode <= 2'd2; walk_sel <= WS_FAT;
                        state  <= S_WAIT_BLK; next_after_walk <= S_FAT_RD;
                    end else begin
                        sec_in_clus <= sec_in_clus + 1'b1;
                        rd_lba      <= data_start
                                    + ((cur_clus - 32'd2) * {24'd0, sec_per_clus})
                                    + {23'd0, (sec_in_clus + 8'd1)};
                        rd_req      <= 1'b1; mode <= 2'd1; walk_sel <= WS_FILE;
                        state       <= S_WAIT_BLK; next_after_walk <= S_ADV;
                    end
                end

                // ==================== FAT 块走完 → 跳到下一簇 ====================
                S_FAT_RD: begin
                    if ((clus_tmp & 32'h0FFFFFF8) == 32'h0FFFFFF8 || clus_tmp == 32'd0) begin
                        fat_err_r <= 3'd3; state <= S_ERR;
                    end else begin
                        cur_clus    <= clus_tmp & 32'h0FFFFFFF;
                        sec_in_clus <= 8'd0;
                        rd_lba      <= data_start
                                    + (((clus_tmp & 32'h0FFFFFFF) - 32'd2)
                                       * {24'd0, sec_per_clus});
                        rd_req      <= 1'b1; mode <= 2'd1; walk_sel <= WS_FILE;
                        state       <= S_WAIT_BLK; next_after_walk <= S_ADV;
                    end
                end

                // ==================== 结束 ====================
                S_DONE: begin
                    loading_r <= 1'b0; done_r <= 1'b1; state <= S_IDLE;
                end
                S_ERR: begin
                    loading_r <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase

            // ------------------------------------------------------------------
            // 在 WALK3 里按字节位置抓字段（MBR / BPB 也走同一条扫描通路）
            // ------------------------------------------------------------------
            // 关键：MBR 字段只在扫 MBR 时抓，BPB 字段只在扫 BPB 时抓。
            // 否则扫 BPB 时 0x1C6..0x1C9 全是 0，会把 part_lba 清成 0，
            // 导致 data_start 少算一个分区偏移（13 算成 12）。
            if (state == S_WALK3 && walk_sel == WS_MBR) begin
                case (byte_ptr)
                    // --- MBR：分区起始 LBA @0x1C6..0x1C9 ---
                    9'h1C6: part_lba[7:0]   <= buf_data;
                    9'h1C7: part_lba[15:8]  <= buf_data;
                    9'h1C8: part_lba[23:16] <= buf_data;
                    9'h1C9: part_lba[31:24] <= buf_data;
                    default: ;
                endcase
            end

            if (state == S_WALK3 && walk_sel == WS_BPB) begin
                case (byte_ptr)
                    // --- BPB：各字段 ---
                    9'h00D: sec_per_clus   <= (buf_data == 8'd0) ? 8'd1 : buf_data;
                    9'h00E: reserved[7:0]  <= buf_data;
                    9'h00F: reserved[15:8] <= buf_data;
                    9'h010: num_fats       <= buf_data;
                    9'h024: fat_size[7:0]   <= buf_data;
                    9'h025: fat_size[15:8]  <= buf_data;
                    9'h026: fat_size[23:16] <= buf_data;
                    9'h027: fat_size[31:24] <= buf_data;
                    9'h02C: root_clus[7:0]   <= buf_data;
                    9'h02D: root_clus[15:8]  <= buf_data;
                    9'h02E: root_clus[23:16] <= buf_data;
                    9'h02F: root_clus[31:24] <= buf_data;
                    default: ;
                endcase
            end
        end
    end

endmodule
