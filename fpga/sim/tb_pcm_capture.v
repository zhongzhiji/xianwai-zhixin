`timescale 1ns/1ps
// Analysis capture, not a wall-clock latency test. Sample strobes are accelerated
// to one per 100 clock edges; DDS increments still specify nominal 48 kHz audio.
// Vibrato/glide are disabled and 100 cycles cover the 32-entry control pipeline.
module tb_pcm_capture;
reg clk50=0,reset_n=0,sample_en=0,enable=0;
wire signed [15:0] pcm;
wire [31:0] voices_active;
wire clipped;
fsr32_engine dut(.clk50(clk50),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
 .note_gate(16'd0),.ext_gate(16'd0),.ext_freq_word(32'd0),
 .family(2'd2),.preset(2'd0),.octave(2'd1),.expression(7'd112),
 .freq_override(1'b0),.freq_override_word(32'd0),.test_mode(1'b1),.test_count(6'd32),
 .vib_depth(4'd0),.glide_en(1'b0),.glide_rate(3'd0),
 .pcm(pcm),.voices_active(voices_active),.clipped(clipped));
always #10 clk50=~clk50;
integer n,f,clip_count=0;
initial begin
 repeat(8)@(negedge clk50);reset_n=1;enable=1;
 f=$fopen("sim/pages_verified/pcm32.txt","w");
 if(!f)$fatal(1,"capture file unavailable");
 for(n=0;n<36864;n=n+1)begin
   sample_en=1;@(negedge clk50);sample_en=0;
   repeat(99)@(negedge clk50);
   if(n>=4096)begin
     if((^pcm)===1'bx || voices_active!==32'hffffffff)$fatal(1,"invalid capture state");
     $fwrite(f,"%0d\n",pcm);if(clipped)clip_count=clip_count+1;
   end
 end
 $fclose(f);$display("CAPTURE PASS samples=32768 active=32 clipped=%0d",clip_count);$finish;
end
endmodule
