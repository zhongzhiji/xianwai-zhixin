`timescale 1ns/1ps
// Autonomous, explicitly labelled test stimuli. No sensor input is fabricated.
// S1 freezes the scene clock, while music and audio sample clocks keep running.
// S2 skips; long S2 restarts. All audio remains DDS/ADSR hardware synthesis.
module showcase_director #(
    parameter integer CLK_HZ=50000000,
    parameter integer TICK_HZ=50
)(
    input wire clk,reset_n,pause_press,next_press,restart_press,
    output reg [4:0] stage,
    output reg held,
    output reg [15:0] gate,
    output reg [6:0] expression,
    output reg [1:0] family,preset,fx,
    output reg [2:0] page,test_sel,
    output reg [3:0] vib_depth,
    output reg glide,melody,backing,
    output reg [31:0] freq_word
);
    localparam integer DIV=CLK_HZ/TICK_HZ;
    reg [31:0] divider;
    reg [5:0] tick,seconds;
    reg [5:0] dwell;
    wire [2:0] beat=seconds[2:0];
    always @* begin
        dwell=24;
        case(stage)
            0:dwell=18;8:dwell=16;
            9,10,11,14,15,16:dwell=20;
            17:dwell=25;
            20,21,23,24:dwell=30;
            25:dwell=45;
            default:dwell=24;
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin divider<=0;tick<=0;seconds<=0;stage<=0;held<=0;end
        else if(restart_press) begin divider<=0;tick<=0;seconds<=0;stage<=0;held<=0;end
        else begin
            if(pause_press) held<=~held;
            if(next_press) begin divider<=0;tick<=0;seconds<=0;stage<=stage==25 ? 0 : stage+1'b1;end
            else if(!held) begin
                if(divider==DIV-1) begin
                    divider<=0;
                    if(tick==TICK_HZ-1) begin
                        tick<=0;
                        if(seconds==dwell-1) begin seconds<=0;stage<=stage==25 ? 0 : stage+1'b1;end
                        else seconds<=seconds+1'b1;
                    end else tick<=tick+1'b1;
                end else divider<=divider+1'b1;
            end
        end
    end
    // 12 banks retain independent phase and envelope state in each voice.
    always @* begin
        gate=16'h0001;expression=100;family=0;preset=0;fx=0;page=1;
        test_sel=0;vib_depth=0;glide=0;melody=0;backing=0;
        freq_word=32'd23409859; // C4 at 48 kHz (rounded DDS increment)
        case(stage)
            0:begin melody=1;page=0;backing=1;end
            1:begin
                family=2;
                case(seconds[2:0])
                    0:expression=32;1:expression=48;2:expression=64;3:expression=80;
                    4:expression=96;5:expression=112;6:expression=127;default:expression=64;
                endcase
            end
            2:begin gate=16'h0001<<beat;end
            3:begin
                case(beat)
                    0:gate=16'h0001;1:gate=16'h0005;2:gate=16'h0015;3:gate=16'h0095;
                    4:gate=16'h0094;5:gate=16'h0090;6:gate=16'h0080;default:gate=0;
                endcase
            end
            4,5,6,7:begin
                family=stage-4;preset=seconds<8 ? 0 : seconds<16 ? 1 : 2;page=2;
                case(seconds[1:0]) 0:gate=1;1:gate=4;2:gate=16;3:gate=128;endcase
                if(tick>=40)gate=0;
            end
            8,9,10,11:begin
                fx=stage-8;page=4;family=1;
                gate=(!seconds[0] && tick<12) ? 16'h0095 : 0;
            end
            12:begin
                page=4;family=2;glide=1;
                // Constant note gate, frequency target changes every two seconds.
                case(seconds[2:1])
                    0:freq_word=23409859;1:freq_word=26276679;
                    2:freq_word=29494575;default:freq_word=35075158;
                endcase
            end
            13:begin page=4;family=2;vib_depth=12;end
            14,15,16,17:begin page=5;test_sel=stage-13;family=2;end
            18:begin page=4;melody=1;end
            19:begin page=5;melody=1;end
            20:begin page=6;melody=1;backing=1;family=2;end
            21:begin page=0;melody=1;backing=1;end
            22:begin page=3;melody=1;end
            23:begin page=3;melody=1;end
            24,25:begin page=0;melody=1;end
            default:begin gate=0;end
        endcase
    end
endmodule
