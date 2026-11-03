`timescale 1ns/1ps
// Master gain for the existing /16 voice mix. A solo voice can use the DAC
// range; up to18 overlapping ADSR voices (including release tails) share16/N gain.
// The current ROM is bounded at +/-28000 and envelopes at32767, so even
// coherent peaks stay below28000. The signed final clamp is a fail-safe.
module audio_master_volume(
    input wire clk,reset_n,sample_en,enable,
    input wire signed [15:0] pcm_in,
    // 同时发声的声部数（按位给出）。32 位是为了覆盖 32 复音引擎；
    // 16 复音链路调用时高位补 0 即可，headroom 表对 0..32 都有定义。
    input wire [31:0] voices_active,
    input wire [4:0] volume_step,
    output reg signed [15:0] pcm_out,
    output wire [12:0] gain_q8,
    output reg [10:0] volume_smoothed,
    output wire clipped
);
    function [2:0] population4;
        input [3:0] bits;
        reg [1:0] a,b;
        begin a={1'b0,bits[0]}+bits[1];b={1'b0,bits[2]}+bits[3];
            population4={1'b0,a}+b;end
    endfunction
    // 32 位分成 8 组 4 位做 popcount，最多 32 个声部 → count 需要 6 位
    wire [3:0] count_0={1'b0,population4(voices_active[3:0])}+population4(voices_active[7:4]);
    wire [3:0] count_1={1'b0,population4(voices_active[11:8])}+population4(voices_active[15:12]);
    wire [3:0] count_2={1'b0,population4(voices_active[19:16])}+population4(voices_active[23:20]);
    wire [3:0] count_3={1'b0,population4(voices_active[27:24])}+population4(voices_active[31:28]);
    wire [5:0] count={2'd0,count_0}+{2'd0,count_1}+{2'd0,count_2}+{2'd0,count_3};
    reg [12:0] headroom;
    reg [10:0] volume_target;
    always @* begin
        // headroom = 4096 / N（N = 同时发声数），单声部给满量程、N 越大衰减越多
        case(count)
            0,1:headroom=4096;  2:headroom=2048;  3:headroom=1365;  4:headroom=1024;
            5:headroom=819;     6:headroom=682;   7:headroom=585;   8:headroom=512;
            9:headroom=455;    10:headroom=409;  11:headroom=372;  12:headroom=341;
            13:headroom=315;   14:headroom=292;  15:headroom=273;  16:headroom=256;
            17:headroom=240;   18:headroom=227;  19:headroom=215;  20:headroom=204;
            21:headroom=195;   22:headroom=186;  23:headroom=178;  24:headroom=170;
            25:headroom=163;   26:headroom=157;  27:headroom=151;  28:headroom=146;
            29:headroom=141;   30:headroom=136;  31:headroom=132;
            default:headroom=128;              // 32 个声部全开
        endcase
        // Round(step*1024/20), without an inferred variable divider.
        case(volume_step)
            0:volume_target=0;1:volume_target=51;2:volume_target=102;3:volume_target=154;
            4:volume_target=205;5:volume_target=256;6:volume_target=307;7:volume_target=358;
            8:volume_target=410;9:volume_target=461;10:volume_target=512;11:volume_target=563;
            12:volume_target=614;13:volume_target=666;14:volume_target=717;15:volume_target=768;
            16:volume_target=819;17:volume_target=870;18:volume_target=922;19:volume_target=973;
            default:volume_target=1024;
        endcase
    end
    reg [23:0] target_product;
    wire [12:0] desired_gain=target_product[22:10];
    reg [12:0] gain_state;
    // Fast headroom reduction prevents overload when another voice enters.
    // Recovery is limited to4/256 gain per sample, so releasing a chord
    // does not cause an immediate volume jump. User gain itself ramps21.3ms.
    assign gain_q8=(gain_state>desired_gain) ? desired_gain : gain_state;
    reg signed [29:0] product;
    wire signed [29:0] scaled=product>>>8;
    assign clipped=enable && (scaled>32767 || scaled< -32768);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            volume_smoothed<=0;target_product<=0;gain_state<=0;product<=0;pcm_out<=0;
        end else if(!enable) begin
            volume_smoothed<=0;target_product<=0;gain_state<=0;product<=0;pcm_out<=0;
        end else begin
            if(sample_en) begin
                if(volume_smoothed<volume_target)volume_smoothed<=volume_smoothed+1'b1;
                else if(volume_smoothed>volume_target)volume_smoothed<=volume_smoothed-1'b1;
            end
            target_product<=headroom*volume_smoothed;
            if(gain_state>desired_gain)gain_state<=desired_gain;
            else if(sample_en) begin
                if({1'b0,gain_state}+14'd4<{1'b0,desired_gain})gain_state<=gain_state+13'd4;
                else gain_state<=desired_gain;
            end
            product<=pcm_in*$signed({1'b0,gain_q8});
            if(scaled>32767)pcm_out<=32767;
            else if(scaled< -32768)pcm_out<=-32768;
            else pcm_out<=scaled[15:0];
        end
    end
endmodule
