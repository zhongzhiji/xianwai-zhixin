`timescale 1ns/1ps
// A wire-level I2C slave model, no DUT hierarchy accesses or forced signals.
// Only the bench-controlled presence, status and external bus faults are used.
module mpr121_slave_model #(
    parameter [6:0] ADDRESS=7'h5a
)(
    inout wire scl, inout wire sda,
    input wire present, input wire nack_read_address,
    input wire [15:0] touch_status,
    input wire hold_scl_low, input wire hold_sda_low,
    output integer writes, output integer reads, output integer starts,
    output integer stops, output integer read_acks, output integer read_nacks
);
    reg drive_low=0;
    assign scl=hold_scl_low ? 1'b0 : 1'bz;
    assign sda=(drive_low || hold_sda_low) ? 1'b0 : 1'bz;
    reg [7:0] registers[0:127];
    reg [7:0] write_register_log[0:511], write_value_log[0:511];
    reg [7:0] shift=0, pointer=0, tx_byte=0;
    integer bit_count=0, destination=0, ack_stage=0, mode=0;
    integer next_destination=0, next_mode=0;
    reg active=0, ack_value=0, read_ack=0;
    integer index;
    // mode0=receive,1=send,2=masterACK,3=awaitSTOP; destination0=addr,1=reg,2=data.
    function [7:0] value_at;
        input [7:0] reg_index;
        begin
            if(reg_index==0) value_at=touch_status[7:0];
            else if(reg_index==1) value_at=touch_status[15:8];
            else if(reg_index<128) value_at=registers[reg_index];
            else value_at=0;
        end
    endfunction

    initial begin
        writes=0; reads=0; starts=0; stops=0; read_acks=0; read_nacks=0;
        for(index=0;index<128;index=index+1) registers[index]=0;
        registers[8'h5d]=8'h24;
    end
    always @(negedge sda) if(scl===1'b1 && !hold_sda_low) begin
        active=1; starts=starts+1; drive_low=0;
        mode=0; destination=0; bit_count=0; ack_stage=0; shift=0;
    end
    always @(posedge sda) if(scl===1'b1) begin
        active=0; stops=stops+1; drive_low=0; ack_stage=0;
    end

    always @(posedge scl) if(active) begin
        if(ack_stage==1) ack_stage=2;
        else if(mode==0 && ack_stage==0) begin
            shift={shift[6:0],sda};
            if(bit_count==7) begin
                ack_value=1; next_mode=0;
                case(destination)
                    0: begin
                        ack_value=present && shift[7:1]==ADDRESS && !(shift[0] && nack_read_address);
                        if(shift[0]) next_mode=1;
                        next_destination=1;
                    end
                    1: begin pointer=shift; next_destination=2; end
                    2: begin
                        if(writes>=512) $fatal(1,"slave write log overflow");
                        write_register_log[writes]=pointer;
                        write_value_log[writes]=shift; writes=writes+1;
                        if(pointer==8'h80 && shift==8'h63) begin
                            for(index=0;index<128;index=index+1) registers[index]=0;
                            registers[8'h5d]=8'h24;
                        end else if(pointer<128) begin
                            if(pointer!=8'h5e && registers[8'h5e][3:0]!=0)
                                $fatal(1,"configuration written while electrodes running");
                            registers[pointer]=shift;
                        end
                        pointer=pointer+1; next_destination=2;
                    end
                endcase
                bit_count=0; ack_stage=3; // waiting first falling edge to drive ACK
            end else bit_count=bit_count+1;
        end else if(mode==1) begin
            if(bit_count==7) begin bit_count=8; reads=reads+1; end
            else bit_count=bit_count+1;
        end else if(mode==2) begin
            read_ack=(sda===1'b0);
            if(read_ack) read_acks=read_acks+1;
            else read_nacks=read_nacks+1;
            bit_count=1; // flag ACK sampling occurred
        end
    end
    always @(negedge scl) if(active) begin
        if(ack_stage==3) begin drive_low=ack_value; ack_stage=1; end
        else if(ack_stage==2) begin
            drive_low=0; ack_stage=0; bit_count=0; shift=0;
            destination=next_destination; mode=ack_value ? next_mode : 3;
            if(mode==1) begin tx_byte=value_at(pointer); drive_low=~tx_byte[7]; end
        end else if(mode==1) begin
            if(bit_count==8) begin drive_low=0; bit_count=0; mode=2; end
            else drive_low=~tx_byte[7-bit_count];
        end else if(mode==2 && bit_count==1) begin
            if(read_ack) begin
                pointer=pointer+1; tx_byte=value_at(pointer);
                bit_count=0; mode=1; drive_low=~tx_byte[7];
            end else begin mode=3; drive_low=0; end
        end
    end
endmodule
