`timescale 1ns/1ps
// No FPGA pad assignments. Bind these open-drain inouts ONLY after checking
// Tang Mega 138K bank VCCIO, header schematic and 3.3V external pull-ups.
module mpr121_input #(
    parameter integer CLK_HZ=50000000,
    parameter integer I2C_HZ=100000,
    parameter [6:0] I2C_ADDRESS=7'h5a,
    parameter integer POLL_US=2000,
    parameter integer BUS_TIMEOUT_US=2000,
    parameter integer POWER_WAIT_MS=20,
    parameter integer RESET_WAIT_MS=1,
    parameter integer SETTLE_MS=20,
    parameter integer RETRY_MS=100,
    parameter [7:0] TOUCH_THRESHOLD=8'd12,
    parameter [7:0] RELEASE_THRESHOLD=8'd6
)(
    input wire clk, input wire reset_n,
    inout wire scl, inout wire sda,
    output reg [11:0] touched,
    output reg [11:0] press_event, output reg [11:0] release_event,
    output reg sample_valid, output reg online, output reg fault,
    output reg clear_event, output reg error_event,
    output reg [2:0] fault_code
);
    localparam integer POLL_CYCLES=(CLK_HZ/1000000)*POLL_US;
    localparam integer POWER_CYCLES=(CLK_HZ/1000)*POWER_WAIT_MS;
    localparam integer RESET_CYCLES=(CLK_HZ/1000)*RESET_WAIT_MS;
    localparam integer SETTLE_CYCLES=(CLK_HZ/1000)*SETTLE_MS;
    localparam integer RETRY_CYCLES=(CLK_HZ/1000)*RETRY_MS;
    localparam [3:0] BOOT=0, INIT_START=1, INIT_WAIT=2, RESET_DELAY=3,
        SETTLE=4, POLL_IDLE=5, POLL_START=6, POLL_WAIT=7, RETRY=8;
    reg [3:0] state;
    reg [31:0] delay_count, poll_count;
    reg [5:0] init_index;
    reg bus_start, bus_read, bus_two;
    reg [7:0] bus_register, bus_write;
    wire scl_low, sda_low, bus_busy, bus_done;
    wire [2:0] bus_error;
    wire [15:0] bus_data;
    assign scl=scl_low ? 1'b0 : 1'bz;
    assign sda=sda_low ? 1'b0 : 1'bz;
    i2c_register_master #(.CLK_HZ(CLK_HZ), .BUS_HZ(I2C_HZ), .TIMEOUT_US(BUS_TIMEOUT_US))
        master(.clk(clk),.reset_n(reset_n),.start(bus_start),.address(I2C_ADDRESS),
        .register_address(bus_register),.write_data(bus_write),.read_request(bus_read),
        .read_two_bytes(bus_two),.scl_in(scl),.sda_in(sda),
        .scl_drive_low(scl_low),.sda_drive_low(sda_low),.busy(bus_busy),
        .done(bus_done),.error(bus_error),.read_data(bus_data));

    // Independent implementation using documented register values.
    // Datasheet: https://www.nxp.com/docs/en/data-sheet/MPR121.pdf Rev4, sections5.6-5.13.
    // Baseline filter starting values: Adafruit's official MPR121 driver begin().
    // These starting values are NOT electrode-specific calibration or noise proof.
    function [15:0] init_command;
        input [5:0] index;
        begin
            case(index)
                0: init_command=16'h8063; // soft reset
                1: init_command=16'h5d00; // READ reset CONFIG2, expected 0x24
                2: init_command=16'h5e00; // stop before writing configuration
                3: init_command=16'h2b01;
                4: init_command=16'h2c01;
                5: init_command=16'h2d0e;
                6: init_command=16'h2e00;
                7: init_command=16'h2f01;
                8: init_command=16'h3005;
                9: init_command=16'h3101;
                10: init_command=16'h3200;
                11: init_command=16'h3300;
                12: init_command=16'h3400;
                13: init_command=16'h3500;
                38: init_command=16'h5b00; // no extra debounce, use hysteresis+filters
                39: init_command=16'h5c10; // FFI6, global current16uA
                40: init_command=16'h5d20; // 0.5us charge, SFI4, ESI1ms
                41: init_command=16'h5e8f; // CL=10, proximity0, ELE_EN=11xx => all12
                42: init_command=16'h5e00; // READ back ECR, expected0x8f
                default: begin
                    init_command[15:8]=8'h41+(index-14);
                    init_command[7:0]=index[0] ? RELEASE_THRESHOLD : TOUCH_THRESHOLD;
                end
            endcase
        end
    endfunction

    wire [15:0] init_word=init_command(init_index);
    wire init_bad_read=(init_index==1 && bus_data[7:0]!=8'h24) ||
        (init_index==42 && bus_data[7:0]!=8'h8f);
    // Invalidate held notes on ANY failed transaction. A release due to a bus
    // fault has sample_valid=0; clear_event/error_event explicitly identify it.
    task fail_safe;
        input [2:0] code;
        begin
            release_event<=touched; touched<=0; press_event<=0;
            sample_valid<=0; online<=0; fault<=1; fault_code<=code;
            clear_event<=1; error_event<=1; delay_count<=RETRY_CYCLES;
            state<=RETRY;
        end
    endtask

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=BOOT; delay_count<=POWER_CYCLES; poll_count<=0; init_index<=0;
            bus_start<=0; bus_read<=0; bus_two<=0; bus_register<=0; bus_write<=0;
            touched<=0; press_event<=0; release_event<=0; sample_valid<=0;
            online<=0; fault<=0; fault_code<=0; clear_event<=0; error_event<=0;
        end else begin
            bus_start<=0; press_event<=0; release_event<=0; sample_valid<=0;
            clear_event<=0; error_event<=0;
            if(poll_count!=0) poll_count<=poll_count-1;
            case(state)
                BOOT, RETRY: begin
                    if(delay_count!=0) delay_count<=delay_count-1;
                    else begin init_index<=0; state<=INIT_START; end
                end
                INIT_START: if(!bus_busy) begin
                    bus_register<=init_word[15:8]; bus_write<=init_word[7:0];
                    bus_read<=(init_index==1 || init_index==42); bus_two<=0;
                    bus_start<=1; state<=INIT_WAIT;
                end
                INIT_WAIT: if(bus_done) begin
                    if(bus_error!=0) fail_safe(bus_error);
                    else if(init_bad_read) fail_safe(3'd5);
                    else if(init_index==0) begin
                        delay_count<=RESET_CYCLES; init_index<=1; state<=RESET_DELAY;
                    end else if(init_index==42) begin
                        delay_count<=SETTLE_CYCLES; state<=SETTLE;
                    end else begin init_index<=init_index+1; state<=INIT_START; end
                end
                RESET_DELAY: begin
                    if(delay_count!=0) delay_count<=delay_count-1;
                    else state<=INIT_START;
                end
                SETTLE: begin
                    if(delay_count!=0) delay_count<=delay_count-1;
                    else begin poll_count<=0; state<=POLL_IDLE; end
                end
                POLL_IDLE: if(poll_count==0) state<=POLL_START;
                POLL_START: if(!bus_busy) begin
                    bus_register<=8'h00; bus_write<=0; bus_read<=1; bus_two<=1;
                    bus_start<=1; poll_count<=POLL_CYCLES; state<=POLL_WAIT;
                end
                POLL_WAIT: if(bus_done) begin
                    if(bus_error!=0) fail_safe(bus_error);
                    else if(bus_data[15]) fail_safe(3'd4); // OVCF is NOT a touch
                    else begin
                        press_event<=bus_data[11:0]&~touched;
                        release_event<=touched&~bus_data[11:0];
                        touched<=bus_data[11:0]; sample_valid<=1; online<=1;
                        fault<=0; fault_code<=0; state<=POLL_IDLE;
                    end
                end
                default: fail_safe(3'd5);
            endcase
        end
    end
endmodule
