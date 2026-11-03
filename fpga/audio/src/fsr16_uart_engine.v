`timescale 1ns/1ps
// Fixed clk50 integration boundary for LCD/pressure/audio. Signal names are
// deliberately independent of the standalone demo top; C24 binding is in CST.
// levels is a binary-trigger engineering indicator, NOT calibrated force.
module fsr16_uart_engine #(
    parameter integer CLK_PER_BIT=434,DELTA_MIN=32,DELTA_OFF=16,TO_BITS=25,
    parameter integer LAYOUT=1,VOL_SHIFT=4,CHROMATIC_AUDITION=0,
    parameter integer PRESSURE_EXPRESSION=0,PRESSURE_SHIFT=2
)(
    input wire clk50,rst_n,uart_rx,enable,demo_mode,
    input wire [1:0] family,preset,octave,
    input wire [4:0] volume_step,
    input wire backing_enabled,backing_gate,
    input wire [31:0] backing_freq_word,
    input wire [15:0] external_gate,
    input wire external_freq_override,
    input wire [31:0] external_freq_word,
    output wire HP_BCK,HP_WS,HP_DIN,PA_EN,
    output wire [15:0] live_gate,note_on,note_off,voices_active,
    output wire [383:0] values,
    output wire frame_ok,online,
    output wire [23:0] dev_max,
    output wire signed [15:0] pcm,
    output wire sample_en,clipped,
    output wire [111:0] levels
);
    reg [TO_BITS-1:0] watchdog;
    reg seen_frame;
    reg live_armed;
    wire [15:0] selected_mask;
    wire [15:0] expression_smoothed;
    wire protocol;
    assign online=seen_frame && !(&watchdog);
    always @(posedge clk50 or negedge rst_n) begin
        if(!rst_n) begin watchdog<=0;seen_frame<=0;live_armed<=0;end
        else begin
            if(frame_ok) begin watchdog<=0;seen_frame<=1;end
            else if(!(&watchdog)) watchdog<=watchdog+1'b1;
            // Re-entering live mode while a pad is held must not create an
            // unexpected note. Require all pads released once after enable.
            if(!enable || demo_mode || !online) live_armed<=0;
            else if(live_gate==0) live_armed<=1;
        end
    end
    fsr16_audio_wrapper #(.CLK_PER_BIT(CLK_PER_BIT),.DELTA_MIN(DELTA_MIN),
        .DELTA_OFF(DELTA_OFF),.TO_BITS(TO_BITS),.LAYOUT(LAYOUT),.VOL_SHIFT(VOL_SHIFT),
        .CHROMATIC_AUDITION(CHROMATIC_AUDITION),
        .PRESSURE_EXPRESSION(PRESSURE_EXPRESSION),.PRESSURE_SHIFT(PRESSURE_SHIFT)) u_audio(
        .clk50(clk50),.reset_n(rst_n),.uart_rx(uart_rx),.enable(enable),
        .auto_mode(demo_mode || !live_armed),
        .external_note_gate(demo_mode ? external_gate : 16'd0),
        .external_freq_override(demo_mode && external_freq_override),
        .external_freq_word(external_freq_word),
        .family(family),.preset(preset),.octave(octave),.volume_step(volume_step),
        .backing_enabled(backing_enabled),.backing_gate(backing_gate),.backing_freq_word(backing_freq_word),
        .HP_BCK(HP_BCK),.HP_WS(HP_WS),.HP_DIN(HP_DIN),.pressure_raw(values),
        .pressure_deviation(dev_max),.frame_ok(frame_ok),.protocol(protocol),
        .pressure_gate(live_gate),.note_mask(selected_mask),.note_on(note_on),
        .note_off(note_off),.voices_active(voices_active),.pcm(pcm),
        .expression_smoothed(expression_smoothed),.clipped(clipped),.frame_en(sample_en));
    assign PA_EN=rst_n;
    genvar i;
    generate for(i=0;i<16;i=i+1) begin: LEVEL
        assign levels[i*7+:7]=live_gate[i] ? 7'd64 : 7'd0;
    end endgenerate
endmodule
