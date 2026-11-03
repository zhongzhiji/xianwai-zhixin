`timescale 1ns/1ps
// Reusable integration boundary: same baseline UART/frame/gate/serial modules,
// same C24 UART binding in top.cst. No conversion/truncation of raw24-bit input.
module fsr16_audio_wrapper #(
    parameter integer CLK_PER_BIT=434,DELTA_MIN=32,DELTA_OFF=16,TO_BITS=25,
    parameter integer LAYOUT=1,VOL_SHIFT=4,CHROMATIC_AUDITION=0,
    parameter integer PRESSURE_EXPRESSION=0,PRESSURE_SHIFT=2,CLEAN_OUTPUT=1
)(
    input wire clk50,reset_n,uart_rx,enable,auto_mode,
    input wire [15:0] external_note_gate,
    input wire external_freq_override,
    input wire [31:0] external_freq_word,
    input wire [1:0] family,preset,octave,
    input wire [4:0] volume_step,
    input wire backing_enabled,backing_gate,
    input wire [31:0] backing_freq_word,
    output wire HP_BCK,HP_WS,HP_DIN,
    output wire [383:0] pressure_raw,
    output wire [23:0] pressure_deviation,
    output wire frame_ok,protocol,
    output wire [15:0] pressure_gate,note_mask,note_on,note_off,voices_active,
    output wire signed [15:0] pcm,
    output wire [15:0] expression_smoothed,
    output wire clipped,frame_en
);
    wire [7:0] byte_data;
    wire byte_valid,bck,bck_rise,bck_fall;
    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_uart(
        .clk(clk50),.rst_n(reset_n),.rx(uart_rx),.data(byte_data),.valid(byte_valid));
    wax_frame u_frame(.clk(clk50),.rst_n(reset_n),.b(byte_data),.bvalid(byte_valid),
        .frame_ok(frame_ok),.proto(protocol),.vals(pressure_raw));
    fsr_gate #(.N(16),.DELTA_MIN(DELTA_MIN),.DELTA_OFF(DELTA_OFF),.TO_BITS(TO_BITS)) u_gate(
        .clk(clk50),.rst_n(reset_n),.new_frame(frame_ok),.vals(pressure_raw),
        .gate(pressure_gate),.dev_max(pressure_deviation));
    assign note_mask=auto_mode ? external_note_gate : pressure_gate;
    // Pressure gain is opt-in until raw scale is measured. Default127 preserves
    // existing note response/loudness; thresholds/base tracking are untouched.
    wire [24:0] mapped_expression=25'd32+(pressure_deviation>>PRESSURE_SHIFT);
    wire [6:0] expression=PRESSURE_EXPRESSION && !auto_mode ?
        (mapped_expression>127 ? 7'd127 : mapped_expression[6:0]) : 7'd127;
    clk_gen #(.ACC_MOD(50000),.ACC_STEP(3072)) u_clock(.clk(clk50),.rst_n(reset_n),
        .bck(bck),.bck_rise(bck_rise),.bck_fall(bck_fall));
    wire signed [15:0] raw_pcm;
    wire signed [15:0] master_pcm;
    wire engine_clipped,master_clipped,backing_clipped;
    wire signed [15:0] backing_pcm;
    wire [1:0] backing_voices;
    reg signed [16:0] combined_pcm;
    wire signed [15:0] bounded_mix=combined_pcm>32767 ? 16'sd32767 :
        combined_pcm< -32768 ? -16'sd32768 : combined_pcm[15:0];
    wire mix_clipped=enable && (combined_pcm>32767 || combined_pcm< -32768);
    fsr16_engine #(.LAYOUT(LAYOUT),.VOL_SHIFT(VOL_SHIFT),
        .CHROMATIC_AUDITION(CHROMATIC_AUDITION)) u_engine(
        .clk50(clk50),.reset_n(reset_n),.sample_en(frame_en),.enable(enable),
        .note_gate(note_mask),.family(family),.preset(preset),.octave(octave),.expression(expression),
        .freq_override(auto_mode && external_freq_override),.freq_override_word(external_freq_word),
        .pcm(raw_pcm),.voices_active(voices_active),.note_on(note_on),.note_off(note_off),
        .expression_smoothed(expression_smoothed),.clipped(engine_clipped),.voice_debug());
    audio_master_volume u_master_volume(
        .clk(clk50),.reset_n(reset_n),.sample_en(frame_en),.enable(enable),
        .pcm_in(bounded_mix),.voices_active({14'd0,backing_voices,voices_active}),.volume_step(volume_step),
        .pcm_out(master_pcm),.gain_q8(),.volume_smoothed(),.clipped(master_clipped));
    audio_output_filter #(.BYPASS(CLEAN_OUTPUT==0)) u_output_filter(
        .clk(clk50),.reset_n(reset_n),.sample_en(frame_en),.enable(enable),
        .pcm_in(master_pcm),.pcm_out(pcm));
    score_accompaniment u_backing(
        .clk(clk50),.reset_n(reset_n),.sample_en(frame_en),.enable(enable && backing_enabled),
        .note_gate(backing_gate),.freq_word(backing_freq_word),
        .pcm(backing_pcm),.voices_active(backing_voices),.clipped(backing_clipped));
    always @(posedge clk50 or negedge reset_n)
        if(!reset_n)combined_pcm<=0;
        else if(!enable)combined_pcm<=0;
        else combined_pcm<=$signed({raw_pcm[15],raw_pcm})+$signed({backing_pcm[15],backing_pcm});
    assign clipped=engine_clipped || master_clipped || backing_clipped || mix_clipped;
    i2s_tx u_serial(.clk(clk50),.rst_n(reset_n),.bck(bck),.bck_rise(bck_rise),
        .sample_l(pcm),.sample_r(pcm),.HP_BCK(HP_BCK),.HP_WS(HP_WS),.HP_DIN(HP_DIN),
        .req(),.frame_en(frame_en));
endmodule
