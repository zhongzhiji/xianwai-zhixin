`timescale 1ns/1ps
// Original fixed-point unity-DC three-tap FIR, H(z)=(1+2z^-1+z^-2)/4.
// 48 kHz: ideal group delay 1 sample (20.833 us), zero at Nyquist.
// This is spectral smoothing, NOT noise cancellation or instrument modelling.
// Reference concept: STK OneZero unity-gain normalization (no code copied).
module audio_output_filter #(
    parameter integer BYPASS = 0
)(
    input wire clk,reset_n,sample_en,enable,
    input wire signed [15:0] pcm_in,
    output reg signed [15:0] pcm_out
);
    reg signed [15:0] previous1,previous2;
    wire signed [17:0] x0={{2{pcm_in[15]}},pcm_in};
    wire signed [17:0] x1={{2{previous1[15]}},previous1};
    wire signed [17:0] x2={{2{previous2[15]}},previous2};
    // Convex weights guarantee full-scale inputs cannot overflow the output.
    wire signed [17:0] weighted=x0+(x1<<<1)+x2;
    // Nearest integer; ties away from zero, symmetric for signed input.
    wire signed [17:0] rounded=weighted+(weighted<0 ? 18'sd1 : 18'sd2);
    wire signed [17:0] filtered=rounded>>>2;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin previous1<=0;previous2<=0;pcm_out<=0;end
        else if(!enable)begin previous1<=0;previous2<=0;pcm_out<=0;end
        else if(sample_en)begin
            previous1<=pcm_in;previous2<=previous1;
            pcm_out<=BYPASS!=0 ? pcm_in : filtered[15:0];
        end
    end
endmodule
