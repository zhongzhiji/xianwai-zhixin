`timescale 1ns/1ps
// Registered monophonic guide-to-DDS decoder. C4-B5 includes all 24 semitones.
// The displayed/imported score is a single melody. If a malformed guide has
// several bits set, audition deterministically chooses the lowest pitch.
// Two clk50 cycles keep the priority encoder and constant table separate.
module chromatic_audition #(parameter DIRECT_MIDI=0)(
    input wire clk50,reset_n,
    input wire [23:0] notes,
    input wire [6:0] midi_note,
    output reg gate,
    output reg [31:0] freq_word
);
    reg [4:0] pitch_q;
    reg valid_q;
    reg [6:0] midi_q;
    function [2:0] lowest_octet;
        input [7:0] bits;
        begin
            casez(bits)
                8'b???????1:lowest_octet=0;
                8'b??????10:lowest_octet=1;
                8'b?????100:lowest_octet=2;
                8'b????1000:lowest_octet=3;
                8'b???10000:lowest_octet=4;
                8'b??100000:lowest_octet=5;
                8'b?1000000:lowest_octet=6;
                default:lowest_octet=7;
            endcase
        end
    endfunction
    // Direct melody input avoids forcing a low guitar note into a visible
    // keyboard octave. C3-B6 is played at its actual equal-tempered pitch.
    function [31:0] phase_of_midi;
        input [6:0] midi;
        begin
            case(midi)
                48:phase_of_midi=11704930;49:phase_of_midi=12400941;
                50:phase_of_midi=13138339;51:phase_of_midi=13919586;
                52:phase_of_midi=14747287;53:phase_of_midi=15624207;
                54:phase_of_midi=16553270;55:phase_of_midi=17537579;
                56:phase_of_midi=18580418;57:phase_of_midi=19685267;
                58:phase_of_midi=20855814;59:phase_of_midi=22095965;
                60:phase_of_midi=23409859;61:phase_of_midi=24801882;
                62:phase_of_midi=26276679;63:phase_of_midi=27839171;
                64:phase_of_midi=29494575;65:phase_of_midi=31248413;
                66:phase_of_midi=33106541;67:phase_of_midi=35075158;
                68:phase_of_midi=37160835;69:phase_of_midi=39370534;
                70:phase_of_midi=41711627;71:phase_of_midi=44191930;
                72:phase_of_midi=46819719;73:phase_of_midi=49603764;
                74:phase_of_midi=52553357;75:phase_of_midi=55678342;
                76:phase_of_midi=58989149;77:phase_of_midi=62496826;
                78:phase_of_midi=66213081;79:phase_of_midi=70150316;
                80:phase_of_midi=74321671;81:phase_of_midi=78741067;
                82:phase_of_midi=83423255;83:phase_of_midi=88383859;
                84:phase_of_midi=93639437;85:phase_of_midi=99207528;
                86:phase_of_midi=105106715;87:phase_of_midi=111356685;
                88:phase_of_midi=117978298;89:phase_of_midi=124993653;
                90:phase_of_midi=132426162;91:phase_of_midi=140300631;
                92:phase_of_midi=148643341;93:phase_of_midi=157482134;
                94:phase_of_midi=166846509;95:phase_of_midi=176767719;
                default:phase_of_midi=0;
            endcase
        end
    endfunction
    // Identical values to original note_freq.vh; regression independently
    // verifies round(440 * 2**((MIDI-69)/12) * 2**32 / 48000), A4=440 Hz.
    function [31:0] phase_of;
        input [4:0] pitch;
        begin
            case(pitch)
                0:phase_of=32'd23409859;1:phase_of=32'd24801882;
                2:phase_of=32'd26276679;3:phase_of=32'd27839171;
                4:phase_of=32'd29494575;5:phase_of=32'd31248413;
                6:phase_of=32'd33106541;7:phase_of=32'd35075158;
                8:phase_of=32'd37160835;9:phase_of=32'd39370534;
                10:phase_of=32'd41711627;11:phase_of=32'd44191930;
                12:phase_of=32'd46819719;13:phase_of=32'd49603764;
                14:phase_of=32'd52553357;15:phase_of=32'd55678342;
                16:phase_of=32'd58989149;17:phase_of=32'd62496826;
                18:phase_of=32'd66213081;19:phase_of=32'd70150316;
                20:phase_of=32'd74321671;21:phase_of=32'd78741067;
                22:phase_of=32'd83423255;23:phase_of=32'd88383859;
                default:phase_of=0;
            endcase
        end
    endfunction
    always @(posedge clk50 or negedge reset_n) begin
        if(!reset_n)begin pitch_q<=0;midi_q<=0;valid_q<=0;gate<=0;freq_word<=0;end
        else begin
            valid_q<=DIRECT_MIDI ? (midi_note>=48 && midi_note<=95) : |notes;
            midi_q<=midi_note;
            if(|notes[7:0])pitch_q<={2'b00,lowest_octet(notes[7:0])};
            else if(|notes[15:8])pitch_q<={2'b01,lowest_octet(notes[15:8])};
            else pitch_q<={2'b10,lowest_octet(notes[23:16])};
            gate<=valid_q;
            // A rest releases the ADSR but must not freeze its oscillator.
            // Keep the last pitch so the release tail remains alternating
            // audio instead of an artificial DC tail at a fixed ROM sample.
            if(valid_q)freq_word<=DIRECT_MIDI ? phase_of_midi(midi_q) : phase_of(pitch_q);
        end
    end
endmodule
