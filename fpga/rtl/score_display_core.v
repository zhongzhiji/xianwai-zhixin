// Pixel-domain display and transport. Audio GPIOs are driven by the parent.
// Inputs, including import and external_pressed, MUST be in pixel_clk domain.
// The parent uses atomic mailboxes for UART/MPR input and audio control.
module score_display_core #(
    parameter SHOWCASE=0,
    parameter H_ACTIVE=800, H_BACK=182, H_FRONT=210,
    parameter V_ACTIVE=480, V_BACK=8, V_FRONT=45,
    parameter FRAME_HZ=55,
    parameter AUDIO_NOTE_GAP_CYCLES=175000,
    parameter ENABLE_GUIDANCE=0
)(
    input wire [21:0] showcase_config,
    input wire pixel_clk, reset_n,
    input wire toggle_play, restart, next_timbre, toggle_demo,
    input wire next_mode, next_instrument,
    input wire next_song,
    input wire [2:0] input_online,
    input wire [31:0] external_pressed,
    input wire [6:0] external_expression,
    input wire [4:0] volume_step,
    input wire volume_edit,
    input wire [1:0] practice_mode,
    input wire backing_enabled,
    input wire load_we,
    input wire [7:0] load_addr,
    input wire [6:0] load_note,
    input wire [3:0] load_length,
    input wire load_commit,
    input wire [7:0] load_count,
    input wire [7:0] load_bpm,
    output reg lcd_de,
    output reg [5:0] lcd_r, lcd_g, lcd_b,
    output reg [7:0] frame_count,
    output wire [43:0] audio_control,
    // 音游判定信号引出（原内部信号，不影响既有显示/跟弹逻辑）
    output wire       o_game_playing,
    output wire       o_game_ready,
    output wire [6:0] o_game_note,
    output wire [10:0] o_game_token,
    output wire       o_game_advance,
    output wire       o_game_wrong,
    output wire [31:0] o_game_mask,
    // 音游 HUD 回灌：顶层 rhythm_judge 的判定结果送回渲染器画到屏上。
    // 全部是 pixel_clk 域的持续电平（不是脉冲），可以直接连。
    input  wire        i_game_enable,
    input  wire [1:0]  i_game_judge,
    input  wire [5:0]  i_game_judge_hold,
    input  wire [7:0]  i_game_combo,
    input  wire [7:0]  i_game_best_combo,
    input  wire [31:0] i_game_score_bcd,
    input  wire [7:0]  i_game_pf,
    input  wire [7:0]  i_game_gd,
    input  wire [7:0]  i_game_ms,
    // 实时波形示波器：audio_wave_scope 的 25 bit 载荷，
    // 已经由顶层 u_wave_mailbox 同步到 pixel_clk 域，这里只做直通。
    input  wire [24:0] wave_mail,
    // 实时频谱：audio_spectrum_goertzel 的 14 bit 载荷
    //   {toggle[13], bin[12:8], level[7:0]}，已由 u_spec_mailbox 同步到本域
    input  wire [13:0] spec_mail,
    // 双通道李萨如：audio_lissajous_scope 的 16 bit 载荷
    //   {toggle[15], quiet[14], x[13:7], y[6:0]}，已由 u_liss_mailbox 同步到本域
    input  wire [15:0] liss_mail,
    // 现场验证档位（顶层 pixel_clk 域寄存器，直接送入渲染器）
    input  wire [1:0]  fx_mode,
    input  wire [2:0]  test_sel
);
    wire [4:0] showcase_stage=showcase_config[20:16];
    reg [4:0] last_showcase_stage;
    reg [2:0] manual_page; reg manual_page_active;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin last_showcase_stage<=31;manual_page<=0;manual_page_active<=0;end
        else begin
            last_showcase_stage<=showcase_stage;
            if(showcase_stage!=last_showcase_stage) manual_page_active<=0;
            else if(next_mode) begin
                manual_page_active<=1;
                if(manual_page_active) manual_page <= manual_page==6 ? 0 : manual_page+1'b1;
                else manual_page <= showcase_config[15:13]==6 ? 0 : showcase_config[15:13]+1'b1;
            end
        end
    end
    localparam H_TOTAL=H_ACTIVE+H_BACK+H_FRONT;
    localparam V_TOTAL=V_ACTIVE+V_BACK+V_FRONT;
    localparam [11:0] H_BACK_VALUE=H_BACK;
    localparam [11:0] V_BACK_VALUE=V_BACK;
    reg [11:0] h_count, v_count;
    wire active=(h_count>=H_BACK && h_count<H_BACK+H_ACTIVE &&
                 v_count>=V_BACK && v_count<V_BACK+V_ACTIVE);
    wire [11:0] x=h_count-H_BACK_VALUE;
    wire [11:0] y=v_count-V_BACK_VALUE;
    wire frame_tick=(h_count==H_TOTAL-1 && v_count==V_TOTAL-1);
    reg [3:0] snapshot_delay;
    reg demo_enabled;
    wire [55:0] raw_notes;
    wire [31:0] raw_lengths;
    wire [2:0] raw_slot;
    wire [7:0] raw_ticks_left;      // 下落式音游：当前音符剩余 tick
    wire [7:0] raw_page, raw_bpm;
    wire [6:0] raw_progress;
    wire [23:0] raw_guide;
    wire [6:0] raw_midi_note;
    wire raw_playing;
    wire [1:0] practice=ENABLE_GUIDANCE ? practice_mode : 2'd0;
    wire backing=ENABLE_GUIDANCE ? backing_enabled : 1'b0;
    reg [1:0] previous_practice;
    wire practice_changed=(practice!=previous_practice);
    wire [6:0] target_midi_note;
    wire target_ready,completed,matched_advance,wrong_note,unsupported;
    wire [31:0] target_mask;
    wire [15:0] hits,errors;
    reg [5:0] wrong_frames;
    wire raw_imported;
    wire [2:0] raw_mode;
    wire [1:0] raw_instrument, raw_preset;
    wire [2:0] raw_song;
    wire song_list=(raw_mode==2'd3);
    wire list_starts_audition=song_list && toggle_play && !demo_enabled && practice==0;
    reg [55:0] view_notes;
    reg [31:0] view_lengths;
    reg [2:0] view_slot;
    reg [7:0] view_ticks_left;      // 与 view_slot 同拍寄存，保证位置与序号一致
    reg [7:0] view_page, view_bpm;
    reg [6:0] view_progress, view_expression;
    reg [23:0] view_guide;
    reg [31:0] view_pressed;
    reg view_playing, view_demo;
    reg [1:0] view_timbre;
    reg [2:0] view_mode;
    reg [1:0] view_instrument;
    reg view_imported;
    reg [2:0] view_song, view_online;
    reg [4:0] view_volume;
    reg view_volume_edit;
    reg [1:0] view_practice,view_upper_guide;
    reg view_backing,view_completed,view_unsupported,view_wrong;
    reg [6:0] view_target_note;
    reg [7:0] view_hits,view_errors;
    wire [17:0] color;
    wire renderer_de;
    reg [7:0] audio_previous_page;
    reg [2:0] audio_previous_slot;
    reg audio_previous_playing;
    reg [17:0] audio_gap_count;
    wire audio_event_changed=(raw_page!=audio_previous_page ||
        raw_slot!=audio_previous_slot || (raw_playing && !audio_previous_playing));
    wire [23:0] articulated_guide=(audio_event_changed || audio_gap_count!=0) ?
                                  24'd0 : raw_guide;
    wire [6:0] articulated_note=(audio_event_changed || audio_gap_count!=0) ?
                                 7'd0 : raw_midi_note;

    // A short release is required between identical consecutive score notes.
    // At 35 MHz this is 5 ms; the visual score guide remains continuous.
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin
            audio_previous_page<=0;audio_previous_slot<=0;
            audio_previous_playing<=0;audio_gap_count<=0;
        end else begin
            audio_previous_page<=raw_page;audio_previous_slot<=raw_slot;
            audio_previous_playing<=raw_playing;
            if(audio_event_changed) audio_gap_count<=AUDIO_NOTE_GAP_CYCLES;
            else if(audio_gap_count!=0) audio_gap_count<=audio_gap_count-1'b1;
        end
    end

    ui_view_state u_views(
        .clk(pixel_clk),.reset_n(reset_n),.next_mode(next_mode),
        .next_family(next_instrument),.next_preset(next_timbre && !song_list),
        .ui_mode(raw_mode),.instrument(raw_instrument),.preset(raw_preset)
    );
    score_transport #(.FRAME_HZ(FRAME_HZ),.ENABLE_GUIDANCE(ENABLE_GUIDANCE)) u_transport(
        .clk(pixel_clk),.reset_n(reset_n),
        .frame_tick(frame_tick && (demo_enabled || practice!=0 || backing)),
        .toggle_play(toggle_play && !list_starts_audition),
        .restart(restart || list_starts_audition || (SHOWCASE!=0 && showcase_stage!=last_showcase_stage && (showcase_stage==0 || showcase_stage==18 || showcase_stage==24))),.next_timbre(1'b0),
        .next_song(next_song || (song_list && next_timbre) || (SHOWCASE!=0 && showcase_stage==22 && frame_tick && frame_count[7:0]==0)),.pause_request(toggle_demo || practice_changed),
        .step_mode(practice==2 && !demo_enabled),.step_advance(matched_advance),
        .target_midi_note(target_midi_note),.target_ready(target_ready),.completed(completed),
        .load_we(load_we),.load_addr(load_addr),.load_note(load_note),
        .load_length(load_length),.load_commit(load_commit),
        .load_count(load_count),.load_bpm(load_bpm),
        .score_notes(raw_notes),.score_lengths(raw_lengths),
        .active_slot(raw_slot),.page_index(raw_page),.progress(raw_progress),
        .ticks_left(raw_ticks_left),
        .guide(raw_guide),.current_midi_note(raw_midi_note),
        .playing(raw_playing),.timbre(),.bpm(raw_bpm),
        .imported_score(raw_imported),.song_id(raw_song)
    );
    // 与 transport 出口那一拍对齐：target_midi_note/target_ready 现已寄存，
    // token 必须同样晚一拍。否则换音瞬间 rhythm_judge 会在 token_changed
    // 那一拍拿到**上一个音的 target_mask**，把还按着旧键的手误判成命中。
    reg [10:0] target_token_q;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) target_token_q <= 11'd0;
        else         target_token_q <= {raw_page,raw_slot};
    end
    generate if(ENABLE_GUIDANCE)begin: GUIDANCE
        score_note_matcher u_matcher(
            .clk(pixel_clk),.reset_n(reset_n),.enable(raw_playing && !demo_enabled && practice!=0),
            .online(input_online[2]),
            .resync(toggle_play || toggle_demo || restart || next_song || practice_changed ||
                    (song_list && next_timbre) || load_commit),
            .clear_stats(restart || next_song || practice_changed ||
                         (song_list && next_timbre) || load_commit || (completed && toggle_play)),
            .target_ready(target_ready),.target_midi_note(target_midi_note),
            .event_token(target_token_q),.pressed(external_pressed),
            .advance(matched_advance),.wrong_note(wrong_note),.unsupported(unsupported),
            .target_mask(target_mask),.hits(hits),.errors(errors));
    end else begin: NO_GUIDANCE
        assign matched_advance=0;assign wrong_note=0;assign unsupported=0;
        assign target_mask=0;assign hits=0;assign errors=0;
    end endgenerate
    // 音游判定引出：全部为既有信号的直连，不引入新逻辑、不改变原行为
    assign o_game_playing = raw_playing;
    assign o_game_ready   = target_ready;
    assign o_game_note    = target_midi_note;
    assign o_game_token   = target_token_q;
    assign o_game_advance = matched_advance;
    assign o_game_wrong   = wrong_note;
    assign o_game_mask    = target_mask;
    score_ui_renderer #(.REGISTER_FONT(1)) u_renderer(
        .showcase_active(SHOWCASE!=0),.showcase_stage(showcase_stage),.showcase_hold(showcase_config[21]),
        .pixel_clk(pixel_clk),.reset_n(reset_n),.display_de(renderer_de),
        .de(active),.x(x),.y(y),.pressed(view_pressed),.guide(view_guide),
        .score_notes(view_notes),.score_lengths(view_lengths),
        .active_slot(view_slot),.page_index(view_page),.progress(view_progress),
        .ticks_left(view_ticks_left),
        .playing(view_playing),.timbre(view_timbre),.bpm(view_bpm),
        .ui_mode(view_mode),.instrument(view_instrument),.imported_score(view_imported),
        .song_id(view_song),.input_online(view_online),
        .volume_step(view_volume),.volume_edit(view_volume_edit),
        .practice_mode(view_practice),.backing_enabled(view_backing),
        .target_note(view_target_note),.guide_hits(view_hits),.guide_errors(view_errors),
        .guide_completed(view_completed),.guide_unsupported(view_unsupported),
        .guide_wrong(view_wrong),.upper_guide(view_upper_guide),
        .expression(view_expression),.demo_mode(view_demo),.rgb666(color),
        .game_enable(i_game_enable),.game_judge(i_game_judge),
        .game_judge_hold(i_game_judge_hold),
        .game_combo(i_game_combo),.game_best_combo(i_game_best_combo),
        .game_score_bcd(i_game_score_bcd),
        .game_pf(i_game_pf),.game_gd(i_game_gd),.game_ms(i_game_ms),
        .wave_mail(wave_mail),.spec_mail(spec_mail),.liss_mail(liss_mail),
        .fx_mode(fx_mode),.test_sel(test_sel)
    );
    // Atomic mailbox to 50 MHz, not independent two-flop bus sampling.
    // Bits30:24 formerly carried an unused display expression. They now
    // carry the master volume step0..20; actual pressure display is separate.
    assign audio_control={articulated_note,raw_playing,demo_enabled,raw_instrument,raw_preset,
                          1'b0,backing,volume_step,articulated_guide};
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            h_count<=0; v_count<=0; frame_count<=0;
            lcd_de<=0; lcd_r<=0; lcd_g<=0; lcd_b<=0;
            snapshot_delay<=0; demo_enabled<=1;
            view_notes<={7'd62,7'd64,7'd65,7'd67,7'd67,7'd65,7'd64,7'd64};
            view_lengths<=32'h44444444;
            view_slot<=0; view_page<=0; view_progress<=0; view_bpm<=100;
            view_guide<=0; view_pressed<=0;
            view_expression<=64; view_playing<=0; view_demo<=1; view_timbre<=0;
            view_mode<=0; view_instrument<=0; view_imported<=0;
            view_song<=0; view_online<=0;
            view_volume<=12;view_volume_edit<=0;
            previous_practice<=0;wrong_frames<=0;
            view_practice<=0;view_backing<=0;view_completed<=0;
            view_ticks_left<=8'd0;
            view_unsupported<=0;view_wrong<=0;view_target_note<=0;
            view_hits<=0;view_errors<=0;view_upper_guide<=0;
        end else begin
            if (h_count==H_TOTAL-1) begin
                h_count<=0;
                if (v_count==V_TOTAL-1) begin
                    v_count<=0; frame_count<=frame_count+1'b1;
                end else v_count<=v_count+1'b1;
            end else h_count<=h_count+1'b1;
            previous_practice<=practice;
            if(practice_changed)demo_enabled<=0;
            else if (toggle_demo) demo_enabled<=~demo_enabled;
            else if (song_list && toggle_play && practice==0) demo_enabled<=1'b1;
            if(wrong_note)wrong_frames<=30;
            else if(frame_tick && wrong_frames!=0)wrong_frames<=wrong_frames-1'b1;
            // Synchronous song ROM takes 2 clocks; progress takes 8 clocks.
            // Snapshot after 10 clocks, wholly within vertical blanking.
            // Renderer inputs stay fixed throughout every active frame.
            if(frame_tick) snapshot_delay<=10;
            else if(snapshot_delay!=0) snapshot_delay<=snapshot_delay-1'b1;
            if (snapshot_delay==1) begin
                view_notes<=raw_notes; view_lengths<=raw_lengths;
                view_slot<=raw_slot; view_page<=raw_page;
                view_ticks_left<=raw_ticks_left;
                view_progress<=raw_progress; view_bpm<=raw_bpm;
                view_guide<=(demo_enabled || practice!=0) ? raw_guide : 24'd0; view_playing<=raw_playing;
                view_timbre<=SHOWCASE!=0 ? showcase_config[10:9] : raw_preset; view_demo<=SHOWCASE!=0 ? 1'b1 : demo_enabled;
                view_mode<=SHOWCASE!=0 ? (manual_page_active ? manual_page : showcase_config[15:13]) : raw_mode; view_instrument<=SHOWCASE!=0 ? showcase_config[12:11] : raw_instrument; view_imported<=raw_imported;
                view_song<=raw_song; view_online<=input_online;
                view_volume<=volume_step;view_volume_edit<=volume_edit;
                view_practice<=practice;view_backing<=backing;view_completed<=completed;
                view_target_note<=target_ready ? target_midi_note : 7'd0;
                view_hits<=hits>255 ? 8'd255 : hits[7:0];
                view_errors<=errors>255 ? 8'd255 : errors[7:0];
                view_unsupported<=unsupported;view_wrong<=wrong_frames!=0;
                view_upper_guide<=(demo_enabled || practice!=0) && raw_playing && target_ready ?
                    {target_midi_note==86,target_midi_note==84} : 2'd0;
                // Automatic score guidance must not impersonate live touches.
                view_pressed<=(SHOWCASE!=0 || !demo_enabled) ? external_pressed : 32'd0;
                view_expression<=SHOWCASE!=0 ? external_expression : (demo_enabled ? (raw_playing ? 7'd84 : 7'd0) : external_expression);
            end
            // Four renderer stages (balanced painter, selection, font address,
            // BSRAM), then this output FF: five pixel cycles, DE matched.
            // Inverted exported clock still gives the panel a half-cycle.
            lcd_de<=renderer_de;
            if (renderer_de) {lcd_r,lcd_g,lcd_b}<=color;
            else {lcd_r,lcd_g,lcd_b}<=18'd0;
        end
    end
endmodule
