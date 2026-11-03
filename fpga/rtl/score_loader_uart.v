// ---------------------------------------------------------------------------
// score_loader_uart.v —— 串口/蓝牙曲谱下载器
//
//  本模块现在只是 "uart_rx + score_loader_core" 的薄封装：
//  协议解析与校验全部在 score_loader_core.v 里，与 SD 卡通道共用同一份实现，
//  保证两条通道行为完全一致（不会出现"蓝牙能用、SD 卡解析不一致"）。
//
//  行为与原版本逐字节等价：同样的状态机、同样的越界判定、
//  同样的 load_we / load_commit 单拍互斥脉冲。
//
// 装载协议见 score_loader_core.v 顶部说明。
// ---------------------------------------------------------------------------
module score_loader_uart #(
    parameter integer CLK_PER_BIT = 434      // 50 MHz / 115200；35MHz 用 304
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,                   // 蓝牙模块 TXD 或 USB-UART TX

    output wire        load_we,              // 单拍脉冲
    output wire [7:0]  load_addr,
    output wire [6:0]  load_note,
    output wire [3:0]  load_length,
    output wire        load_commit,          // 单拍脉冲
    output wire [7:0]  load_count,
    output wire [7:0]  load_bpm,

    output wire        frame_done,           // 收到一条完整命令
    output wire        commit_accept,        // 校验通过并已提交
    output wire [2:0]  err_code,             // 1 同步错 2 未知命令 3 参数越界
    output wire [7:0]  err_count,
    output wire [7:0]  recv_count
);
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_rx(
        .clk(clk), .rst_n(rst_n), .rx(rx),
        .data(rx_data), .valid(rx_valid));

    score_loader_core u_core(
        .clk(clk), .rst_n(rst_n),
        .byte_data(rx_data), .byte_valid(rx_valid),
        .load_we(load_we), .load_addr(load_addr), .load_note(load_note),
        .load_length(load_length), .load_commit(load_commit),
        .load_count(load_count), .load_bpm(load_bpm),
        .frame_done(frame_done), .commit_accept(commit_accept),
        .err_code(err_code), .err_count(err_count), .recv_count(recv_count));

endmodule
