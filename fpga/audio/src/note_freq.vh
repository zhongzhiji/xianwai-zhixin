// ============================================================================
//  note_freq.vh  —  自动生成，请勿手改（改 tools/gen_note_freq.py 后重跑）
//
//  freq_word = round(f / 48000 * 2^32)，f 按 12 平均律 A4=440Hz
//  覆盖 MIDI 36..96
//
//  实测口径：频率分辨率 = Fs/2^32 ≈ 1.1e-5 Hz，音准误差远小于 1 音分。
// ============================================================================

`ifndef NOTE_FREQ_VH
`define NOTE_FREQ_VH

localparam [31:0] NOTE_FW_36 = 32'd5852465;   // C2      65.4064 Hz
localparam [31:0] NOTE_FW_37 = 32'd6200470;   // C#2     69.2957 Hz
localparam [31:0] NOTE_FW_38 = 32'd6569170;   // D2      73.4162 Hz
localparam [31:0] NOTE_FW_39 = 32'd6959793;   // D#2     77.7817 Hz
localparam [31:0] NOTE_FW_40 = 32'd7373644;   // E2      82.4069 Hz
localparam [31:0] NOTE_FW_41 = 32'd7812103;   // F2      87.3071 Hz
localparam [31:0] NOTE_FW_42 = 32'd8276635;   // F#2     92.4986 Hz
localparam [31:0] NOTE_FW_43 = 32'd8768789;   // G2      97.9989 Hz
localparam [31:0] NOTE_FW_44 = 32'd9290209;   // G#2    103.8262 Hz
localparam [31:0] NOTE_FW_45 = 32'd9842633;   // A2     110.0000 Hz
localparam [31:0] NOTE_FW_46 = 32'd10427907;   // A#2    116.5409 Hz
localparam [31:0] NOTE_FW_47 = 32'd11047982;   // B2     123.4708 Hz
localparam [31:0] NOTE_FW_48 = 32'd11704930;   // C3     130.8128 Hz
localparam [31:0] NOTE_FW_49 = 32'd12400941;   // C#3    138.5913 Hz
localparam [31:0] NOTE_FW_50 = 32'd13138339;   // D3     146.8324 Hz
localparam [31:0] NOTE_FW_51 = 32'd13919586;   // D#3    155.5635 Hz
localparam [31:0] NOTE_FW_52 = 32'd14747287;   // E3     164.8138 Hz
localparam [31:0] NOTE_FW_53 = 32'd15624207;   // F3     174.6141 Hz
localparam [31:0] NOTE_FW_54 = 32'd16553270;   // F#3    184.9972 Hz
localparam [31:0] NOTE_FW_55 = 32'd17537579;   // G3     195.9977 Hz
localparam [31:0] NOTE_FW_56 = 32'd18580418;   // G#3    207.6523 Hz
localparam [31:0] NOTE_FW_57 = 32'd19685267;   // A3     220.0000 Hz
localparam [31:0] NOTE_FW_58 = 32'd20855814;   // A#3    233.0819 Hz
localparam [31:0] NOTE_FW_59 = 32'd22095965;   // B3     246.9417 Hz
localparam [31:0] NOTE_FW_60 = 32'd23409859;   // C4     261.6256 Hz
localparam [31:0] NOTE_FW_61 = 32'd24801882;   // C#4    277.1826 Hz
localparam [31:0] NOTE_FW_62 = 32'd26276679;   // D4     293.6648 Hz
localparam [31:0] NOTE_FW_63 = 32'd27839171;   // D#4    311.1270 Hz
localparam [31:0] NOTE_FW_64 = 32'd29494575;   // E4     329.6276 Hz
localparam [31:0] NOTE_FW_65 = 32'd31248413;   // F4     349.2282 Hz
localparam [31:0] NOTE_FW_66 = 32'd33106541;   // F#4    369.9944 Hz
localparam [31:0] NOTE_FW_67 = 32'd35075158;   // G4     391.9954 Hz
localparam [31:0] NOTE_FW_68 = 32'd37160835;   // G#4    415.3047 Hz
localparam [31:0] NOTE_FW_69 = 32'd39370534;   // A4     440.0000 Hz
localparam [31:0] NOTE_FW_70 = 32'd41711627;   // A#4    466.1638 Hz
localparam [31:0] NOTE_FW_71 = 32'd44191930;   // B4     493.8833 Hz
localparam [31:0] NOTE_FW_72 = 32'd46819719;   // C5     523.2511 Hz
localparam [31:0] NOTE_FW_73 = 32'd49603764;   // C#5    554.3653 Hz
localparam [31:0] NOTE_FW_74 = 32'd52553357;   // D5     587.3295 Hz
localparam [31:0] NOTE_FW_75 = 32'd55678342;   // D#5    622.2540 Hz
localparam [31:0] NOTE_FW_76 = 32'd58989149;   // E5     659.2551 Hz
localparam [31:0] NOTE_FW_77 = 32'd62496826;   // F5     698.4565 Hz
localparam [31:0] NOTE_FW_78 = 32'd66213081;   // F#5    739.9888 Hz
localparam [31:0] NOTE_FW_79 = 32'd70150316;   // G5     783.9909 Hz
localparam [31:0] NOTE_FW_80 = 32'd74321671;   // G#5    830.6094 Hz
localparam [31:0] NOTE_FW_81 = 32'd78741067;   // A5     880.0000 Hz
localparam [31:0] NOTE_FW_82 = 32'd83423255;   // A#5    932.3275 Hz
localparam [31:0] NOTE_FW_83 = 32'd88383859;   // B5     987.7666 Hz
localparam [31:0] NOTE_FW_84 = 32'd93639437;   // C6    1046.5023 Hz
localparam [31:0] NOTE_FW_85 = 32'd99207528;   // C#6   1108.7305 Hz
localparam [31:0] NOTE_FW_86 = 32'd105106715;   // D6    1174.6591 Hz
localparam [31:0] NOTE_FW_87 = 32'd111356685;   // D#6   1244.5079 Hz
localparam [31:0] NOTE_FW_88 = 32'd117978298;   // E6    1318.5102 Hz
localparam [31:0] NOTE_FW_89 = 32'd124993653;   // F6    1396.9129 Hz
localparam [31:0] NOTE_FW_90 = 32'd132426162;   // F#6   1479.9777 Hz
localparam [31:0] NOTE_FW_91 = 32'd140300631;   // G6    1567.9817 Hz
localparam [31:0] NOTE_FW_92 = 32'd148643341;   // G#6   1661.2188 Hz
localparam [31:0] NOTE_FW_93 = 32'd157482134;   // A6    1760.0000 Hz
localparam [31:0] NOTE_FW_94 = 32'd166846509;   // A#6   1864.6550 Hz
localparam [31:0] NOTE_FW_95 = 32'd176767719;   // B6    1975.5332 Hz
localparam [31:0] NOTE_FW_96 = 32'd187278874;   // C7    2093.0045 Hz

// 按音符号取频率字（m 需在 `NOTE_LO..`NOTE_HI 内）
function [31:0] note_fw(input [6:0] m);
    begin
        case (m)
            7'd36: note_fw = NOTE_FW_36;
            7'd37: note_fw = NOTE_FW_37;
            7'd38: note_fw = NOTE_FW_38;
            7'd39: note_fw = NOTE_FW_39;
            7'd40: note_fw = NOTE_FW_40;
            7'd41: note_fw = NOTE_FW_41;
            7'd42: note_fw = NOTE_FW_42;
            7'd43: note_fw = NOTE_FW_43;
            7'd44: note_fw = NOTE_FW_44;
            7'd45: note_fw = NOTE_FW_45;
            7'd46: note_fw = NOTE_FW_46;
            7'd47: note_fw = NOTE_FW_47;
            7'd48: note_fw = NOTE_FW_48;
            7'd49: note_fw = NOTE_FW_49;
            7'd50: note_fw = NOTE_FW_50;
            7'd51: note_fw = NOTE_FW_51;
            7'd52: note_fw = NOTE_FW_52;
            7'd53: note_fw = NOTE_FW_53;
            7'd54: note_fw = NOTE_FW_54;
            7'd55: note_fw = NOTE_FW_55;
            7'd56: note_fw = NOTE_FW_56;
            7'd57: note_fw = NOTE_FW_57;
            7'd58: note_fw = NOTE_FW_58;
            7'd59: note_fw = NOTE_FW_59;
            7'd60: note_fw = NOTE_FW_60;
            7'd61: note_fw = NOTE_FW_61;
            7'd62: note_fw = NOTE_FW_62;
            7'd63: note_fw = NOTE_FW_63;
            7'd64: note_fw = NOTE_FW_64;
            7'd65: note_fw = NOTE_FW_65;
            7'd66: note_fw = NOTE_FW_66;
            7'd67: note_fw = NOTE_FW_67;
            7'd68: note_fw = NOTE_FW_68;
            7'd69: note_fw = NOTE_FW_69;
            7'd70: note_fw = NOTE_FW_70;
            7'd71: note_fw = NOTE_FW_71;
            7'd72: note_fw = NOTE_FW_72;
            7'd73: note_fw = NOTE_FW_73;
            7'd74: note_fw = NOTE_FW_74;
            7'd75: note_fw = NOTE_FW_75;
            7'd76: note_fw = NOTE_FW_76;
            7'd77: note_fw = NOTE_FW_77;
            7'd78: note_fw = NOTE_FW_78;
            7'd79: note_fw = NOTE_FW_79;
            7'd80: note_fw = NOTE_FW_80;
            7'd81: note_fw = NOTE_FW_81;
            7'd82: note_fw = NOTE_FW_82;
            7'd83: note_fw = NOTE_FW_83;
            7'd84: note_fw = NOTE_FW_84;
            7'd85: note_fw = NOTE_FW_85;
            7'd86: note_fw = NOTE_FW_86;
            7'd87: note_fw = NOTE_FW_87;
            7'd88: note_fw = NOTE_FW_88;
            7'd89: note_fw = NOTE_FW_89;
            7'd90: note_fw = NOTE_FW_90;
            7'd91: note_fw = NOTE_FW_91;
            7'd92: note_fw = NOTE_FW_92;
            7'd93: note_fw = NOTE_FW_93;
            7'd94: note_fw = NOTE_FW_94;
            7'd95: note_fw = NOTE_FW_95;
            7'd96: note_fw = NOTE_FW_96;
            default: note_fw = 32'd0;
        endcase
    end
endfunction

localparam integer NOTE_LO = 36;
localparam integer NOTE_HI = 96;

`endif
