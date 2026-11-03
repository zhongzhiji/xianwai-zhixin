`timescale 1ns/1ps
module tb_showcase_midi_score;
reg clk=0,rst_n=0,rx=1;
always #10 clk=~clk;
wire on,off,alive,valid;wire [6:0] note,vel;wire [7:0] raw;wire [15:0] count;
bt_uart_link #(.CLK_PER_BIT(8),.IDLE_TIMEOUT(70000)) dut(clk,rst_n,rx,on,off,note,vel,raw,valid,alive,count);
integer ons=0,offs=0,errors=0;
always @(posedge clk) begin if(on) ons=ons+1; if(off) offs=offs+1; end
task send; input [7:0] b; integer j; begin
 @(negedge clk);rx=0;repeat(8) @(negedge clk);
 for(j=0;j<8;j=j+1) begin rx=b[j];repeat(8) @(negedge clk);end
 rx=1;repeat(12) @(negedge clk);
end endtask
initial begin
 repeat(8) @(negedge clk);rst_n=1;
 send(8'h90);send(60);send(100);send(8'h80);send(60);send(0);
 send(8'h55);send("L");send(1);send(144);
 send(8'h55);send("W");send(0);send(64);send(4);
 send(8'h55);send("C");
 repeat(12) @(negedge clk);
 if(ons!=1 || offs!=1)errors=errors+1;
 send(8'h90);send(67);send(100);
 repeat(10000) @(negedge clk);
 if(!alive || ons!=2 || note!=67)errors=errors+1;
 repeat(61000) @(negedge clk);
 if(alive) errors=errors+1;
 $display("PASS=%0d FAIL=%0d MIDI_ON=%0d MIDI_OFF=%0d",3-errors,errors,ons,offs);
 if(errors) $fatal(1,"Score/MIDI demultiplex failure");
 $finish;
end
endmodule
