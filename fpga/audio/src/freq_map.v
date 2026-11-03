// ============================================================================
//  freq_map.v  —  第 IDX 个感应点 → 32 位频率字（编译期常量表）
// ----------------------------------------------------------------------------
//  频率字口径：freq_word = round(f / 48000 * 2^32)（与 osc.v 的 32 位相位累加器
//  完全一致；数值直接取自 note_freq.vh，没有第二套数据）。
//
//  两个布局（LAYOUT 参数选）：
//    LAYOUT = 1（默认，推荐）= C 大调 C4…D6，16 个音正好铺满 16 个点：
//        点0  C4 261.63   点1  D4 293.66   点2  E4 329.63   点3  F4 349.23
//        点4  G4 392.00   点5  A4 440.00   点6  B4 493.88   点7  C5 523.25
//        点8  D5 587.33   点9  E5 659.26   点10 F5 698.46   点11 G5 783.99
//        点12 A5 880.00   点13 B5 987.77   点14 C6 1046.50  点15 D6 1174.66
//      → 点阵就是一台 16 键的旋律乐器，随手画个音阶/曲子都能弹。
//
//    LAYOUT = 0 = 半音阶 C4…D#5（midi 60..75），16 个半音。
//
//  ★ 实例化时 IDX 用 genvar 常量传入 → 整个模块被综合成一条常量，0 LUT。
//  ★ 用「函数 + 连续赋值」而不是 always @(*)：
//    表里只有常量、没有任何输入信号，always @(*) 的敏感列表为空，
//    iverilog 会警告 "found no sensitivities so it will never trigger"，
//    fw 一直是 X（仿真里表现为整机无声）。连续赋值没有这个问题。
// ============================================================================
`timescale 1ns / 1ps
`include "note_freq.vh"

module freq_map #(
    parameter integer LAYOUT = 1,
    parameter integer IDX    = 0
)(
    output wire [31:0] fw
);

    function [31:0] freq_word_of;
        input integer layout;
        input integer idx;
        begin
            if (layout == 1) begin
                case (idx)
                    0:  freq_word_of = NOTE_FW_60;   // C4
                    1:  freq_word_of = NOTE_FW_62;   // D4
                    2:  freq_word_of = NOTE_FW_64;   // E4
                    3:  freq_word_of = NOTE_FW_65;   // F4
                    4:  freq_word_of = NOTE_FW_67;   // G4
                    5:  freq_word_of = NOTE_FW_69;   // A4
                    6:  freq_word_of = NOTE_FW_71;   // B4
                    7:  freq_word_of = NOTE_FW_72;   // C5
                    8:  freq_word_of = NOTE_FW_74;   // D5
                    9:  freq_word_of = NOTE_FW_76;   // E5
                    10: freq_word_of = NOTE_FW_77;   // F5
                    11: freq_word_of = NOTE_FW_79;   // G5
                    12: freq_word_of = NOTE_FW_81;   // A5
                    13: freq_word_of = NOTE_FW_83;   // B5
                    14: freq_word_of = NOTE_FW_84;   // C6
                    15: freq_word_of = NOTE_FW_86;   // D6
                    default: freq_word_of = 32'd0;
                endcase
            end else begin
                case (idx)
                    0:  freq_word_of = NOTE_FW_60;   // C4
                    1:  freq_word_of = NOTE_FW_61;   // C#4
                    2:  freq_word_of = NOTE_FW_62;   // D4
                    3:  freq_word_of = NOTE_FW_63;   // D#4
                    4:  freq_word_of = NOTE_FW_64;   // E4
                    5:  freq_word_of = NOTE_FW_65;   // F4
                    6:  freq_word_of = NOTE_FW_66;   // F#4
                    7:  freq_word_of = NOTE_FW_67;   // G4
                    8:  freq_word_of = NOTE_FW_68;   // G#4
                    9:  freq_word_of = NOTE_FW_69;   // A4
                    10: freq_word_of = NOTE_FW_70;   // A#4
                    11: freq_word_of = NOTE_FW_71;   // B4
                    12: freq_word_of = NOTE_FW_72;   // C5
                    13: freq_word_of = NOTE_FW_73;   // C#5
                    14: freq_word_of = NOTE_FW_74;   // D5
                    15: freq_word_of = NOTE_FW_75;   // D#5
                    default: freq_word_of = 32'd0;
                endcase
            end
        end
    endfunction

    assign fw = freq_word_of(LAYOUT, IDX);

endmodule
