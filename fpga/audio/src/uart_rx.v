// ============================================================================
//  uart_rx.v  —  8N1 串口接收（中点采样版）
// ----------------------------------------------------------------------------
//  用途：收 WAX-RX-M / RX-M 采集模块的 TXD。
//
//  为什么不用 16 倍过采样：
//    这条链路只有 115200，50MHz 下一位 = 50e6/115200 = 434.03 拍。
//    用「起点后等半位 → 每位等 1 位 → 在中点采样」的老办法，
//    434 与 434.03 的误差在 10 位内累计只有 0.007 位，完全够用，
//    而且状态机只有 4 个状态、没有过采样计数器组的面积开销。
//
//  CLK_PER_BIT：
//    115200 → 434（默认）
//    9600   → 5208   （模块若被 SETB=1 改成 9600，把 top 的参数改掉重编）
//
//  ★ 收错不锁死：start 位中点复检不是低电平就当毛刺，回 IDLE 重新等。
// ============================================================================
`timescale 1ns / 1ps

module uart_rx #(
    parameter integer CLK_PER_BIT = 434       // 50MHz / 波特率
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,        // 空闲高
    output reg  [7:0] data,
    output reg        valid      // 1 拍脉冲
);

    localparam integer HALF = CLK_PER_BIT / 2;

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;              // 最大 5208（9600）→ 16 位够
    reg [2:0]  bidx;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bidx  <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (st)
                // ── 等起始位下降沿 ─────────────────────────────────────────
                S_IDLE: begin
                    if (!rx) begin
                        cnt <= 16'd0;
                        st  <= S_START;
                    end
                end

                // ── 等半位后复检（仍是低才认）─────────────────────────────
                S_START: begin
                    if (cnt == HALF - 1) begin
                        cnt <= 16'd0;
                        if (!rx) begin
                            bidx <= 3'd0;
                            st   <= S_DATA;
                        end else begin
                            st <= S_IDLE;          // 毛刺
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // ── 每位中点采样，LSB 先出 ────────────────────────────────
                S_DATA: begin
                    if (cnt == CLK_PER_BIT - 1) begin
                        cnt <= 16'd0;
                        sh  <= {rx, sh[7:1]};
                        if (bidx == 3'd7) st   <= S_STOP;
                        else              bidx <= bidx + 3'd1;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // ── 停止位中点：高才认这帧 ────────────────────────────────
                S_STOP: begin
                    if (cnt == CLK_PER_BIT - 1) begin
                        cnt <= 16'd0;
                        if (rx) begin
                            data  <= sh;
                            valid <= 1'b1;
                        end
                        st <= S_IDLE;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
