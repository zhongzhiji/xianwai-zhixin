`timescale 1ns/1ps
module tb_showcase_director;
 reg clk=0,rst=0,pause=0,skip=0,restart=0;
 always #10 clk=~clk;
 wire [4:0] stage;wire held;wire [15:0] gate;wire [6:0] expr;
 wire [1:0] family,preset,fx;wire [2:0] page,test_sel;
 wire [3:0] vib;wire glide,melody,backing;wire [31:0] fw;
 showcase_director #(.CLK_HZ(500),.TICK_HZ(50)) dut(
  .clk(clk),.reset_n(rst),.pause_press(pause),.next_press(skip),.restart_press(restart),
  .stage(stage),.held(held),.gate(gate),.expression(expr),.family(family),.preset(preset),
  .fx(fx),.page(page),.test_sel(test_sel),.vib_depth(vib),.glide(glide),
  .melody(melody),.backing(backing),.freq_word(fw));
 integer cycles=0,last=-1,seen=0,fail=0,n=0;
 initial begin
  repeat(4)@(negedge clk);rst=1;
  while(seen<27 && cycles<400000)begin
   @(negedge clk);cycles=cycles+1;
   if(stage!==last) begin
    $display("STAGE %0d page=%0d family=%0d fx=%0d test=%0d",stage,page,family,fx,test_sel);
    if(stage!==seen%26)fail=fail+1;
    last=stage;seen=seen+1;
   end
   if((^gate)===1'bx || (^fw)===1'bx || expr>127 || page>6)fail=fail+1;
   if(stage>=14 && stage<=17 && (test_sel!=stage-13 || page!=5))fail=fail+1;
   if(stage==20 && !backing)fail=fail+1;
  end
  if(seen!=27)fail=fail+1;
  pause=1;@(negedge clk);pause=0;n=dut.seconds;
  repeat(1000)@(negedge clk);
  if(!held || dut.seconds!=n)fail=fail+1;
  skip=1;@(negedge clk);skip=0;@(negedge clk);
  if(stage!=1 || !held)fail=fail+1;
  restart=1;@(negedge clk);restart=0;@(negedge clk);
  if(stage!=0 || held)fail=fail+1;
  $display("PASS=%0d FAIL=%0d",seen,fail);
  if(fail)$fatal(1,"director failed");$finish;
 end
endmodule
