`timescale 1ns/1ps
// ============================================================================
//  mpr121_sequencer.v
//
//  单颗 MPR121 的寄存器时序器 —— 与外部 I2C 主机解耦，便于多颗 MPR121
//  通过仲裁器共享同一条 SCL/SDA。
//
//  与 rtl/mpr121_input.v 的关系：
//    mpr121_input.v = 本文件 + i2c_register_master 的单体封装（已在
//    16_mpr121_input 中通过总线级仿真）。本文件把那套已验证的状态机原样
//    搬过来，只把"直接驱动总线"换成"请求 / 授权"握手：
//      - req 是**电平**，从发起事务一直保持到收到 xfer_done；
//      - 仲裁器选中本时序器后拉高 grant，并在事务结束时给一拍 xfer_done；
//      - 未被授权的时序器收不到 xfer_done，会安静地等在原地，不会抢总线。
//
//  初始化序列（NXP MPR121 Datasheet Rev4, sections 5.6..5.13）:
//    上电 20ms → 0x80←0x63 软复位 → 1ms → 读 0x5D 期望 0x24
//    → 0x5E←0x00 停扫描 → 0x2B..0x35 基线滤波 → 0x41..0x58 逐电极阈值(12/6)
//    → 0x5B=0, 0x5C=0x10, 0x5D=0x20, 0x5E=0x8F → 回读 0x5E 期望 0x8F
//    → 20ms → 从 0x00 重复 START 读 2 字节（低字节 ELE0..7，高字节低 4bit ELE8..11）
//
//  安全语义（与 music 层对接的关键）：
//    * 高字节 bit7 是 OVCF 过流位，**不是按键**，出现即判故障。
//    * 任何一次事务失败都会清 touched，并对所有仍按住的键补发 release_event；
//      此时 sample_valid=0，music 层必须独立消费 clear_event，
//      不能只在 sample_valid 时处理 release，否则掉线会留下悬挂音。
// ============================================================================
module mpr121_sequencer #(
    parameter integer CLK_HZ             = 50000000,
    parameter integer POLL_US            = 2000,
    parameter integer POWER_WAIT_MS      = 20,
    parameter integer RESET_WAIT_MS      = 1,
    parameter integer SETTLE_MS          = 20,
    parameter integer RETRY_MS           = 100,
    parameter [7:0]   TOUCH_THRESHOLD    = 8'd12,
    parameter [7:0]   RELEASE_THRESHOLD  = 8'd6,
    parameter [6:0]   I2C_ADDRESS        = 7'h5a
)(
    input  wire        clk,
    input  wire        reset_n,

    // ---- 面向共享 I2C 主机的请求通道 ----
    output reg         req,               // 电平：请求一次事务，直到 xfer_done
    output wire [6:0]  req_address,
    output wire [7:0]  req_register,
    output wire [7:0]  req_write,
    output reg         req_read,
    output reg         req_two,
    input  wire        xfer_done,         // 仅当本时序器持有总线时才会有脉冲
    input  wire [2:0]  xfer_error,
    input  wire [15:0] xfer_data,
    input  wire        poll_now,          // IRQ 有效：轮询间隔减半（限流，不饱和总线）

    // ---- 结果 ----
    output reg  [11:0] touched,
    output reg  [11:0] press_event,
    output reg  [11:0] release_event,
    output reg         sample_valid,
    output reg         online,
    output reg         fault,
    output reg         clear_event,
    output reg         error_event,
    output reg  [2:0]  fault_code
);
    localparam integer POLL_CYCLES   = (CLK_HZ/1000000)*POLL_US;
    localparam integer POWER_CYCLES  = (CLK_HZ/1000)*POWER_WAIT_MS;
    localparam integer RESET_CYCLES  = (CLK_HZ/1000)*RESET_WAIT_MS;
    localparam integer SETTLE_CYCLES = (CLK_HZ/1000)*SETTLE_MS;
    localparam integer RETRY_CYCLES  = (CLK_HZ/1000)*RETRY_MS;

    localparam [3:0] BOOT=0, INIT_START=1, INIT_WAIT=2, RESET_DELAY=3,
                     SETTLE=4, POLL_IDLE=5, POLL_START=6, POLL_WAIT=7, RETRY=8;

    reg [3:0]   state;
    reg [31:0]  delay_count, poll_count;
    reg [5:0]   init_index;
    reg [7:0]   reg_addr, reg_wdata;

    function [15:0] init_command;
        input [5:0] index;
        begin
            case(index)
                0:  init_command = 16'h8063;   // soft reset
                1:  init_command = 16'h5d00;   // READ CONFIG2, expect 0x24
                2:  init_command = 16'h5e00;   // stop before configuring
                3:  init_command = 16'h2b01;
                4:  init_command = 16'h2c01;
                5:  init_command = 16'h2d0e;
                6:  init_command = 16'h2e00;
                7:  init_command = 16'h2f01;
                8:  init_command = 16'h3005;
                9:  init_command = 16'h3101;
                10: init_command = 16'h3200;
                11: init_command = 16'h3300;
                12: init_command = 16'h3400;
                13: init_command = 16'h3500;
                38: init_command = 16'h5b00;
                39: init_command = 16'h5c10;   // FFI6, 16uA
                40: init_command = 16'h5d20;   // 0.5us, SFI4, ESI 1ms
                41: init_command = 16'h5e8f;   // CL=10, prox0, ELE_EN=11xx => 12 elec
                42: init_command = 16'h5e00;   // READ back ECR, expect 0x8f
                default: begin
                    init_command[15:8] = 8'h41 + (index - 14);
                    init_command[7:0]  = index[0] ? RELEASE_THRESHOLD : TOUCH_THRESHOLD;
                end
            endcase
        end
    endfunction

    wire [15:0] init_word    = init_command(init_index);
    wire        init_is_read = (init_index == 1) || (init_index == 42);
    wire        init_bad_read = (init_index == 1  && xfer_data[7:0] != 8'h24) ||
                                (init_index == 42 && xfer_data[7:0] != 8'h8f);

    assign req_address  = I2C_ADDRESS;
    assign req_register = (state == INIT_START || state == INIT_WAIT) ? reg_addr   : 8'h00;
    assign req_write    = (state == INIT_START || state == INIT_WAIT) ? reg_wdata  : 8'h00;

    task fail_safe;
        input [2:0] code;
        begin
            release_event <= touched;
            touched       <= 12'd0;
            press_event   <= 12'd0;
            sample_valid  <= 1'b0;
            online        <= 1'b0;
            fault         <= 1'b1;
            fault_code    <= code;
            clear_event   <= 1'b1;
            error_event   <= 1'b1;
            delay_count   <= RETRY_CYCLES;
            state         <= RETRY;
        end
    endtask

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= BOOT; delay_count <= POWER_CYCLES; poll_count <= 32'd0;
            init_index <= 6'd0; req <= 1'b0; req_read <= 1'b0; req_two <= 1'b0;
            reg_addr <= 8'd0; reg_wdata <= 8'd0;
            touched <= 12'd0; press_event <= 12'd0; release_event <= 12'd0;
            sample_valid <= 1'b0; online <= 1'b0; fault <= 1'b0;
            clear_event <= 1'b0; error_event <= 1'b0; fault_code <= 3'd0;
        end else begin
            req          <= 1'b0;
            press_event  <= 12'd0;
            release_event<= 12'd0;
            sample_valid <= 1'b0;
            clear_event  <= 1'b0;
            error_event  <= 1'b0;
            if (poll_count != 0) poll_count <= poll_count - 1'b1;
            // req 是电平：发起事务后一直保持到收到 xfer_done，未被授权的
            // 时序器会一直停在这两个状态里等待，不会抢总线。
            if (state == INIT_WAIT || state == POLL_WAIT) req <= 1'b1;

            case (state)
                BOOT, RETRY: begin
                    if (delay_count != 0) delay_count <= delay_count - 1'b1;
                    else begin init_index <= 6'd0; state <= INIT_START; end
                end

                INIT_START: begin
                    reg_addr   <= init_word[15:8];
                    reg_wdata  <= init_word[7:0];
                    req_read   <= init_is_read;
                    req_two    <= 1'b0;
                    req        <= 1'b1;
                    state      <= INIT_WAIT;
                end

                INIT_WAIT: if (xfer_done) begin
                    if (xfer_error != 3'd0)        fail_safe(xfer_error);
                    else if (init_bad_read)        fail_safe(3'd5);
                    else if (init_index == 0) begin
                        delay_count <= RESET_CYCLES; init_index <= 6'd1; state <= RESET_DELAY;
                    end else if (init_index == 42) begin
                        delay_count <= SETTLE_CYCLES; state <= SETTLE;
                    end else begin
                        init_index <= init_index + 1'b1; state <= INIT_START;
                    end
                end

                RESET_DELAY: begin
                    if (delay_count != 0) delay_count <= delay_count - 1'b1;
                    else state <= INIT_START;
                end

                SETTLE: begin
                    if (delay_count != 0) delay_count <= delay_count - 1'b1;
                    else begin poll_count <= 32'd0; state <= POLL_IDLE; end
                end

                POLL_IDLE: if (poll_count == 0) state <= POLL_START;

                POLL_START: begin
                    reg_addr  <= 8'h00;
                    reg_wdata <= 8'h00;
                    req_read  <= 1'b1;
                    req_two   <= 1'b1;
                    req       <= 1'b1;
                    // MPR121 的 IRQ 在整个触摸期间都保持低电平。如果每次
                    // poll_now 都立刻清零 poll_count，总线会被轮询打满。
                    // 这里改成"间隔减半"：2ms → 1ms，是安全的折中。
                    poll_count<= poll_now ? (POLL_CYCLES >> 1) : POLL_CYCLES;
                    state     <= POLL_WAIT;
                end

                POLL_WAIT: if (xfer_done) begin
                    if (xfer_error != 3'd0) fail_safe(xfer_error);
                    else if (xfer_data[15]) fail_safe(3'd4);   // OVCF 不是按键
                    else begin
                        press_event   <= xfer_data[11:0] & ~touched;
                        release_event <= touched & ~xfer_data[11:0];
                        touched       <= xfer_data[11:0];
                        sample_valid  <= 1'b1;
                        online        <= 1'b1;
                        fault         <= 1'b0;
                        fault_code    <= 3'd0;
                        state         <= POLL_IDLE;
                    end
                end

                default: fail_safe(3'd5);
            endcase
        end
    end
endmodule
