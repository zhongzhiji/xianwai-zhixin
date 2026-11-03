// UI selection only: NOT a synthesizer, sample loader or audio acknowledgement.
// All events are one-cycle pulses in pixel_clk domain. Each family remembers
// its own selected preset. Changing pages never restarts the score transport.
module ui_view_state(
    input wire clk, reset_n,
    input wire next_mode, next_family, next_preset,
    output reg [2:0] ui_mode,
    output reg [1:0] instrument,
    output reg [1:0] preset
);
    reg [1:0] keys_preset, strings_preset, synth_preset, perc_preset;
    always @* begin
        case (instrument)
            2'd0: preset=keys_preset;
            2'd1: preset=strings_preset;
            2'd2: preset=synth_preset;
            default: preset=perc_preset;
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ui_mode<=0; instrument<=0;
            keys_preset<=0; strings_preset<=0; synth_preset<=0; perc_preset<=0;
        end else begin
            // SCORE / PLAY / SOUND / SONG LIST / WAVE / SPEC / LISS, all
            // independently persistent. 七页循环（频谱与李萨如是 6/7 页，
            // 都属于拓展3"LED/LCD 实时视听"的可选增强）。
            if (next_mode) ui_mode<=(ui_mode==3'd6) ? 3'd0 : ui_mode+3'd1;
            // Family takes priority over preset on coincident external events.
            if (next_family) instrument<=instrument+1'b1;
            else if (next_preset) begin
                case (instrument)
                    2'd0: keys_preset<=(keys_preset==2) ? 2'd0 : keys_preset+1'b1;
                    2'd1: strings_preset<=(strings_preset==2) ? 2'd0 : strings_preset+1'b1;
                    2'd2: synth_preset<=(synth_preset==2) ? 2'd0 : synth_preset+1'b1;
                    2'd3: perc_preset<=(perc_preset==2) ? 2'd0 : perc_preset+1'b1;
                endcase
            end
        end
    end
endmodule
