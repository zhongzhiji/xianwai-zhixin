`timescale 1ns/1ps
// 16 independent phase accumulators + ADSRs. Original natural-note map/48kHz
// preserved. Input controls MUST share clk50 domain. PCM is not instrument PCM
// recording: finite-harmonic mathematical waves with characteristic envelopes.
module fsr16_engine #(
    parameter integer LAYOUT=1,VOL_SHIFT=4,CHROMATIC_AUDITION=0,
    parameter ROM_FILE="audio/rom/wavetable_showcase.mem"
)(
    input wire clk50,reset_n,sample_en,enable,
    input wire [15:0] note_gate,
    input wire [1:0] family,preset,octave,
    input wire [6:0] expression,
    // Default disabled: original pressure/top/audio tests retain the same map.
    // Enabled only for the combined project's monophonic C4-B5 audition path.
    input wire freq_override,
    input wire [31:0] freq_override_word,
    output reg signed [15:0] pcm,
    output wire [15:0] voices_active,
    output reg [15:0] note_on,note_off,
    output reg [15:0] expression_smoothed,
    output wire clipped,
    output wire [255:0] voice_debug
);
    wire [15:0] effective_gate=enable ? note_gate : 16'd0;
    reg [15:0] previous_gate;
    wire [15:0] gain_target={1'b0,expression,8'd0};
    genvar v;
    generate for(v=0;v<16;v=v+1) begin: VOICE
        wire [31:0] base_fw,fw;
        freq_map #(.LAYOUT(LAYOUT),.IDX(v)) u_frequency(.fw(base_fw));
        wire [31:0] mapped_fw=octave==0 ? (base_fw>>1) : octave==1 ? base_fw :
                  octave==2 ? (base_fw<<1) : (base_fw<<2);
        if(v==0 && CHROMATIC_AUDITION!=0) begin: AUDITION
            assign fw=freq_override ? freq_override_word : mapped_fw;
        end else begin: FIXED_MAP
            assign fw=mapped_fw;
        end
        timbre_voice #(.VOL_SHIFT(VOL_SHIFT),.ROM_FILE(ROM_FILE)) u_voice(
            .clk(clk50),.reset_n(reset_n),.sample_en(sample_en),.enable(enable),
            .gate(effective_gate[v]),.freq_word(fw),.family(family),.preset(preset),
            .sample(voice_debug[v*16+:16]),.active(voices_active[v]));
    end endgenerate
    //50MHz timing: every balanced sum stage and the gain multiplication is
    // registered. Five extra sysclk cycles(100ns) versus the original PCM
    // path; the48kHz serializer still captures the same settled prior frame.
    reg signed [16:0] level1 [0:7];
    reg signed [17:0] level2 [0:3];
    reg signed [18:0] level3 [0:1];
    generate for(v=0;v<8;v=v+1) begin: MIX1
        wire signed [15:0] a=voice_debug[v*32+:16],b=voice_debug[v*32+16+:16];
        always @(posedge clk50 or negedge reset_n)
            if(!reset_n)level1[v]<=0;
            else if(!enable)level1[v]<=0;
            else level1[v]<=$signed({a[15],a})+$signed({b[15],b});
    end
    for(v=0;v<4;v=v+1) begin: MIX2
        always @(posedge clk50 or negedge reset_n)
            if(!reset_n)level2[v]<=0;
            else if(!enable)level2[v]<=0;
            else level2[v]<=$signed({level1[2*v][16],level1[2*v]})+
                            $signed({level1[2*v+1][16],level1[2*v+1]});
    end
    for(v=0;v<2;v=v+1) begin: MIX3
        always @(posedge clk50 or negedge reset_n)
            if(!reset_n)level3[v]<=0;
            else if(!enable)level3[v]<=0;
            else level3[v]<=$signed({level2[2*v][17],level2[2*v]})+
                            $signed({level2[2*v+1][17],level2[2*v+1]});
    end endgenerate
    reg signed [19:0] mix;
    reg signed [36:0] gain_product;
    always @(posedge clk50 or negedge reset_n)
        if(!reset_n)begin mix<=0;gain_product<=0;end
        else if(!enable)begin mix<=0;gain_product<=0;end
        else begin
            mix<=$signed({level3[0][18],level3[0]})+$signed({level3[1][18],level3[1]});
            gain_product<=mix*$signed({1'b0,expression_smoothed});
        end
    wire signed [36:0] gain_scaled=gain_product>>>15;
    assign clipped=enable && (gain_scaled>32767 || gain_scaled< -32768);
    always @(posedge clk50 or negedge reset_n) begin
        if(!reset_n) begin
            pcm<=0;expression_smoothed<=0;previous_gate<=0;note_on<=0;note_off<=0;
        end else begin
            previous_gate<=effective_gate;
            note_on<=effective_gate & ~previous_gate;
            note_off<=previous_gate & ~effective_gate;
            if(!enable) begin pcm<=0;expression_smoothed<=0;end
            else begin
                if(sample_en) begin
                    // Maximum full-scale expression travel <5.4ms at48kHz;
                    // no one-frame jump even if raw pressure changes abruptly.
                    if(expression_smoothed+17'd128 < {1'b0,gain_target})
                        expression_smoothed<=expression_smoothed+16'd128;
                    else if({1'b0,expression_smoothed} > gain_target+17'd128)
                        expression_smoothed<=expression_smoothed-16'd128;
                    else expression_smoothed<=gain_target;
                end
                if(gain_scaled>32767) pcm<=32767;
                else if(gain_scaled< -32768) pcm<=-32768;
                else pcm<=gain_scaled[15:0];
            end
        end
    end
endmodule

module timbre_voice #(
    parameter integer VOL_SHIFT=4,
    parameter ROM_FILE="audio/rom/wavetable_showcase.mem"
)(
    input wire clk,reset_n,sample_en,enable,gate,
    input wire [31:0] freq_word,
    input wire [1:0] family,preset,
    output reg signed [15:0] sample,
    output wire active
);
    localparam IDLE=0,ATTACK=1,DECAY=2,SUSTAIN=3,RELEASE=4;
    reg [2:0] state;
    reg [15:0] envelope;
    reg [31:0] phase;
    reg [1:0] active_family,active_preset;
    reg previous_gate;
    reg [3:0] held_decay_counter;
    reg [15:0] attack_step,decay_step,sustain_level,release_step;
    wire tone_change=family!=active_family || (preset>2 ? 2'd2 : preset)!=active_preset;
    wire [3:0] family_wide={2'b00,active_family};
    wire [3:0] bank=(family_wide<<1)+family_wide+{2'b00,active_preset};
    wire [10:0] address={bank,phase[31:25]};
    (* syn_romstyle="block_rom" *) reg [15:0] waves [0:1535];
    reg signed [15:0] wave;
    initial $readmemh(ROM_FILE,waves);
    always @(posedge clk) wave<=waves[address];
    wire signed [32:0] product=wave*$signed({1'b0,envelope});
    wire signed [32:0] attenuated=product >>> (15+VOL_SHIFT);
    assign active=enable && envelope!=0;
    always @* begin
        attack_step=170;decay_step=8;sustain_level=8192;release_step=8;
        case(active_family)
            0:case(active_preset)
                0:begin attack_step=137;decay_step=6;sustain_level=8192;release_step=8;end
                1:begin attack_step=205;decay_step=12;sustain_level=6144;release_step=12;end
                default:begin attack_step=164;decay_step=4;sustain_level=12288;release_step=6;end
            endcase
            1:begin
                attack_step=328;decay_step=32;sustain_level=4096;release_step=24;
                if(active_preset==1) begin attack_step=205;decay_step=24;release_step=16;end
                if(active_preset==2) begin attack_step=410;decay_step=48;release_step=32;end
            end
            2:begin
                attack_step=34;decay_step=4;sustain_level=24576;release_step=12;
                if(active_preset==1) begin attack_step=68;sustain_level=22937;release_step=16;end
                if(active_preset==2) begin attack_step=27;sustain_level=26000;release_step=10;end
            end
            default:begin
                attack_step=41;decay_step=8;sustain_level=20000;release_step=16;
                if(active_preset==1) begin attack_step=205;decay_step=24;sustain_level=12000;release_step=24;end
                if(active_preset==2) begin attack_step=82;sustain_level=22937;release_step=12;end
            end
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE;envelope<=0;phase<=0;previous_gate<=0;
            active_family<=0;active_preset<=0;sample<=0;held_decay_counter<=0;
        end else if(!enable) begin
            state<=IDLE;envelope<=0;previous_gate<=0;sample<=0;held_decay_counter<=0;
        end else begin
            sample<=attenuated[15:0];
            if(sample_en) begin
                previous_gate<=gate;
                phase<=phase+freq_word;
                // Changing a preset at full envelope would click. Fade out
                // within<=1.34ms, switch at zero, then use new attack shape.
                if(tone_change) begin
                    if(envelope>512) envelope<=envelope-16'd512;
                    else begin
                        envelope<=0;active_family<=family;
                        active_preset<=preset>2 ? 2'd2 : preset;
                        state<=gate ? ATTACK : IDLE;held_decay_counter<=0;
                    end
                end else if(gate && !previous_gate) begin state<=ATTACK;held_decay_counter<=0;end
                else if(!gate && previous_gate) state<=RELEASE;
                else case(state)
                    IDLE:envelope<=0;
                    ATTACK:if({1'b0,envelope}+{1'b0,attack_step}>=17'd32767) begin
                        envelope<=32767;state<=DECAY;
                    end else envelope<=envelope+attack_step;
                    DECAY:if(envelope<=sustain_level+decay_step) begin
                        envelope<=sustain_level;state<=SUSTAIN;held_decay_counter<=0;
                    end else envelope<=envelope-decay_step;
                    SUSTAIN:begin
                        // Struck/plucked families decay while a pad is held,
                        // unlike original fixed sustain on every waveform.
                        if(active_family<2) begin
                            // Fractional-rate decay avoids the integer-Q15
                            // floor making all struck notes vanish in~250ms.
                            held_decay_counter<=held_decay_counter+1'b1;
                            if(active_family==0 && held_decay_counter==15 && envelope>0)
                                envelope<=envelope-((envelope>>11)>0 ? (envelope>>11) : 16'd1);
                            else if(active_family==1 && held_decay_counter[1:0]==3 && envelope>0)
                                envelope<=envelope-((envelope>>10)>0 ? (envelope>>10) : 16'd1);
                        end else envelope<=sustain_level;
                    end
                    RELEASE:if(envelope<=release_step) begin
                        envelope<=0;state<=IDLE;
                    end else envelope<=envelope-release_step;
                    default:begin envelope<=0;state<=IDLE;end
                endcase
            end
        end
    end
endmodule
