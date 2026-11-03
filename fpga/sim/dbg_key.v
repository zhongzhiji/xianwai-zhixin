`timescale 1ns/1ps
module dbg;
    reg clk=0, rst_n=0;
    wire [7:0] row_drv;
    reg [7:0] col_in;
    wire [63:0] key_state;
    wire key_change, key_valid, ghost_warn;
    wire [5:0] key_index;
    always #10 clk=~clk;
    key_matrix_scan #(.ROWS(8),.COLS(8),.KEYW(6),.CLK_HZ(50000000),.ROW_US(1),.FRAMES(3),.ACTIVE_LOW(1)) uut(
        .clk(clk),.rst_n(rst_n),.row_drv(row_drv),.col_in(col_in),
        .key_state(key_state),.key_change(key_change),.key_valid(key_valid),
        .key_index(key_index),.ghost_warn(ghost_warn));
    reg [63:0] pressed;
    integer r,c; reg [7:0] col_r;
    always @(*) begin
        col_r=8'hFF;
        for(r=0;r<8;r=r+1) if(row_drv[r]==1'b0)
            for(c=0;c<8;c=c+1) if(pressed[r*8+c]) col_r[c]=1'b0;
        col_in=col_r;
    end
    reg vseen=0, cseen=0;
    always @(posedge clk) begin
        if (key_valid)  vseen <= 1'b1;
        if (key_change) cseen <= 1'b1;
    end
    initial begin
        pressed=0; #200 rst_n=1'b1;
        repeat(1000) @(posedge clk);
        pressed=64'd1;
        repeat(3000) @(posedge clk);
        $display("FINAL ks0=%b vseen=%b cseen=%b", key_state[0], vseen, cseen);
        $finish;
    end
    always @(posedge clk) begin
        if (uut.frame_done || key_valid || key_change)
            $display("[%0t] fd=%b ks0=%b prev=%b newly=%b chg=%b val=%b idx=%d",
                $time, uut.frame_done, key_state[0], uut.state_prev[0], uut.newly[0],
                key_change, key_valid, key_index);
    end
endmodule
