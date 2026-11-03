`timescale 1ns/1ps
// Single-master, 7-bit-address I2C register engine. NO push-pull high drives.
// One byte write, or one/two byte read using a repeated START.
// Inputs must be the actual bus levels; external pull-ups are required.
// Error: 0=OK, 1=NACK, 2=bus/clock timeout, 3=lost arbitration/bus conflict.
module i2c_register_master #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BUS_HZ = 100000,
    parameter integer TIMEOUT_US = 2000
) (
    input wire clk, input wire reset_n,
    input wire start, input wire [6:0] address,
    input wire [7:0] register_address, input wire [7:0] write_data,
    input wire read_request, input wire read_two_bytes,
    input wire scl_in, input wire sda_in,
    output reg scl_drive_low, output reg sda_drive_low,
    output reg busy, output reg done, output reg [2:0] error,
    output reg [15:0] read_data
);
    localparam integer QUARTER = (CLK_HZ + 4*BUS_HZ - 1)/(4*BUS_HZ);
    localparam integer LOW_CYCLES = 2*QUARTER;
    localparam integer TIMEOUT_CYCLES = ((CLK_HZ/1000)*TIMEOUT_US)/1000;
    localparam [4:0] IDLE=0, START_WAIT=1, START_HOLD=2, BIT_LOW=3,
        BIT_HIGH_WAIT=4, BIT_HIGH_HOLD=5, ACK_LOW=6, ACK_HIGH_WAIT=7,
        ACK_HIGH_HOLD=8, RESTART_LOW=9, RESTART_WAIT=10, STOP_LOW=11,
        STOP_WAIT=12, STOP_HOLD=13;
    reg [4:0] state;
    reg [31:0] timer, watchdog;
    reg [1:0] scl_sync, sda_sync;
    reg [6:0] saved_address;
    reg [7:0] saved_register, saved_write, tx_byte, rx_byte;
    reg saved_read, saved_two, reading, rx_second;
    reg [2:0] bit_number;
    reg [1:0] stage;
    reg nack_seen;
    wire scl_level = scl_sync[1];
    wire sda_level = sda_sync[1];
    wire stalled = (!scl_drive_low && !scl_level) ||
        ((state==START_WAIT || state==RESTART_WAIT || state==STOP_HOLD) && !sda_level);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin scl_sync<=2'b11; sda_sync<=2'b11; end
        else begin scl_sync<={scl_sync[0],scl_in}; sda_sync<={sda_sync[0],sda_in}; end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=IDLE; timer<=0; watchdog<=0; busy<=0; done<=0; error<=0;
            read_data<=0; scl_drive_low<=0; sda_drive_low<=0;
            saved_address<=0; saved_register<=0; saved_write<=0;
            saved_read<=0; saved_two<=0; reading<=0; rx_second<=0;
            tx_byte<=0; rx_byte<=0; bit_number<=7; stage<=0; nack_seen<=0;
        end else begin
            done<=0;
            if (busy && stalled) watchdog<=watchdog+1;
            else watchdog<=0;
            if (busy && stalled && watchdog>=TIMEOUT_CYCLES-1) begin
                // A STOP is impossible with a physically stuck line. Release both
                // wires, report failure, and let the owner reinitialise later.
                scl_drive_low<=0; sda_drive_low<=0; busy<=0; done<=1;
                error<=2; read_data<=0; state<=IDLE; timer<=0; watchdog<=0;
            end else case (state)
                IDLE: begin
                    scl_drive_low<=0; sda_drive_low<=0; timer<=0;
                    if (start) begin
                        saved_address<=address; saved_register<=register_address;
                        saved_write<=write_data; saved_read<=read_request;
                        saved_two<=read_two_bytes; busy<=1; error<=0; read_data<=0;
                        stage<=0; reading<=0; rx_second<=0; nack_seen<=0;
                        state<=START_WAIT;
                    end
                end
                START_WAIT: begin
                    if (scl_level && sda_level) begin
                        if (timer>=LOW_CYCLES-1) begin
                            sda_drive_low<=1; timer<=0; state<=START_HOLD;
                        end else timer<=timer+1;
                    end else timer<=0;
                end
                START_HOLD: begin
                    // Standard-mode START hold >=4us at100kHz.
                    if (timer>=LOW_CYCLES-1) begin
                        scl_drive_low<=1; timer<=0; bit_number<=7;
                        tx_byte <= (stage==3) ? {saved_address,1'b1} : {saved_address,1'b0};
                        state<=BIT_LOW;
                    end else timer<=timer+1;
                end
                BIT_LOW: begin
                    sda_drive_low <= reading ? 1'b0 : ~tx_byte[bit_number];
                    if (timer>=LOW_CYCLES-1) begin
                        scl_drive_low<=0; timer<=0; state<=BIT_HIGH_WAIT;
                    end else timer<=timer+1;
                end
                BIT_HIGH_WAIT: begin
                    if (scl_level) begin
                        if (timer>=QUARTER-1) begin
                            if (reading) rx_byte<={rx_byte[6:0],sda_level};
                            if (!reading && tx_byte[bit_number] && !sda_level) begin
                                // We intended a released '1' but saw '0'. Do not
                                // issue STOP into another master's transaction.
                                error<=3; read_data<=0; busy<=0; done<=1;
                                scl_drive_low<=0; sda_drive_low<=0; state<=IDLE;
                            end else state<=BIT_HIGH_HOLD;
                            timer<=0;
                        end else timer<=timer+1;
                    end else timer<=0;
                end
                BIT_HIGH_HOLD: begin
                    if (timer>=QUARTER-1) begin
                        scl_drive_low<=1; timer<=0;
                        if (bit_number==0) state<=ACK_LOW;
                        else begin bit_number<=bit_number-1; state<=BIT_LOW; end
                    end else timer<=timer+1;
                end
                ACK_LOW: begin
                    // ACK first read byte iff another byte is requested. Last
                    // read byte is NACKed by releasing SDA (not driving high).
                    sda_drive_low<=reading && saved_two && !rx_second;
                    if (timer>=LOW_CYCLES-1) begin
                        scl_drive_low<=0; timer<=0; state<=ACK_HIGH_WAIT;
                    end else timer<=timer+1;
                end
                ACK_HIGH_WAIT: begin
                    if (scl_level) begin
                        if (timer>=QUARTER-1) begin
                            if (!reading && sda_level) begin nack_seen<=1; error<=1; end
                            timer<=0; state<=ACK_HIGH_HOLD;
                        end else timer<=timer+1;
                    end else timer<=0;
                end
                ACK_HIGH_HOLD: begin
                    if (timer>=QUARTER-1) begin
                        scl_drive_low<=1; timer<=0; bit_number<=7;
                        if (nack_seen) begin read_data<=0; state<=STOP_LOW; end
                        else if (reading) begin
                            if (rx_second) read_data[15:8]<=rx_byte;
                            else read_data[7:0]<=rx_byte;
                            if (saved_two && !rx_second) begin
                                rx_second<=1; rx_byte<=0; state<=BIT_LOW;
                            end else state<=STOP_LOW;
                        end else case (stage)
                            0: begin stage<=1; tx_byte<=saved_register; state<=BIT_LOW; end
                            1: if (saved_read) begin stage<=3; state<=RESTART_LOW; end
                               else begin stage<=2; tx_byte<=saved_write; state<=BIT_LOW; end
                            2: state<=STOP_LOW;
                            3: begin reading<=1; rx_byte<=0; state<=BIT_LOW; end
                        endcase
                    end else timer<=timer+1;
                end
                RESTART_LOW: begin
                    sda_drive_low<=0;
                    if (timer>=LOW_CYCLES-1) begin
                        scl_drive_low<=0; timer<=0; state<=RESTART_WAIT;
                    end else timer<=timer+1;
                end
                RESTART_WAIT: begin
                    if (scl_level && sda_level) begin
                        // Standard-mode repeated START setup >=4.7us.
                        if (timer>=LOW_CYCLES-1) begin
                            sda_drive_low<=1; timer<=0; state<=START_HOLD;
                        end else timer<=timer+1;
                    end else timer<=0;
                end
                STOP_LOW: begin
                    sda_drive_low<=1;
                    if (timer>=LOW_CYCLES-1) begin
                        scl_drive_low<=0; timer<=0; state<=STOP_WAIT;
                    end else timer<=timer+1;
                end
                STOP_WAIT: begin
                    if (scl_level) begin
                        if (timer>=LOW_CYCLES-1) begin
                            sda_drive_low<=0; timer<=0; state<=STOP_HOLD;
                        end else timer<=timer+1;
                    end else timer<=0;
                end
                STOP_HOLD: begin
                    if (scl_level && sda_level) begin
                        if (timer>=LOW_CYCLES-1) begin
                            busy<=0; done<=1; state<=IDLE; timer<=0;
                        end else timer<=timer+1;
                    end else timer<=0;
                end
                default: begin state<=IDLE; busy<=0; error<=3; done<=1; end
            endcase
        end
    end
endmodule
