// Active-low key: 2-FF sync, stable-level debounce, mutually exclusive actions.
// Short action is emitted ON RELEASE; long action fires once at HOLD_CYCLES.
// Holding a key never emits its short action as well. Default 600ms at 35MHz.
module ui_action_button #(
    parameter DEBOUNCE_CYCLES=350000,
    parameter HOLD_CYCLES=21000000
)(
    input wire clk, reset_n, button_n,
    output reg short_press, long_press,
    output wire pressed
);
    reg sync_a, sync_b, stable_n;
    reg [23:0] debounce_count;
    reg [24:0] hold_count;
    reg long_fired,initial_release_seen;
    assign pressed=initial_release_seen && !stable_n;
    wire level_change=(sync_b!=stable_n && debounce_count>=DEBOUNCE_CYCLES-1);
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Start disarmed. A key held through reset must not become an
            // implicit play command when it is first released.
            sync_a<=0; sync_b<=0; stable_n<=0;
            debounce_count<=0; hold_count<=0; long_fired<=0;
            short_press<=0; long_press<=0;
            initial_release_seen<=0;
        end else begin
            sync_a<=button_n; sync_b<=sync_a;
            short_press<=0; long_press<=0;
            if (sync_b==stable_n) debounce_count<=0;
            else if (level_change) begin
                stable_n<=sync_b; debounce_count<=0;
            end else debounce_count<=debounce_count+1'b1;

            if (level_change) begin
                if (!sync_b) begin
                    hold_count<=0; long_fired<=0;
                end else begin
                    // Release wins a simultaneous threshold tick. A release
                    // that has not crossed the threshold is a short press.
                    short_press<=initial_release_seen && !long_fired;
                    initial_release_seen<=1;
                    hold_count<=0; long_fired<=0;
                end
            end else if (initial_release_seen && !stable_n && !long_fired) begin
                if (hold_count>=HOLD_CYCLES-1) begin
                    long_press<=1; long_fired<=1;
                end else hold_count<=hold_count+1'b1;
            end
        end
    end
endmodule
