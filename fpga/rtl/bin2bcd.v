// ---------------------------------------------------------------------------
// bin2bcd.v —— 二进制转 BCD（移位加三法，一拍移一位）
//
// 为什么不用组合逻辑直接除：24 位 ÷10 的除法器在 35 MHz（28.6 ns）下
// 会形成 30 ns 以上的组合链，是这类 UI 数字最常见的时序杀手。
// 这里改成"每拍只做一次移位 + 每位数码各一次加三校正"，
// 单拍延时就是 4 位加法器 + 4 位比较器的深度（约 2 ns），随便跑。
//
// 用法：给 start 一个 1 拍脉冲，W+1 拍之后 done 拉高 1 拍，bcd 稳定可读。
// 转换进行中再次 start 会重新开始（不会出错，只是结果延后）。
//
// 输出字节序与 ascii 显示一致：bcd[3:0] 是个位，bcd[7:4] 是十位……
// ---------------------------------------------------------------------------
module bin2bcd #(
    parameter W      = 24,     // 输入二进制位宽
    parameter DIGITS = 8       // 输出 BCD 位数（必须 >= ceil(W/3.32)）
)(
    input  wire                  clk,
    input  wire                  reset_n,
    input  wire [W-1:0]          bin_in,
    input  wire                  start,
    output reg  [4*DIGITS-1:0]   bcd,
    output reg                   done
);

    localparam TOTAL = W + 4*DIGITS;          // 移位寄存器总长
    localparam CNT_W = (W <= 2)  ? 2 :
                       (W <= 4)  ? 3 :
                       (W <= 8)  ? 4 :
                       (W <= 16) ? 5 :
                       (W <= 32) ? 6 : 7;

    reg [TOTAL-1:0] sh;
    reg [CNT_W-1:0] cnt;
    reg             busy;

    // 加三校正：该位 >4 就 +3（纯组合，4 位宽，深度极浅）
    function [3:0] add3;
        input [3:0] d;
        begin
            add3 = (d > 4'd4) ? (d + 4'd3) : d;
        end
    endfunction

    // 下一拍的移位寄存器值 = 先逐位加三，再整体左移一位
    reg [TOTAL-1:0] sh_next;
    integer i;
    always @* begin
        sh_next = sh;
        for (i = 0; i < DIGITS; i = i + 1)
            sh_next[TOTAL-1-4*i -: 4] = add3(sh_next[TOTAL-1-4*i -: 4]);
        sh_next = sh_next << 1;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sh   <= {TOTAL{1'b0}};
            cnt  <= {CNT_W{1'b0}};
            busy <= 1'b0;
            bcd  <= {4*DIGITS{1'b0}};
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start) begin
                // 二进制放低位，BCD 区清零，从头开始数 W 拍
                sh   <= {{(4*DIGITS){1'b0}}, bin_in};
                cnt  <= {CNT_W{1'b0}};
                busy <= 1'b1;
            end else if (busy) begin
                sh  <= sh_next;
                cnt <= cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                if (cnt == W[CNT_W-1:0] - 1'b1) begin
                    busy <= 1'b0;
                    bcd  <= sh_next[TOTAL-1 -: 4*DIGITS];
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
