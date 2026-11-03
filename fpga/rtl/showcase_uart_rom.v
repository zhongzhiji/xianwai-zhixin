`timescale 1ns/1ps
// Full 8N1 waveform through the unmodified UART and score parser, no load-bus bypass.
module showcase_uart_rom #(parameter integer CLK_PER_BIT=304)(
    input wire clk,reset_n,start, output reg tx,busy,done
);
    localparam integer N_BYTES=126;
    reg [15:0] count; reg [9:0] shift;
    reg [3:0] bit_index; reg [8:0] addr;
    function [7:0] byte_at; input [8:0] index; begin case(index)
            0: byte_at=8'h55;
            1: byte_at=8'h4c;
            2: byte_at=8'h18;
            3: byte_at=8'h78;
            4: byte_at=8'h55;
            5: byte_at=8'h57;
            6: byte_at=8'h00;
            7: byte_at=8'h43;
            8: byte_at=8'h04;
            9: byte_at=8'h55;
            10: byte_at=8'h57;
            11: byte_at=8'h01;
            12: byte_at=8'h40;
            13: byte_at=8'h04;
            14: byte_at=8'h55;
            15: byte_at=8'h57;
            16: byte_at=8'h02;
            17: byte_at=8'h40;
            18: byte_at=8'h04;
            19: byte_at=8'h55;
            20: byte_at=8'h57;
            21: byte_at=8'h03;
            22: byte_at=8'h41;
            23: byte_at=8'h04;
            24: byte_at=8'h55;
            25: byte_at=8'h57;
            26: byte_at=8'h04;
            27: byte_at=8'h3e;
            28: byte_at=8'h04;
            29: byte_at=8'h55;
            30: byte_at=8'h57;
            31: byte_at=8'h05;
            32: byte_at=8'h3e;
            33: byte_at=8'h04;
            34: byte_at=8'h55;
            35: byte_at=8'h57;
            36: byte_at=8'h06;
            37: byte_at=8'h3c;
            38: byte_at=8'h04;
            39: byte_at=8'h55;
            40: byte_at=8'h57;
            41: byte_at=8'h07;
            42: byte_at=8'h3e;
            43: byte_at=8'h04;
            44: byte_at=8'h55;
            45: byte_at=8'h57;
            46: byte_at=8'h08;
            47: byte_at=8'h40;
            48: byte_at=8'h04;
            49: byte_at=8'h55;
            50: byte_at=8'h57;
            51: byte_at=8'h09;
            52: byte_at=8'h41;
            53: byte_at=8'h04;
            54: byte_at=8'h55;
            55: byte_at=8'h57;
            56: byte_at=8'h0a;
            57: byte_at=8'h43;
            58: byte_at=8'h04;
            59: byte_at=8'h55;
            60: byte_at=8'h57;
            61: byte_at=8'h0b;
            62: byte_at=8'h43;
            63: byte_at=8'h04;
            64: byte_at=8'h55;
            65: byte_at=8'h57;
            66: byte_at=8'h0c;
            67: byte_at=8'h43;
            68: byte_at=8'h04;
            69: byte_at=8'h55;
            70: byte_at=8'h57;
            71: byte_at=8'h0d;
            72: byte_at=8'h43;
            73: byte_at=8'h04;
            74: byte_at=8'h55;
            75: byte_at=8'h57;
            76: byte_at=8'h0e;
            77: byte_at=8'h40;
            78: byte_at=8'h04;
            79: byte_at=8'h55;
            80: byte_at=8'h57;
            81: byte_at=8'h0f;
            82: byte_at=8'h40;
            83: byte_at=8'h04;
            84: byte_at=8'h55;
            85: byte_at=8'h57;
            86: byte_at=8'h10;
            87: byte_at=8'h41;
            88: byte_at=8'h04;
            89: byte_at=8'h55;
            90: byte_at=8'h57;
            91: byte_at=8'h11;
            92: byte_at=8'h3e;
            93: byte_at=8'h04;
            94: byte_at=8'h55;
            95: byte_at=8'h57;
            96: byte_at=8'h12;
            97: byte_at=8'h3e;
            98: byte_at=8'h04;
            99: byte_at=8'h55;
            100: byte_at=8'h57;
            101: byte_at=8'h13;
            102: byte_at=8'h3c;
            103: byte_at=8'h04;
            104: byte_at=8'h55;
            105: byte_at=8'h57;
            106: byte_at=8'h14;
            107: byte_at=8'h40;
            108: byte_at=8'h04;
            109: byte_at=8'h55;
            110: byte_at=8'h57;
            111: byte_at=8'h15;
            112: byte_at=8'h43;
            113: byte_at=8'h04;
            114: byte_at=8'h55;
            115: byte_at=8'h57;
            116: byte_at=8'h16;
            117: byte_at=8'h43;
            118: byte_at=8'h04;
            119: byte_at=8'h55;
            120: byte_at=8'h57;
            121: byte_at=8'h17;
            122: byte_at=8'h40;
            123: byte_at=8'h08;
            124: byte_at=8'h55;
            125: byte_at=8'h43;
            default:byte_at=8'hff;
    endcase end endfunction
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin tx<=1;busy<=0;done<=0;count<=0;shift<=10'h3ff;bit_index<=0;addr<=0;end
        else begin
            done<=0;
            if(start && !busy) begin
                busy<=1;addr<=0;bit_index<=0;count<=0;tx<=0;
                shift<={1'b1,byte_at(0),1'b0};
            end else if(busy) begin
                if(count==CLK_PER_BIT-1) begin
                    count<=0;
                    if(bit_index==9) begin
                        if(addr==N_BYTES-1) begin busy<=0;done<=1;tx<=1;end
                        else begin addr<=addr+1'b1;bit_index<=0;shift<={1'b1,byte_at(addr+1'b1),1'b0};tx<=0;end
                    end else begin bit_index<=bit_index+1'b1;shift<={1'b1,shift[9:1]};tx<=shift[1];end
                end else count<=count+1'b1;
            end
        end
    end
endmodule
