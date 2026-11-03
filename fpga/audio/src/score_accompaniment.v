`timescale 1ns/1ps
// Two mathematical support voices following the articulated score melody:
// bass two octaves below, and a fifth above that bass. No recorded backing
// track, chord recognition, percussion or independent score transport.
module score_accompaniment(
    input wire clk,reset_n,sample_en,enable,note_gate,
    input wire [31:0] freq_word,
    output reg signed [15:0] pcm,
    output wire [1:0] voices_active,
    output wire clipped
);
    reg [31:0] retained_freq_word;
    wire [31:0] current_freq_word=freq_word!=0 ? freq_word : retained_freq_word;
    wire [31:0] bass_freq_word=current_freq_word>>2;
    wire [31:0] fifth_freq_word=(current_freq_word>>2)+(current_freq_word>>3);
    wire gate=enable && note_gate && freq_word!=0;
    wire signed [15:0] bass_sample,fifth_sample;
    timbre_voice #(.VOL_SHIFT(4)) u_bass(
        .clk(clk),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
        .gate(gate),.freq_word(bass_freq_word),.family(2'd1),.preset(2'd0),
        .sample(bass_sample),.active(voices_active[0]));
    timbre_voice #(.VOL_SHIFT(4)) u_fifth(
        .clk(clk),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
        .gate(gate),.freq_word(fifth_freq_word),.family(2'd2),.preset(2'd0),
        .sample(fifth_sample),.active(voices_active[1]));
    // Current wave tables bound each /16 voice to +/-1750. The 17-bit
    // registered sum preserves the sign even for out-of-bound fault inputs.
    reg signed [16:0] mixed_pcm;
    assign clipped=enable && (mixed_pcm>32767 || mixed_pcm< -32768);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            retained_freq_word<=0;mixed_pcm<=0;pcm<=0;
        end else begin
            // A zero input marks a rest: release envelopes continue at their
            // previous oscillator pitch rather than freezing the DDS phase.
            if(freq_word!=0)retained_freq_word<=freq_word;
            if(!enable)begin mixed_pcm<=0;pcm<=0;end
            else begin
                mixed_pcm<=$signed({bass_sample[15],bass_sample})+
                           $signed({fifth_sample[15],fifth_sample});
                if(mixed_pcm>32767)pcm<=32767;
                else if(mixed_pcm< -32768)pcm<=-32768;
                else pcm<=mixed_pcm[15:0];
            end
        end
    end
endmodule
