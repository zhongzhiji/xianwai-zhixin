`timescale 1ns/1ps
module tb_showcase_transport;
reg clk=0,rst=0;always #10 clk=~clk;
reg [21:0] cfg=0;reg page=0;wire [43:0] ac;
score_display_core #(.SHOWCASE(1),.H_ACTIVE(16),.H_BACK(0),.H_FRONT(0),.V_ACTIVE(16),.V_BACK(0),.V_FRONT(0),.AUDIO_NOTE_GAP_CYCLES(4)) dut(
 .pixel_clk(clk),.reset_n(rst),.showcase_config(cfg),.toggle_play(1'b0),.restart(1'b0),
 .next_timbre(1'b0),.toggle_demo(1'b0),.next_mode(page),.next_instrument(1'b0),.next_song(1'b0),
 .input_online(3'd0),.external_pressed(32'd1),.external_expression(7'd100),.volume_step(5'd12),.volume_edit(1'b0),
 .practice_mode(2'd0),.backing_enabled(1'b0),.load_we(1'b0),.load_addr(8'd0),.load_note(7'd0),.load_length(4'd0),
 .load_commit(1'b0),.load_count(8'd0),.load_bpm(8'd120),.audio_control(ac),
 .i_game_enable(1'b0),.i_game_judge(2'd0),.i_game_judge_hold(6'd0),.i_game_combo(8'd0),.i_game_best_combo(8'd0),
 .i_game_score_bcd(32'd0),.i_game_pf(8'd0),.i_game_gd(8'd0),.i_game_ms(8'd0),.wave_mail(25'd0),.spec_mail(14'd0),.liss_mail(16'd0),.fx_mode(2'd0),.test_sel(3'd0));
integer err=0;reg [9:0] idx;
initial begin
 repeat(8)@(negedge clk);rst=1;repeat(1024)@(negedge clk);
 if(dut.raw_playing!==1 || dut.articulated_note==0)err=err+1;
 if(dut.u_transport.user_score && dut.raw_ticks_left != (dut.u_transport.remaining_ticks+2)/3)
   $fatal(1,"display duration units differ from score window");
 idx=dut.u_transport.event_index;
 repeat(16000)@(negedge clk);
 if(dut.u_transport.event_index==idx)err=err+1;
 page=1;@(negedge clk);page=0;repeat(1024)@(negedge clk);
 if(dut.view_mode!=1)err=err+1;
 cfg={1'b0,5'd18,3'd4,2'd0,2'd0,2'd0,3'd0,1'b0,3'd0};repeat(1024)@(negedge clk);
 if(dut.view_mode!=4 || dut.raw_playing!==1 || dut.u_transport.event_index!=0)err=err+1;
 $display("PASS=%0d FAIL=%0d boot_play=%0b note=%0d",4-err,err,dut.raw_playing,dut.articulated_note);
 if(err)$fatal(1,"showcase transport failure");$finish;
end
endmodule
