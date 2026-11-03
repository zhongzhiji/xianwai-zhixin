`timescale 1ns/1ps
// Display-only pressure normalization; it does not change gates or audio.
// Default2048 uses one measured channel's normal-firm span plus headroom.
// This is an adjustable raw-code display range, not grams or16-key calibration.
module pressure_display_mapper #(
    parameter [23:0] FULL_SCALE = 24'd2048
)(
    input wire clk, reset_n, online,
    input wire [23:0] deviation,
    output reg [6:0] level
);
    reg [23:0] sample;
    reg [24:0] remainder;
    reg [6:0] quotient;
    reg [2:0] bit_index;
    reg busy;
    wire [24:0] shifted = remainder << 1;
    wire subtract = shifted >= {1'b0, FULL_SCALE};
    wire [24:0] next_remainder = subtract ?
        shifted - {1'b0, FULL_SCALE} : shifted;
    wire [6:0] next_quotient = {quotient[5:0], subtract};

    // Seven one-clock fractional steps find floor(deviation*128/FULL_SCALE).
    // Subtract one iff the remainder is smaller than deviation to obtain
    // exactly floor(deviation*127/FULL_SCALE), without a variable divide or
    // a seven-stage combinational compare/subtract chain.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            level <= 0;
            sample <= 0;
            remainder <= 0;
            quotient <= 0;
            bit_index <= 0;
            busy <= 0;
        end else if (!online || FULL_SCALE == 0) begin
            level <= 0;
            sample <= 0;
            remainder <= 0;
            quotient <= 0;
            bit_index <= 0;
            busy <= 0;
        end else if (deviation == 0) begin
            level <= 0;
            sample <= 0;
            busy <= 0;
        end else if (deviation != sample) begin
            sample <= deviation;
            if (deviation >= FULL_SCALE) begin
                level <= 127;
                busy <= 0;
            end else begin
                remainder <= {1'b0, deviation};
                quotient <= 0;
                bit_index <= 6;
                busy <= 1;
            end
        end else if (busy) begin
            remainder <= next_remainder;
            quotient <= next_quotient;
            if (bit_index == 0) begin
                level <= next_remainder < {1'b0, sample} ?
                    next_quotient - 1'b1 : next_quotient;
                busy <= 0;
            end else bit_index <= bit_index - 1'b1;
        end
    end
endmodule
