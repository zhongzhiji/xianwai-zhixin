// Exact monophonic score matching in the pixel clock domain. A touch state is
// not a note-on: compare previous/current states and require release to rearm.
// Concept reference: Adafruit_MPR121/examples/MPR121test/MPR121test.ino
// Original HDL implementation; no third-party source copied.
module score_note_matcher #(
    parameter [31:0] PLAYABLE_MASK=32'h05ab5ab5
)(
    input wire clk,reset_n,enable,online,resync,clear_stats,target_ready,
    input wire [6:0] target_midi_note,
    input wire [10:0] event_token,
    input wire [31:0] pressed,
    output reg advance,wrong_note,
    output wire unsupported,
    output wire [31:0] target_mask,
    output reg [15:0] hits,errors
);
    reg [31:0] previous_pressed;
    reg [10:0] previous_token;
    reg armed,event_matched;
    reg previous_enabled,previous_online;
    wire [31:0] onsets=pressed & ~previous_pressed;
    wire transaction_changed=event_token!=previous_token;
    wire pitched=target_midi_note!=0;
    assign target_mask=(target_midi_note>=7'd60 && target_midi_note<=7'd91) ?
                       (32'd1 << (target_midi_note-7'd60)) : 32'd0;
    assign unsupported=target_ready && pitched &&
                       ((target_mask & PLAYABLE_MASK)==0);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            previous_pressed<=0;previous_token<=0;armed<=0;event_matched<=0;
            previous_enabled<=0;previous_online<=0;
            advance<=0;wrong_note<=0;hits<=0;errors<=0;
        end else begin
            previous_pressed<=pressed;previous_token<=event_token;
            previous_enabled<=enable;previous_online<=online;
            advance<=0;wrong_note<=0;
            if(clear_stats) begin hits<=0;errors<=0;end
            // FOLLOW can spend many frames on one event. Release/repress,
            // pause/resume and reconnect must not award that event twice.
            // A new event (including repeated pitches) or a new attempt may.
            if(clear_stats || transaction_changed)event_matched<=0;
            // A resume/reconnect/new event cannot turn a pre-held pad into a hit.
            if(resync || clear_stats || !enable || !online || !target_ready ||
               !previous_enabled || !previous_online || transaction_changed)
                armed<=0;
            else if(pressed==0)
                armed<=1;
            else if(armed && onsets!=0 && !event_matched) begin
                armed<=0;
                // Unsupported score pitches stay visible and never auto-pass.
                // A rest is handled by transport timing, not by an arbitrary key.
                if(pitched && !unsupported) begin
                    if(pressed==target_mask && onsets==target_mask) begin
                        advance<=1;
                        event_matched<=1;
                        if(hits!=16'hffff) hits<=hits+1'b1;
                    end else begin
                        wrong_note<=1;
                        if(errors!=16'hffff) errors<=errors+1'b1;
                    end
                end
            end
        end
    end
endmodule
