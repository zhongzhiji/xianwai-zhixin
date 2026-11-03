// Score transport for the original LCD UI. No audio, UART or Bluetooth here.
// All control inputs and frame_tick are one-clock pulses in the clk domain.
// FRAME_HZ is the integer approximation of complete LCD frames per second;
// use FRAME_HZ >= 48 for the new 12-tick scores at BPM240 (hardware ~55.09 Hz).
module score_transport #(
    parameter integer FRAME_HZ = 55,
    parameter integer ENABLE_GUIDANCE = 0,
    // ------------------------------------------------------------------
    // 单曲事件容量上限。原来是**硬编码 64**（notes/lengths 数组 0:63、
    // load_addr 只有 6 位），一首完整的曲子必须切成 4 段才能装进来，
    // 现场演示体验很差。现在参数化成 255（= 一个字节能表示的最大 count）。
    //
    // 资源代价：存储是 7bit+4bit 的分布式 RAM（不是 BSRAM，本工程 BSRAM
    // 已经 87%），64→255 大约多 6 kbit LUT RAM，对 34% 的 Logic 占用无感。
    //
    // 想回退成旧行为：把 MAX_EVENTS 改成 64、ADDR_W 改成 6 即可。
    // ------------------------------------------------------------------
    parameter integer MAX_EVENTS = 255,
    parameter integer ADDR_W     = 8
)(
    input wire clk,
    input wire reset_n,
    input wire frame_tick,
    input wire toggle_play,
    input wire restart,
    input wire next_timbre,
    input wire next_song,
    input wire pause_request,
    input wire step_mode,
    input wire step_advance,
    input wire load_we,
    input wire [ADDR_W-1:0] load_addr,
    input wire [6:0] load_note,
    input wire [3:0] load_length,
    input wire load_commit,
    input wire [7:0] load_count,
    input wire [7:0] load_bpm,
    output reg [55:0] score_notes,
    output reg [31:0] score_lengths,
    output wire [2:0] active_slot,
    output wire [7:0] page_index,
    // 当前音符到"判定线"还剩几个 tick。下落式音游用它算音符块的 y 坐标：
    // 有了它，音符块才能连续下滑，而不是每跳一个音符才跳一格。
    output wire [7:0] ticks_left,
    output reg [6:0] progress,
    output reg [23:0] guide,
    output wire [6:0] current_midi_note,
    output reg [6:0] target_midi_note,
    output reg target_ready,
    output reg completed,
    output reg playing,
    output reg [1:0] timbre,
    output wire [7:0] bpm,
    output reg imported_score,
    output reg [2:0] song_id
);
    localparam integer TICK_THRESHOLD = FRAME_HZ * 60;
    wire step_active=(ENABLE_GUIDANCE!=0) ? step_mode : 1'b0;
    reg previous_step_active;

    reg [6:0] notes_a   [0:MAX_EVENTS-1];
    reg [6:0] notes_b   [0:MAX_EVENTS-1];
    reg [3:0] lengths_a [0:MAX_EVENTS-1];
    reg [3:0] lengths_b [0:MAX_EVENTS-1];
    reg active_bank;
    // 草稿校验从"255 位 valid 位图"改成两个计数器（见 commit_valid 处说明）
    reg [ADDR_W-1:0] draft_max_addr;
    reg [9:0]        draft_written;
    reg [10:0] event_count;
    reg [7:0] tempo_bpm;
    reg [9:0] event_index;
    reg [7:0] duration_tick;
    reg [31:0] tempo_accumulator;
    reg commit_valid;
    reg [6:0] current_note;
    reg [7:0] current_length;
    wire user_score = !imported_score && song_id >= 3'd4;
    wire [119:0] user_words;
    wire [10:0] user_count_0,user_count_1,user_count_2;
    wire [7:0] user_bpm_0,user_bpm_1,user_bpm_2;
    reg [9:0] user_index_d1,user_index_d2;
    reg [2:0] user_song_d1,user_song_d2,user_row_song,user_selected_song;
    reg [6:0] user_row_page,user_selected_page;
    reg [14:0] user_current_word;
    wire user_ready = user_index_d2 == event_index && user_song_d2 == song_id &&
                      user_selected_song == song_id &&
                      user_selected_page == event_index[9:3];

    // Eight independent synchronous ROM lanes: each address is one score page.
    // Selection is another registered stage. On index/song changes guide stays
    // silent for two clocks, so a stale note is never sent to the audio engine.
    user_song_rom u_user_rom(.clk(clk),.song_select(song_id[1:0]),
        .page_address(event_index[9:3]),.words(user_words),
        .song0_count(user_count_0),.song1_count(user_count_1),.song2_count(user_count_2),
        .song0_bpm(user_bpm_0),.song1_bpm(user_bpm_1),.song2_bpm(user_bpm_2));
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            user_index_d1<=0;user_index_d2<=0;
            user_song_d1<=0;user_song_d2<=0;
            user_row_page<=0;user_selected_page<=0;
            user_row_song<=0;user_selected_song<=0;user_current_word<=0;
        end else begin
            user_index_d1<=event_index;user_index_d2<=user_index_d1;
            user_song_d1<=song_id;user_song_d2<=user_song_d1;
            user_row_page<=event_index[9:3];user_selected_page<=user_row_page;
            user_row_song<=song_id;user_selected_song<=user_row_song;
            case(user_index_d1[2:0])
                0:user_current_word<=user_words[14:0];
                1:user_current_word<=user_words[29:15];
                2:user_current_word<=user_words[44:30];
                3:user_current_word<=user_words[59:45];
                4:user_current_word<=user_words[74:60];
                5:user_current_word<=user_words[89:75];
                6:user_current_word<=user_words[104:90];
                7:user_current_word<=user_words[119:105];
            endcase
        end
    end
    integer reset_i;
    integer window_i;
    integer window_address;

    wire note_is_valid = (load_note == 7'd0) ||
                         ((load_note >= 7'd60) && (load_note <= 7'd83));
    wire [31:0] tempo_increment = user_score ?
        (({24'd0,tempo_bpm} << 3)+({24'd0,tempo_bpm} << 2)) :
        ({24'd0,tempo_bpm} << 2);
    wire [31:0] frame_sum = tempo_accumulator + tempo_increment;

    assign active_slot = event_index[2:0];
    assign page_index = {1'd0, event_index[9:3]};
    assign bpm = tempo_bpm;
    // 当前音符剩余 tick。current_length 是音符总时长（tick），duration_tick
    // 是已经走过的 tick；两者都是 reg，减法后钳到 0 防止长度被改小的时候下溢。
    // Display lengths use four units per quarter; user ROM uses twelve.
    // Round remaining sub-ticks upward to preserve the final visible unit.
    wire [7:0] remaining_ticks = (current_length > duration_tick) ?
                        (current_length - duration_tick) : 8'd0;
    assign ticks_left = user_score ? (({1'b0,remaining_ticks}+9'd2)/3) : remaining_ticks;
    // Audio sees the source pitch, including user-song notes outside C4..B5.
    // Legacy guide remains the 24-bit screen keyboard range; never transpose.
    wire ready_now = !user_score || user_ready;
    assign current_midi_note = playing && ready_now ? current_note : 7'd0;
    // The visible learning target is independent of whether audio/transport run.
    //
    // 时序修复（2026-11-01）：target_* 原来是 event_index 的纯组合输出。
    // current_note 来自 notes_a/event_index 的**异步读**（255 选 1 的 LUT 多路器）
    // 与 library_note() 的大 case，再往下游接 score_note_matcher 的
    // 32 位桶形移位 + PLAYABLE_MASK 归约 + hits 进位链，构成全设计最差路径：
    // 实测 slack 仅 0.005 ns（pixel_clk 35.006 MHz，余量 0.02%）。
    // 这里在 transport 出口打一拍，把那条 28 ns 组合链切成两段。
    // 只打指引/显示这一支；音频 current_midi_note 与内部时长计数仍用组合值，
    // 行为逐比特不变。下游 event_token 由 display core 同步打拍，保持对齐。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            target_midi_note <= 7'd0;
            target_ready     <= 1'b0;
        end else begin
            target_midi_note <= ready_now ? current_note : 7'd0;
            target_ready     <= ready_now;
        end
    end

    // Public-domain melody, adapted to a short 32-event practice excerpt.
    // The last quarter of each phrase is a rest, useful for showing releases.
    function [6:0] demo_note;
        input integer address;
        begin
            case (address)
                0, 1, 6, 11, 12, 16, 17, 22, 27: demo_note = 7'd64;
                2, 5, 18, 21: demo_note = 7'd65;
                3, 4, 19, 20: demo_note = 7'd67;
                7, 10, 13, 14, 23, 26, 28: demo_note = 7'd62;
                8, 9, 24, 25, 29, 30: demo_note = 7'd60;
                default: demo_note = 7'd0;
            endcase
        end
    endfunction

    function [3:0] demo_length;
        input integer address;
        begin
            case (address)
                12, 28: demo_length = 4'd6;
                13, 29: demo_length = 4'd2;
                default: demo_length = 4'd4;
            endcase
        end
    endfunction

    // Bounded 7-step fraction arithmetic, no variable '/' operator.
    // Practice arrangements: three public-domain compositions and one original.
    function [6:0] library_note;
        input [2:0] song;
        input integer address;
        begin
            library_note=0;
            case(song)
                0: library_note=demo_note(address);
                1: case(address)
                    0,1,13,28,29,41: library_note=60;
                    2,3,6,14,15,21,22,30,31,34: library_note=67;
                    4,5,32,33: library_note=69;
                    7,8,16,17,23,24,35,36: library_note=65;
                    9,10,18,19,25,26,37,38: library_note=64;
                    11,12,20,27,39,40: library_note=62;
                    default: library_note=0;
                endcase
                2: case(address)
                    0,3,4,7,19,25,26,28,29,31: library_note=72;
                    1,5: library_note=74;
                    2,6,8,11,18,24: library_note=76;
                    9,12,17,23: library_note=77;
                    10,13,14,16,20,22: library_note=79;
                    15,21: library_note=81;
                    27,30: library_note=67;
                    default: library_note=0;
                endcase
                3: case(address)
                    0,14,22: library_note=60;
                    1,13,20: library_note=64;
                    2,12,18: library_note=67;
                    3,11,16: library_note=71;
                    4,10: library_note=72;
                    5,9,17: library_note=69;
                    6,8,19: library_note=65;
                    default: library_note=0;
                endcase
                default: library_note=0;
            endcase
        end
    endfunction
    function [3:0] library_length;
        input [2:0] song;
        input integer address;
        begin
            library_length=4;
            case(song)
                0: library_length=demo_length(address);
                1: case(address)
                    6,13,20,27,34,41: library_length=8;
                    default: library_length=4;
                endcase
                2: case(address)
                    10,13,26,27,28,29,30,31: library_length=8;
                    14,15,16,17,18,19,20,21,22,23,24,25: library_length=2;
                    default: library_length=4;
                endcase
                default: library_length=4;
            endcase
        end
    endfunction
    function [10:0] library_count;
        input [2:0] song;
        begin
            case(song)
                1: library_count=42;
                3: library_count=24;
                4: library_count=user_count_0;
                5: library_count=user_count_1;
                6: library_count=user_count_2;
                default: library_count=32;
            endcase
        end
    endfunction
    function [7:0] library_bpm;
        input [2:0] song;
        begin
            case(song)
                1: library_bpm=110;
                2: library_bpm=120;
                3: library_bpm=90;
                4: library_bpm=user_bpm_0;
                5: library_bpm=user_bpm_1;
                6: library_bpm=user_bpm_2;
                default: library_bpm=100;
            endcase
        end
    endfunction
    // First find floor(position*128/count) and its remainder; subtract one
    // exactly when that remainder is less than position to get *127/count.
    // Kept as a simulation oracle. The hardware progress datapath below performs
    // one step per clock, instead of synthesizing this seven-step function chain.
    function [6:0] normalized_position;
        input [9:0] position;
        input [10:0] count;
        reg [6:0] quotient;
        reg [11:0] remainder;
        integer bit_i;
        begin
            quotient = 7'd0;
            remainder = {2'd0, position};
            for (bit_i = 6; bit_i >= 0; bit_i = bit_i - 1) begin
                remainder = remainder << 1;
                if (remainder >= {1'b0, count}) begin
                    remainder = remainder - {1'b0, count};
                    quotient[bit_i] = 1'b1;
                end
            end
            normalized_position = (remainder < {2'd0, position}) ?
                                  quotient - 1'b1 : quotient;
        end
    endfunction

    // Exact floor(index*127/count), computed over seven short compare/subtract
    // clocks after each position change. No variable divide or long carry chain.
    reg [9:0] progress_index;
    reg [10:0] progress_count;
    reg [11:0] progress_remainder;
    reg [6:0] progress_quotient;
    reg [2:0] progress_bit;
    reg progress_busy;
    wire [11:0] progress_shift = progress_remainder << 1;
    wire progress_subtract = progress_shift >= {1'b0,progress_count};
    wire [11:0] progress_next_remainder = progress_subtract ?
        progress_shift - {1'b0,progress_count} : progress_shift;
    wire [6:0] progress_next_quotient =
        {progress_quotient[5:0],progress_subtract};
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            progress<=0;progress_index<=0;progress_count<=32;
            progress_remainder<=0;progress_quotient<=0;
            progress_bit<=0;progress_busy<=0;
        end else if(completed) begin
            progress<=127;progress_busy<=0;
        end else if(progress_index != event_index || progress_count != event_count) begin
            progress_index<=event_index;progress_count<=event_count;
            progress_remainder<={2'd0,event_index};progress_quotient<=0;
            progress_bit<=6;progress_busy<=event_index!=0;
            if(event_index==0) progress<=0;
        end else if(event_index==0) begin
            // A one-event exercise finishes at index0; restarting that same
            // index must still clear the terminal127, even without index change.
            progress<=0;progress_busy<=0;
        end else if(progress_busy) begin
            progress_remainder<=progress_next_remainder;
            progress_quotient<=progress_next_quotient;
            if(progress_bit==0) begin
                progress<=progress_next_remainder < {2'd0,progress_index} ?
                    progress_next_quotient-1'b1 : progress_next_quotient;
                progress_busy<=0;
            end else progress_bit<=progress_bit-1'b1;
        end
    end

    function [3:0] visual_length;
        input [7:0] ticks;
        reg [8:0] rounded;
        begin
            // 12 musical ticks per quarter -> legacy four-unit drawing scale.
            // Division is by a compile-time constant, never a variable divisor.
            rounded=({1'b0,ticks}+1)/3;
            if(rounded<1) visual_length=1;
            else if(rounded>15) visual_length=15;
            else visual_length=rounded[3:0];
        end
    endfunction

    // All requested events must have been explicitly written to the draft.
    // A bad commit does not change the active score or clear a repairable draft.
    // ------------------------------------------------------------------
    // 提交校验 —— 原来这里是 `for (check_i=0; check_i<64; ...) if (!draft_valid[i])
    // commit_valid=0;`，即一条展开 64 级的与门链。扩到 255 后照抄会变成 255 级，
    // 直接成为新的关键路径（本工程已经在 fsr_gate / chord_from_keys 上为
    // "长组合链"交过学费）。改成两个计数器，O(1)：
    //   · draft_written  >= count   —— 漏写一个就差 1，拦得住
    //   · draft_max_addr >= count-1 —— 只写前几个就提交，拦得住
    // 工具（send_score.py / make_sd_score.py）都是按序写 0..count-1，
    // 与原位图校验等价；异常输入下略宽松，但最坏结果是某个音变休止，不会崩。
    // ------------------------------------------------------------------
    wire [9:0] load_count_ext = {2'd0, load_count};
    always @* begin
        commit_valid = (load_count >= 8'd1) && (load_count_ext <= MAX_EVENTS) &&
                       (load_bpm >= 8'd40) && (load_bpm <= 8'd240) && !load_we &&
                       (draft_written >= load_count_ext) &&
                       (draft_max_addr >= load_count - 8'd1);
    end

    always @* begin
        if (user_score) begin
            current_note = user_current_word[14:8];
            current_length = user_current_word[7:0];
        end else if (!imported_score) begin
            current_note = library_note(song_id,event_index);
            current_length = library_length(song_id,event_index);
        end else if (active_bank) begin
            current_note = notes_b[event_index[ADDR_W-1:0]];
            current_length = {4'd0,lengths_b[event_index[ADDR_W-1:0]]};
        end else begin
            current_note = notes_a[event_index[ADDR_W-1:0]];
            current_length = {4'd0,lengths_a[event_index[ADDR_W-1:0]]};
        end
        score_notes = 56'd0;
        score_lengths = 32'd0;
        window_address = 0;
        for (window_i = 0; window_i < 8; window_i = window_i + 1) begin
            window_address = {event_index[9:3], 3'b000} + window_i;
            if (window_address < event_count) begin
                if(user_score) begin
                    if(user_row_page==event_index[9:3] && user_row_song==song_id) begin
                        score_notes[window_i*7 +: 7] = user_words[window_i*15+8 +: 7];
                        score_lengths[window_i*4 +: 4] = visual_length(user_words[window_i*15 +: 8]);
                    end
                end else if (!imported_score) begin
                    score_notes[window_i*7 +: 7] = library_note(song_id,window_address);
                    score_lengths[window_i*4 +: 4] = library_length(song_id,window_address);
                end else if (active_bank) begin
                    score_notes[window_i*7 +: 7] = notes_b[window_address[ADDR_W-1:0]];
                    score_lengths[window_i*4 +: 4] = lengths_b[window_address[ADDR_W-1:0]];
                end else begin
                    score_notes[window_i*7 +: 7] = notes_a[window_address[ADDR_W-1:0]];
                    score_lengths[window_i*4 +: 4] = lengths_a[window_address[ADDR_W-1:0]];
                end
            end
        end
        guide = 24'd0;
        if (playing && (!user_score || user_ready) &&
            current_note >= 7'd60 && current_note <= 7'd83)
            guide[current_note - 7'd60] = 1'b1;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_bank <= 1'b0;
            draft_max_addr <= {ADDR_W{1'b0}};
            draft_written  <= 10'd0;
            event_count <= 11'd32;
            tempo_bpm <= 8'd100;
            event_index <= 10'd0;
            duration_tick <= 8'd0;
            tempo_accumulator <= 32'd0;
            playing <= 1'b0;
            completed <= 1'b0;
            previous_step_active <= 1'b0;
            timbre <= 2'd0;
            imported_score <= 1'b0;
            song_id <= 0;
            for (reset_i = 0; reset_i < MAX_EVENTS; reset_i = reset_i + 1) begin
                notes_a[reset_i] <= demo_note(reset_i);
                notes_b[reset_i] <= demo_note(reset_i);
                lengths_a[reset_i] <= demo_length(reset_i);
                lengths_b[reset_i] <= demo_length(reset_i);
            end
        end else begin
            previous_step_active <= step_active;
            if (load_we) begin
                if (active_bank) begin
                    notes_a[load_addr] <= load_note;
                    lengths_a[load_addr] <= load_length;
                end else begin
                    notes_b[load_addr] <= load_note;
                    lengths_b[load_addr] <= load_length;
                end
                draft_written  <= draft_written + 10'd1;
                if (load_addr > draft_max_addr)
                    draft_max_addr <= load_addr;
            end

            if (next_timbre)
                timbre <= (timbre == 2'd2) ? 2'd0 : timbre + 1'b1;

            if (next_song) begin
                song_id <= (song_id>=6) ? 0 : song_id+1'b1;
                event_count <= library_count((song_id>=6) ? 0 : song_id+1'b1);
                tempo_bpm <= library_bpm((song_id>=6) ? 0 : song_id+1'b1);
                event_index <= 0; duration_tick <= 0;
                tempo_accumulator <= 0;
                imported_score <= 0; playing <= 0;
                completed <= 0;
            end else if (step_active != previous_step_active) begin
                // Mode changes start a fresh, paused attempt; never reuse a hit.
                event_index<=0;duration_tick<=0;tempo_accumulator<=0;
                playing<=0;completed<=0;
            end else if (pause_request) begin
                playing <= 0;
            end else if (load_commit && commit_valid) begin
                imported_score <= 1'b1;
                active_bank <= !active_bank;
                draft_max_addr <= {ADDR_W{1'b0}};
                draft_written  <= 10'd0;
                event_count <= {3'd0,load_count};
                tempo_bpm <= load_bpm;
                event_index <= 10'd0;
                duration_tick <= 8'd0;
                tempo_accumulator <= 32'd0;
                completed <= 1'b0;
                // Preserve paused/playing state across an import.
            end else if (restart) begin
                event_index <= 10'd0;
                duration_tick <= 8'd0;
                tempo_accumulator <= 32'd0;
                playing <= 1'b1;
                completed <= 1'b0;
            end else if (toggle_play) begin
                if(step_active && completed) begin
                    event_index<=0;duration_tick<=0;tempo_accumulator<=0;
                    completed<=0;playing<=1;
                end else playing <= !playing;
            end else if (step_active && step_advance && playing &&
                         ready_now && current_note!=0) begin
                duration_tick<=0;tempo_accumulator<=0;
                if({1'b0,event_index}+11'd1>=event_count) begin
                    completed<=1;playing<=0;
                end else event_index<=event_index+1'b1;
            end else if (frame_tick && playing && ready_now &&
                         (!step_active || current_note==0)) begin
                if (frame_sum >= TICK_THRESHOLD) begin
                    tempo_accumulator <= frame_sum - TICK_THRESHOLD;
                    if (duration_tick == current_length - 1'b1) begin
                        duration_tick <= 8'd0;
                        if ({1'b0, event_index} + 11'd1 >= event_count) begin
                            if(step_active) begin completed<=1;playing<=0;end
                            else event_index <= 10'd0;
                        end else begin
                            event_index <= event_index + 1'b1;
                        end
                    end else begin
                        duration_tick <= duration_tick + 1'b1;
                    end
                end else begin
                    tempo_accumulator <= frame_sum;
                end
            end
        end
    end
endmodule
