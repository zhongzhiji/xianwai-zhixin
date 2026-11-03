// Press S0 once after downloading. Assert reset asynchronously, release safely.
module reset_sync (
    input wire clk,
    input wire reset_button_n,
    output wire reset_n
);
    reg [2:0] release_pipe;
    always @(posedge clk or negedge reset_button_n) begin
        if (!reset_button_n)
            release_pipe <= 3'b000;
        else
            release_pipe <= {release_pipe[1:0], 1'b1};
    end
    assign reset_n = release_pipe[2];
endmodule
