// Original working FSR16 UART/48kHz/16-voice path + warm-paper LCD/song list.
// Tang Mega 138K Pro 4071d C: pressure UART stays on verified C24.
module top_score_fsr16_ui #(
    parameter DEBOUNCE_CYCLES=350000,HOLD_CYCLES=21000000,
    parameter DISPLAY_PRESSURE_SHIFT=0, DISPLAY_PRESSURE_FULL_SCALE=2048
)(
    input wire sys_clk,rst_n,key_play_n,key_timbre_n,key_demo_n,pressure_rx,
    output wire lcd_clk,lcd_de,
    output wire [5:0] lcd_r,lcd_g,lcd_b,
    output wire [1:0] led_n,
    output wire hp_bck,hp_ws,hp_din,pa_en
);
    wire pixel_clk,locked,pixel_reset_n,system_reset_n;
    wire short_play,long_song,short_timbre,long_family,short_page,long_mode;
    wire [2:0] button_pressed,button_short,button_long,normal_short,normal_long;
    wire volume_edit;
    wire [4:0] volume_step;
    wire [1:0] practice_mode;
    wire backing_enabled;
    assign {short_page,short_timbre,short_play}=normal_short;
    assign {long_mode,long_family,long_song}=normal_long;
    wire [7:0] frame_count;
    wire [43:0] controls_pixel,controls_system;
    wire [15:0] live_gate,auto_gate;
    wire auto_note_gate;
    wire [31:0] auto_freq_word;
    wire [383:0] values;
    wire frame_ok,online;
    wire [23:0] dev_max;
    wire [111:0] levels;
    wire [39:0] inputs_pixel;
    wire [31:0] live_notes;
    // Normalize the displayed raw deviation only; note gating and audio gain
    // remain unchanged. Range2048 is one-key measured span plus headroom,
    // not a physical-force unit or a completed16-key calibration.
    wire [23:0] display_deviation=dev_max>>DISPLAY_PRESSURE_SHIFT;
    wire [6:0] expression;
    pressure_display_mapper #(.FULL_SCALE(DISPLAY_PRESSURE_FULL_SCALE)) u_pressure_display(
        .clk(sys_clk),.reset_n(system_reset_n),.online(online),
        .deviation(display_deviation),.level(expression));
    reg live_armed;
    wire enabled=controls_system[36];
    wire demo_mode=controls_system[35];
    lcd_pll u_pll(.clkin(sys_clk),.clkout0(pixel_clk),.locked(locked));
    reset_sync u_pixel_reset(.clk(pixel_clk),.reset_button_n(rst_n & locked),.reset_n(pixel_reset_n));
    reset_sync u_system_reset(.clk(sys_clk),.reset_button_n(rst_n & locked),.reset_n(system_reset_n));
    ui_action_button #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.HOLD_CYCLES(HOLD_CYCLES)) u_s1(
        .clk(pixel_clk),.reset_n(pixel_reset_n),.button_n(key_play_n),
        .short_press(button_short[0]),.long_press(button_long[0]),.pressed(button_pressed[0]));
    ui_action_button #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.HOLD_CYCLES(HOLD_CYCLES)) u_s2(
        .clk(pixel_clk),.reset_n(pixel_reset_n),.button_n(key_timbre_n),
        .short_press(button_short[1]),.long_press(button_long[1]),.pressed(button_pressed[1]));
    ui_action_button #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.HOLD_CYCLES(HOLD_CYCLES)) u_s3(
        .clk(pixel_clk),.reset_n(pixel_reset_n),.button_n(key_demo_n),
        .short_press(button_short[2]),.long_press(button_long[2]),.pressed(button_pressed[2]));
    ui_volume_control #(.HOLD_CYCLES(HOLD_CYCLES)) u_volume_controls(
        .clk(pixel_clk),.reset_n(pixel_reset_n),.pressed(button_pressed),
        .short_action(button_short),.long_action(button_long),
        .normal_short(normal_short),.normal_long(normal_long),
        .volume_edit(volume_edit),.volume_step(volume_step),
        .practice_mode(practice_mode),.backing_enabled(backing_enabled));
    function integer pitch_index;
        input integer channel;
        begin case(channel)
            0:pitch_index=0;1:pitch_index=2;2:pitch_index=4;3:pitch_index=5;
            4:pitch_index=7;5:pitch_index=9;6:pitch_index=11;7:pitch_index=12;
            8:pitch_index=14;9:pitch_index=16;10:pitch_index=17;11:pitch_index=19;
            12:pitch_index=21;13:pitch_index=23;14:pitch_index=24;15:pitch_index=26;
            default:pitch_index=0;
        endcase end
    endfunction
    assign live_notes=({31'd0,live_gate[0]}<<0)|({31'd0,live_gate[1]}<<2)|
        ({31'd0,live_gate[2]}<<4)|({31'd0,live_gate[3]}<<5)|
        ({31'd0,live_gate[4]}<<7)|({31'd0,live_gate[5]}<<9)|
        ({31'd0,live_gate[6]}<<11)|({31'd0,live_gate[7]}<<12)|
        ({31'd0,live_gate[8]}<<14)|({31'd0,live_gate[9]}<<16)|
        ({31'd0,live_gate[10]}<<17)|({31'd0,live_gate[11]}<<19)|
        ({31'd0,live_gate[12]}<<21)|({31'd0,live_gate[13]}<<23)|
        ({31'd0,live_gate[14]}<<24)|({31'd0,live_gate[15]}<<26);
    // Automatic listening is a single melody at its actual MIDI C3-B6 pitch.
    // Manual playing retains the original independent16 natural-note voices.
    chromatic_audition #(.DIRECT_MIDI(1)) u_audition_pitch(
        .clk50(sys_clk),.reset_n(system_reset_n),
        .notes(controls_system[23:0]),.midi_note(controls_system[43:37]),
        .gate(auto_note_gate),.freq_word(auto_freq_word));
    assign auto_gate={15'd0,auto_note_gate};
    always @(posedge sys_clk or negedge system_reset_n) begin
        if(!system_reset_n) live_armed<=0;
        else if(!enabled || demo_mode || !online) live_armed<=0;
        else if(live_gate==0) live_armed<=1;
    end
    fsr16_uart_engine #(.CHROMATIC_AUDITION(1)) u_audio(
        .clk50(sys_clk),.rst_n(system_reset_n),.uart_rx(pressure_rx),
        .enable(enabled && (demo_mode || live_armed || controls_system[29])),.demo_mode(demo_mode),
        .family(controls_system[34:33]),.preset(controls_system[32:31]),.octave(2'd1),
        .volume_step(controls_system[28:24]),
        .backing_enabled(controls_system[29]),.backing_gate(auto_note_gate),
        .backing_freq_word(auto_freq_word),
        .external_gate(auto_gate),.external_freq_override(demo_mode),
        .external_freq_word(auto_freq_word),
        .HP_BCK(hp_bck),.HP_WS(hp_ws),.HP_DIN(hp_din),.PA_EN(pa_en),
        .live_gate(live_gate),.values(values),.frame_ok(frame_ok),.online(online),
        .dev_max(dev_max),.levels(levels),.pcm(),.sample_en(),
        .note_on(),.note_off(),.voices_active(),.clipped());
    bus_snapshot_cdc #(.WIDTH(40)) u_input_mailbox(
        .src_clk(sys_clk),.src_reset_n(system_reset_n),.src_data({online,expression,live_notes}),
        .dst_clk(pixel_clk),.dst_reset_n(pixel_reset_n),.dst_data(inputs_pixel));
    bus_snapshot_cdc #(.WIDTH(44)) u_control_mailbox(
        .src_clk(pixel_clk),.src_reset_n(pixel_reset_n),.src_data(controls_pixel),
        .dst_clk(sys_clk),.dst_reset_n(system_reset_n),.dst_data(controls_system));
    score_display_core #(.ENABLE_GUIDANCE(1)) u_display(
        .pixel_clk(pixel_clk),.reset_n(pixel_reset_n),.toggle_play(short_play),.next_song(long_song),
        .restart(1'b0),.next_timbre(short_timbre),.toggle_demo(long_mode),
        .next_mode(short_page),.next_instrument(long_family),
        .volume_step(volume_step),.volume_edit(volume_edit),
        .practice_mode(practice_mode),.backing_enabled(backing_enabled),
        .external_pressed(inputs_pixel[31:0]),.external_expression(inputs_pixel[38:32]),
        .input_online({inputs_pixel[39],2'b00}),
        .load_we(1'b0),.load_addr(6'd0),.load_note(7'd0),.load_length(4'd0),
        .load_commit(1'b0),.load_count(7'd0),.load_bpm(8'd100),
        .lcd_de(lcd_de),.lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),
        .frame_count(frame_count),.audio_control(controls_pixel));
    assign lcd_clk=~pixel_clk;
    assign led_n={~frame_count[5],~online};
endmodule
