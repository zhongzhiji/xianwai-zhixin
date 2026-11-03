`timescale 1ns/1ps
module tb_showcase_import;
 reg clk=0,rst=0,start=0;always #10 clk=~clk;
 wire tx,busy,done,we,commit,fd,accept;
 wire [7:0] addr,count,bpm,errs;wire [6:0] note;wire [3:0] length;wire [2:0] ec;
 reg [7:0] expected[0:23];integer writes=0,commits=0,fail=0,cycles=0;
 showcase_uart_rom #(.CLK_PER_BIT(8)) src(.clk(clk),.reset_n(rst),.start(start),.tx(tx),.busy(busy),.done(done));
 score_loader_uart #(.CLK_PER_BIT(8)) dut(.clk(clk),.rst_n(rst),.rx(tx),
  .load_we(we),.load_addr(addr),.load_note(note),.load_length(length),.load_commit(commit),
  .load_count(count),.load_bpm(bpm),.frame_done(fd),.commit_accept(accept),.err_code(ec),.err_count(errs),.recv_count());
 always @(negedge clk) if(rst)begin
  if(we)begin
   if(addr!=writes || note!=expected[writes] || length<1)fail=fail+1;
   writes=writes+1;
  end
  if(commit)commits=commits+1;
 end
 initial begin
  $readmemh("sim/showcase_expected.mem",expected);
  repeat(5)@(negedge clk);rst=1;repeat(3)@(negedge clk);
  start=1;@(negedge clk);start=0;
  while(commits==0 && cycles<20000)begin @(negedge clk);cycles=cycles+1;end
  repeat(40)@(negedge clk);
  if(writes!=24 || commits!=1 || count!=24 || bpm!=120 || errs!=0)fail=fail+1;
  $display("UART 8N1 -> real score_loader_uart: writes=%0d commits=%0d count=%0d bpm=%0d errors=%0d",writes,commits,count,bpm,errs);
  $display("PASS=%0d FAIL=%0d",writes,fail);
  if(fail)$fatal(1,"UART loopback failed");$finish;
 end
endmodule
