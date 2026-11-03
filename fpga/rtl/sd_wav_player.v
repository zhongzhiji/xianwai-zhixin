// ============================================================================
//  sd_wav_player.v —— 从 SD 卡流式播放 WAV（给人声 / 伴奏轨用）
// ----------------------------------------------------------------------------
//  要解决的问题：FPGA 自己合成不出真人声，想要"有人唱"就必须把录音放出来。
//  做法：FAT32 里放一个 48 kHz / 16 bit / 单声道的 VOCAL.WAV，上电后本模块
//  自己去根目录找到它、按簇链往下读、进 FIFO、在 48 kHz 节拍上吐出来。
//
//  和 sd_score_loader 的关系：
//    两者都需要独占 SPI 总线，所以**各自带一个 sd_card_ctrl**，
//    由顶层用 bus_grant 做二选一 MUX（曲谱装载期间归装载器，装载完归本模块）。
//    FAT32 的字节偏移口径与 sd_score_loader 完全一致（小端首簇、0x1C6 分区
//    起始、BPB 0x0D/0x0E/0x10/0x24/0x2C），改一处必须两处一起改。
//
//  时钟域：整个模块跑在 sys_clk（50 MHz），与音频链路同源，
//  FIFO 因此是**单时钟**的，不需要灰码指针。SPI 引脚在顶层做组合 MUX，
//  不引入跨域路径。
//
//  吞吐核算（能不能跟上 48 kHz）：
//    SPI_DIV_FAST=8 → SCK = 50MHz/16 = 3.125 MHz → 字节率约 390 KB/s。
//    48 kHz × 16 bit 单声道 = 96 KB/s，占 25%。
//    一个 512 字节块 = 256 样本 = 5.33 ms 音频，读取约 1.6 ms + 命令开销，
//    余量充足。FIFO 2048 样本 ≈ 42.7 ms，够扛住卡的偶发长响应。
//
//  WAV 格式约定（不做通用 RIFF 解析器，只认最常见的 44 字节标准头）：
//    0..3   "RIFF"      8..11 "WAVE"     36..39 "data"     40..43 数据长度
//    立体声/非 48 kHz 的文件也能播，但会按文件自己的速率出样，
//    与 48 kHz 输出不同源 → 会变调变快/变慢。请用 tools/prepare_vocal.py
//    先转成 48 kHz 单声道。
// ============================================================================
`timescale 1ns / 1ps

module sd_wav_player #(
    parameter integer SPI_DIV_INIT = 280,
    parameter integer SPI_DIV_FAST = 8,
    parameter integer DIR_SEC_CAP  = 8,
    parameter integer FIFO_AW      = 11      // 2048 样本
)(
    input  wire        clk,                  // sys_clk 50 MHz
    input  wire        rst_n,
    input  wire        bus_grant,            // 1 = SPI 总线归本模块
    input  wire        enable,               // 1 = 允许出声（接到伴奏开关）
    input  wire        sample_en,            // 48 kHz 采样节拍（frame_en）
    output reg  signed [15:0] pcm_out,
    output wire        active,               // 1 = 正在出人声
    output wire        file_found,
    output wire        card_ready,
    output wire [3:0]  err_code,             // 1=非FAT32 2=找不到文件 3=簇链坏 4=不是WAV
    output wire [3:0]  state_dbg,
    // ---- SPI 引脚（顶层 MUX 后接到卡座）----
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_csn
);

    localparam [87:0] FILE_NAME = "VOCAL   WAV";   // FAT 8.3：名 8 字节 + 扩展名 3 字节

    localparam S_IDLE=0, S_MBR_RD=1, S_BPB_RD=2, S_DIR_RD=3,
               S_BLK=4, S_WAIT_BLK=5, S_WALK=6, S_WALK2=7, S_WALK3=8,
               S_COPY=9, S_COPY2=10, S_COPY3=11,
               S_ADV=12, S_FAT_RD=13, S_FILL=14, S_DONE=15, S_ERR=16;
    localparam WS_MBR=3'd0, WS_BPB=3'd1, WS_DIR=3'd2, WS_FILE=3'd3, WS_FAT=3'd4;

    reg [4:0] state;
    assign state_dbg = state[3:0];

    // ---------------- FAT32 几何 ----------------
    reg [31:0] part_lba, fat_size, root_clus, data_start;
    reg [31:0] cur_clus, file_clus, file_size, bytes_left, clus_tmp, size_tmp;
    reg [15:0] reserved;
    reg [7:0]  sec_per_clus, num_fats, sec_in_clus, dir_sec_idx;
    reg [8:0]  byte_ptr;
    reg [4:0]  ent_byte;
    reg        name_match, dir_end, hit;
    reg [7:0]  d_first, d_attr;
    reg [2:0]  walk_sel;
    reg [4:0]  next_after_walk;

    // ---------------- WAV 头解析 ----------------
    reg [2:0]  riff_cnt;      // 匹配 "RIFF" 的字节数
    reg [2:0]  wave_cnt;      // 匹配 "WAVE"
    reg [2:0]  data_cnt;      // 匹配 "data"
    reg [31:0] data_size;     // 数据区字节数
    reg        is_wav;
    reg [15:0] sample_rate;   // 仅做状态显示，播放按文件自身速率
    reg [7:0]  ch_count;

    // ---------------- FIFO（单时钟）----------------
    reg [15:0] fifo [0:(1<<FIFO_AW)-1];
    reg [FIFO_AW:0] wr_ptr, rd_ptr;
    wire [FIFO_AW:0] fifo_count = wr_ptr - rd_ptr;
    wire            fifo_full   = (fifo_count == (1<<FIFO_AW));
    // 半仓补水：低于一半就去读下一块，留出卡的响应抖动余量
    wire            need_fill   = (fifo_count < (1<<(FIFO_AW-1)));

    reg [8:0]  cp_idx;        // 块内字节下标
    reg        cp_hi;         // 0=取低字节 1=取高字节
    reg [7:0]  lo_byte;
    reg [15:0] skip_cnt;      // 开头要丢掉的头部样本数
    reg [31:0] played;
    reg [31:0] samples_total;
    reg        active_r, found_r, started_r;
    reg [3:0]  err_r;
    // 音频侧的指针/计数只在音频 always 块里写，SD 侧只发一个重启脉冲。
    // 两边都写同一个寄存器会造成多驱动（iverilog 直接报 X，Gowin 会连错线）。
    reg        restart_p;
    wire [31:0] bl_next = (bytes_left > 32'd512) ? (bytes_left - 32'd512) : 32'd0;

    assign active     = active_r;
    assign file_found = found_r;
    assign err_code   = err_r;

    // ---------------- SD 卡控制器 ----------------
    reg        rd_req;
    reg [31:0] rd_lba;
    wire       rd_busy, rd_done, rd_err;
    reg [8:0]  buf_addr;
    wire [7:0] buf_data;
    wire       card_hc;
    wire [3:0] card_err;

    sd_card_ctrl #(.SPI_DIV_INIT(SPI_DIV_INIT), .SPI_DIV_FAST(SPI_DIV_FAST)) u_ctrl(
        .clk(clk), .rst_n(rst_n),
        .rd_req(rd_req), .rd_lba(rd_lba),
        .rd_busy(rd_busy), .rd_done(rd_done), .rd_err(rd_err),
        .buf_addr(buf_addr), .buf_data(buf_data),
        .card_ready(card_ready), .card_hc(card_hc), .err_code(card_err),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_csn(sd_csn));

    wire [31:0] clus_to_lba = data_start
                            + ((cur_clus - 32'd2) * {24'd0, sec_per_clus})
                            + {23'd0, sec_in_clus};

    // ========================================================================
    //  SD 侧：扫描 + 读块 + 灌 FIFO
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; rd_req <= 1'b0; rd_lba <= 32'd0; buf_addr <= 9'd0;
            part_lba <= 0; fat_size <= 0; root_clus <= 0; data_start <= 0;
            cur_clus <= 0; file_clus <= 0; file_size <= 0; bytes_left <= 0;
            reserved <= 0; sec_per_clus <= 8'd1; num_fats <= 0;
            sec_in_clus <= 0; dir_sec_idx <= 0; byte_ptr <= 0; ent_byte <= 0;
            name_match <= 0; dir_end <= 0; hit <= 0; d_first <= 0; d_attr <= 0;
            clus_tmp <= 0; size_tmp <= 0; walk_sel <= WS_MBR; next_after_walk <= 0;
            cp_idx <= 0; cp_hi <= 0; lo_byte <= 0;
            riff_cnt <= 0; wave_cnt <= 0; data_cnt <= 0; data_size <= 0;
            is_wav <= 0; sample_rate <= 0; ch_count <= 0;
            // skip_cnt / played / rd_ptr / active_r 归音频 always 块，
            // 这里一个都别写，否则就是多驱动
            samples_total <= 0;
            found_r <= 0; started_r <= 0; err_r <= 0;
            wr_ptr <= 0; restart_p <= 1'b0;
        end else begin
            rd_req     <= 1'b0;
            restart_p  <= 1'b0;

            // 上电后总线一交过来就开始扫描（只做一次；扫描完就停在 S_FILL）
            if (bus_grant && card_ready && !started_r && state == S_IDLE) begin
                started_r <= 1'b1;
                hit <= 1'b0; dir_end <= 1'b0;
                rd_lba <= 32'd0; rd_req <= 1'b1;
                walk_sel <= WS_MBR; next_after_walk <= S_MBR_RD;
                state <= S_WAIT_BLK;
            end else case (state)

                // ---------------- 等块读完 ----------------
                S_WAIT_BLK:
                    if (rd_done) begin
                        byte_ptr <= 9'd0; name_match <= 1'b0;
                        ent_byte <= 5'd0;
                        cp_idx <= 9'd0; cp_hi <= 1'b0;
                        state <= (next_after_walk == S_COPY) ? S_COPY : S_WALK;
                    end else if (rd_err) begin
                        err_r <= 3'd3; state <= S_ERR;
                    end

                // ---------------- 顺序扫描 512 字节（MBR/BPB/目录/FAT）----------------
                S_WALK:  begin buf_addr <= byte_ptr; state <= S_WALK2; end
                S_WALK2: begin state <= S_WALK3; end          // 块 RAM 同步读延迟
                S_WALK3: begin
                    ent_byte <= byte_ptr[4:0];
                    case (walk_sel)
                        WS_DIR: begin
                            case (byte_ptr[4:0])
                                5'd0: begin
                                    d_first <= buf_data;
                                    name_match <= (buf_data != 8'h00) && (buf_data != 8'hE5);
                                    if (buf_data == 8'h00) dir_end <= 1'b1;
                                end
                                5'd1,5'd2,5'd3,5'd4,5'd5,
                                5'd6,5'd7,5'd8,5'd9,5'd10: begin
                                    if (buf_data != FILE_NAME[(87 - ({3'd0,byte_ptr[4:0]}*8)) -: 8])
                                        name_match <= 1'b0;
                                end
                                5'd11: begin
                                    d_attr <= buf_data;
                                    if ((buf_data & 8'h0F) == 8'h0F) name_match <= 1'b0;  // LFN
                                end
                                // FAT32 目录项字段全是小端
                                5'd20: clus_tmp[23:16] <= buf_data;
                                5'd21: clus_tmp[31:24] <= buf_data;
                                5'd26: clus_tmp[7:0]   <= buf_data;
                                5'd27: clus_tmp[15:8]  <= buf_data;
                                5'd28,5'd29,5'd30,5'd31:
                                        size_tmp <= {buf_data, size_tmp[31:8]};
                                default: ;
                            endcase
                            if (byte_ptr[4:0] == 5'd31 && name_match) begin
                                file_clus  <= clus_tmp;
                                file_size  <= {buf_data, size_tmp[31:8]};
                                hit        <= 1'b1;
                                found_r    <= 1'b1;
                                name_match <= 1'b0;
                            end
                        end
                        WS_FAT: begin
                            // 每扇区 128 个 32-bit FAT 项，小端
                            if (byte_ptr[8:2] == cur_clus[6:0]) begin
                                case (byte_ptr[1:0])
                                    2'd0: clus_tmp[7:0]   <= buf_data;
                                    2'd1: clus_tmp[15:8]  <= buf_data;
                                    2'd2: clus_tmp[23:16] <= buf_data;
                                    default: clus_tmp[31:24] <= buf_data;
                                endcase
                            end
                        end
                        default: ;
                    endcase

                    if (byte_ptr == 9'd511) state <= next_after_walk;
                    else begin byte_ptr <= byte_ptr + 1'b1; state <= S_WALK; end
                end

                // ---------------- MBR → BPB ----------------
                S_MBR_RD: begin
                    if (buf_data != 8'hAA) part_lba <= 32'd0;    // 无 MBR：从 LBA0 起
                    rd_lba <= (buf_data == 8'hAA) ? part_lba : 32'd0;
                    rd_req <= 1'b1; walk_sel <= WS_BPB;
                    next_after_walk <= S_BPB_RD; state <= S_WAIT_BLK;
                end

                // ---------------- BPB → 根目录 ----------------
                S_BPB_RD: begin
                    if (buf_data != 8'hAA) begin
                        err_r <= 3'd1; state <= S_ERR;              // 不是 FAT32
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
                        rd_req <= 1'b1; walk_sel <= WS_DIR;
                        next_after_walk <= S_DIR_RD; state <= S_WAIT_BLK;
                    end
                end

                // ---------------- 目录扇区走完 ----------------
                S_DIR_RD: begin
                    if (hit) begin
                        cur_clus    <= file_clus;
                        sec_in_clus <= 8'd0;
                        bytes_left  <= file_size;
                        wr_ptr      <= 0;
                        restart_p   <= 1'b1;              // 音频侧清读指针 + 预置丢头计数
                        rd_lba      <= data_start
                                    + ((file_clus - 32'd2) * {24'd0, sec_per_clus});
                        rd_req <= 1'b1; walk_sel <= WS_FILE;
                        next_after_walk <= S_COPY; state <= S_WAIT_BLK;
                    end else if (dir_end || dir_sec_idx + 1 >= DIR_SEC_CAP ||
                                 dir_sec_idx + 1 >= sec_per_clus) begin
                        err_r <= 3'd2; state <= S_ERR;              // 找不到 VOCAL.WAV
                    end else begin
                        dir_sec_idx <= dir_sec_idx + 1'b1;
                        rd_lba      <= data_start
                                    + ((cur_clus - 32'd2) * {24'd0, sec_per_clus})
                                    + {23'd0, (dir_sec_idx + 8'd1)};
                        rd_req <= 1'b1; walk_sel <= WS_DIR;
                        next_after_walk <= S_DIR_RD; state <= S_WAIT_BLK;
                    end
                end

                // ---------------- 把 512 字节搬进 FIFO（2 字节 = 1 样本，小端）----------------
                S_COPY:  begin buf_addr <= cp_idx; state <= S_COPY2; end
                S_COPY2: begin state <= S_COPY3; end
                S_COPY3: begin
                    // 顺手解析标准 44 字节 WAV 头
                    if (cp_idx < 9'd44) begin
                        case (cp_idx)
                            9'd0: riff_cnt <= (buf_data == 8'h52) ? 3'd1 : 3'd0;
                            9'd1: if (buf_data == 8'h49) riff_cnt <= riff_cnt + 1'b1; else riff_cnt <= 0;
                            9'd2: if (buf_data == 8'h46) riff_cnt <= riff_cnt + 1'b1; else riff_cnt <= 0;
                            9'd3: if (buf_data == 8'h46) riff_cnt <= riff_cnt + 1'b1; else riff_cnt <= 0;
                            9'd8:  wave_cnt <= (buf_data == 8'h57) ? 3'd1 : 3'd0;
                            9'd9:  if (buf_data == 8'h41) wave_cnt <= wave_cnt + 1'b1; else wave_cnt <= 0;
                            9'd10: if (buf_data == 8'h56) wave_cnt <= wave_cnt + 1'b1; else wave_cnt <= 0;
                            9'd11: if (buf_data == 8'h45) wave_cnt <= wave_cnt + 1'b1; else wave_cnt <= 0;
                            9'd22: ch_count[7:0] <= buf_data;                 // 声道数（低字节）
                            9'd24: sample_rate[7:0]   <= buf_data;            // 采样率（小端）
                            9'd25: sample_rate[15:8]  <= buf_data;
                            9'd36: data_cnt <= (buf_data == 8'h64) ? 3'd1 : 3'd0;
                            9'd37: if (buf_data == 8'h61) data_cnt <= data_cnt + 1'b1; else data_cnt <= 0;
                            9'd38: if (buf_data == 8'h74) data_cnt <= data_cnt + 1'b1; else data_cnt <= 0;
                            9'd39: if (buf_data == 8'h61) data_cnt <= data_cnt + 1'b1; else data_cnt <= 0;
                            9'd40: data_size[7:0]   <= buf_data;
                            9'd41: data_size[15:8]  <= buf_data;
                            9'd42: data_size[23:16] <= buf_data;
                            9'd43: data_size[31:24] <= buf_data;
                            default: ;
                        endcase
                    end
                    if (!cp_hi) begin
                        lo_byte <= buf_data;
                    end else if (!fifo_full) begin
                        fifo[wr_ptr[FIFO_AW-1:0]] <= {buf_data, lo_byte};
                        wr_ptr <= wr_ptr + 1'b1;
                    end
                    cp_hi <= ~cp_hi;
                    if (cp_idx == 9'd511) begin
                        // 第一块读完就能判定是不是 WAV
                        if (bytes_left == file_size) begin
                            if (!(riff_cnt == 3'd4 && wave_cnt == 3'd4)) begin
                                err_r <= 3'd4; state <= S_ERR;
                            end else begin
                                is_wav <= 1'b1;
                                // data 块紧跟 44 字节头 → 丢 22 个样本；
                                // 非标准头（data_cnt 没匹配上）也按 22 处理并在文档里说明
                                samples_total <= (data_size != 0)
                                                 ? (data_size >> 1)
                                                 : ((file_size >> 1) - 16'd22);
                                state <= S_ADV;
                            end
                        end else
                            state <= S_ADV;
                    end else begin
                        cp_idx <= cp_idx + 1'b1; state <= S_COPY;
                    end
                end

                // ---------------- 一块搬完 → 下一块 / 下一簇 / 结束 ----------------
                S_ADV: begin
                    bytes_left <= bl_next;
                    if (bytes_left <= 32'd512) begin
                        state <= S_DONE;
                    end else if (sec_in_clus + 1'b1 >= sec_per_clus) begin
                        rd_lba <= part_lba + {16'd0, reserved} + (cur_clus >> 7);
                        rd_req <= 1'b1; walk_sel <= WS_FAT;
                        next_after_walk <= S_FAT_RD; state <= S_WAIT_BLK;
                    end else begin
                        sec_in_clus <= sec_in_clus + 1'b1;
                        state <= S_FILL;
                    end
                end
                S_FAT_RD: begin
                    if ((clus_tmp & 32'h0FFFFFF8) == 32'h0FFFFFF8 || clus_tmp == 32'd0) begin
                        err_r <= 3'd3; state <= S_ERR;
                    end else begin
                        cur_clus    <= clus_tmp & 32'h0FFFFFFF;
                        sec_in_clus <= 8'd0;
                        state <= S_FILL;
                    end
                end

                // ---------------- 补水等待：FIFO 低于半仓就再读一块 ----------------
                S_FILL: begin
                    if (need_fill && !rd_busy && bytes_left != 0) begin
                        rd_lba <= clus_to_lba;
                        rd_req <= 1'b1; walk_sel <= WS_FILE;
                        next_after_walk <= S_COPY; state <= S_WAIT_BLK;
                    end
                end

                S_DONE: begin /* 文件读完，FIFO 里剩下的继续播完 */ end
                S_ERR:  begin /* 出错就停在这里，state_dbg 可供排查 */ end
                default: state <= S_IDLE;
            endcase

            // ---- MBR 字段（只在扫 MBR 时抓，否则会被 BPB 的 0 清掉）----
            if (state == S_WALK3 && walk_sel == WS_MBR) begin
                case (byte_ptr)
                    9'h1C6: part_lba[7:0]   <= buf_data;
                    9'h1C7: part_lba[15:8]  <= buf_data;
                    9'h1C8: part_lba[23:16] <= buf_data;
                    9'h1C9: part_lba[31:24] <= buf_data;
                    default: ;
                endcase
            end
            // ---- BPB 字段 ----
            if (state == S_WALK3 && walk_sel == WS_BPB) begin
                case (byte_ptr)
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

    // ========================================================================
    //  音频侧：48 kHz 节拍上从 FIFO 取样本
    // ------------------------------------------------------------------------
    //  开头 skip_cnt 个样本是 WAV 头（会被当成音频播出来就是一段噪音），
    //  必须先丢掉——这是"一播人声先是啪一声杂音"的典型来源。
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0; pcm_out <= 16'sd0; active_r <= 1'b0;
        end else if (restart_p) begin
            rd_ptr   <= 0;
            skip_cnt <= 16'd22;         // 44 字节标准头 = 22 个 16 bit 样本
            played   <= 32'd0;
            pcm_out  <= 16'sd0;
            active_r <= 1'b0;
        end else if (sample_en) begin
            if (!enable || fifo_count == 0) begin
                pcm_out  <= 16'sd0;
                active_r <= 1'b0;
            end else if (skip_cnt != 16'd0) begin
                // 丢掉标准头占用的样本
                skip_cnt <= skip_cnt - 1'b1;
                rd_ptr   <= rd_ptr + 1'b1;
                pcm_out  <= 16'sd0;
                active_r <= 1'b0;
            end else if (samples_total != 0 && played >= samples_total) begin
                pcm_out  <= 16'sd0;
                active_r <= 1'b0;
            end else begin
                pcm_out  <= fifo[rd_ptr[FIFO_AW-1:0]];
                rd_ptr   <= rd_ptr + 1'b1;
                played   <= played + 1'b1;
                active_r <= 1'b1;
            end
        end
    end
endmodule
