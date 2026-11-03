`timescale 1ns/1ps
// ============================================================================
//  vib_lfo.v — 通用低速正弦 LFO（颤音调制源 / 合唱延迟调制源共用结构）
// ----------------------------------------------------------------------------
//  · 24 位相位累加器在 sample_en（48kHz）上推进，长期平均频率精确：
//        f_lfo = LFO_STEP / 2^24 * 48000 Hz
//    常用值：5.5Hz→1928；0.8Hz→280；0Hz→0（测试时冻结 LFO 用）
//  · 256 点 × 16bit 有符号正弦表由 tools/gen_sine_rom.py 用
//    round(32767*sin(2*pi*i/256)) 数学生成（$readmemh 载入，合规口径：
//    单周期数学波形，非录音采样——与波表同一合规论证）。
//  · 输出在两次 sample_en 之间保持恒定（相位不动表读数就不动），
//    下游串行乘法器有充足的 settle 时间。
// ============================================================================
module vib_lfo #(
    parameter integer LFO_STEP = 1928,   // 5.5 Hz @ 48kHz
    parameter ROM_FILE = "audio/rom/sine_lfo_256.mem"
)(
    input  wire clk, reset_n, sample_en,
    output reg  signed [15:0] lfo_sine
);
    reg [23:0] lfo_phase = 24'd0;
    (* syn_romstyle="block_rom" *) reg signed [15:0] sine_tbl [0:255];
    initial $readmemh(ROM_FILE, sine_tbl);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            lfo_phase <= 24'd0;
            lfo_sine  <= 16'sd0;
        end else begin
            lfo_sine <= sine_tbl[lfo_phase[23:16]];
            if (sample_en)
                lfo_phase <= lfo_phase + LFO_STEP[23:0];
        end
    end
endmodule
