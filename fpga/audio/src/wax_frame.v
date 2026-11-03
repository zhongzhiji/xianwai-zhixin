// ============================================================================
//  wax_frame.v  —  阵列薄膜采集模块的帧解析（双协议自动识别）v3
// ----------------------------------------------------------------------------
//  现场有两种固件，靠帧头第 2 字节区分：
//
//  ①「新协议」AA 01   （原厂《1.阵列式薄膜压力传感器用户手册》+ 测试例程）
//       35 字节 = AA 01 | 16 点 × 2 字节大端(16bit) | 校验
//       校验 = 前 34 字节累加取低 8 位
//       例（手册）：AA 01 00 4E 00 11 01 06 ... 00 08 3C
//                   点1=0x004E=78  点10=0x02BD=701  点16=0x0008=8  校验 0x3C
//
//  ②「旧协议」AA 55   （WAX-RX-M wiki + Arduino/STM32 例程）
//       54 字节 = AA 55 | 型号 | 0x30 | 16 点 × 3 字节大端(24bit) | 校验 | 0x0D
//       校验 = 数据区 48 字节累加取低 8 位
//       （例程铁证：M0404 for(k=0;k<34;k++) 累加 + RxBuffer[34]==sum）
//       例（wiki）：01 23 34 = 0x012334 = 74548
//
//  ── ★ v3 关键修正（v2 上板"怎么按都不响"的根因）──────────────────────────
//   v2 把 AA55 的 3 字节组**只取高 16 位**（{b0,b1} = 原值 ÷256），
//   但模块实际输出的是**小整数**（手册例：78 / 701 / 8 —— 全都 < 65536），
//   于是高 16 位恒为 0 ⇒ 在 16bit 域里 16 个点永远"全 0 且不变"，
//   表现就是：无论怎么按都不触发、LED 量级条永远停在 0 档。
//   v3 改成**原样保留 24bit**（vals 扩到 16×24 = 384bit，点 i 在 vals[24*i +: 24]），
//   新协议 16bit 零扩展进 24bit 槽位 ⇒ 与量纲、与大小端解释都无关，不做归一化。
//
//  proto 输出：1 = 新协议，0 = 旧协议
//  ★ 收错帧不输出（frame_ok 不拉高），vals 保持上一次成功帧的值
//  ★ 发送缓冲不能叫 buf —— buf 是 Verilog 的门级原语关键字，会直接语法错误
// ============================================================================
`timescale 1ns / 1ps

module wax_frame (
    input  wire            clk,
    input  wire            rst_n,
    input  wire [7:0]      b,          // 来自 uart_rx
    input  wire            bvalid,     // 1 拍脉冲
    output reg             frame_ok,   // 解析成功，1 拍脉冲
    output reg             proto,      // 1=AA01 新协议, 0=AA55 旧协议
    output reg [24*16-1:0] vals        // 点 i 在 vals[24*i +: 24]（大端原码，未归一化）
);

    localparam [1:0] S_HUNT = 2'd0,   // 找 AA
                     S_CMD  = 2'd1,   // 等第 2 字节定协议
                     S_BODY = 2'd2,   // 收正文 + 校验
                     S_UNPK = 2'd3;   // 解包输出

    reg [1:0]  st;
    reg [7:0]  rxb [0:53];            // 54 字节缓存（旧协议最长）
    reg [5:0]  nbyte;                 // 已收字节数（含帧头 AA）
    reg        p;                     // 当前帧协议
    reg [7:0]  cs_new;                // AA01：前 34 字节累加
    reg [7:0]  cs_old;                // AA55：数据区 48 字节累加
    reg        good;

    // ── 解包：generate 保证下标是常量（不被综合成变址读写）──────────────
    //    新协议 16bit 大端 → 零扩展成 24bit；旧协议 24bit 大端 → 原样
    wire [24*16-1:0] unpacked;
    genvar u;
    generate
        for (u = 0; u < 16; u = u + 1) begin : G_UNPACK
            assign unpacked[24*u +: 24] = p ? {8'h00, rxb[2 + 2*u], rxb[3 + 2*u]}
                                            : {rxb[4 + 3*u], rxb[5 + 3*u], rxb[6 + 3*u]};
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_HUNT;
            nbyte    <= 6'd0;
            p        <= 1'b0;
            cs_new   <= 8'd0;
            cs_old   <= 8'd0;
            good     <= 1'b0;
            frame_ok <= 1'b0;
            proto    <= 1'b0;
            vals     <= 384'd0;
        end else begin
            frame_ok <= 1'b0;

            case (st)
                // ── 找帧头 ───────────────────────────────────────────────
                S_HUNT: begin
                    if (bvalid && b == 8'hAA) begin
                        nbyte <= 6'd1;
                        st    <= S_CMD;
                    end
                end

                // ── 第 2 字节定协议 ──────────────────────────────────────
                S_CMD: begin
                    if (bvalid) begin
                        if (b == 8'h01) begin
                            p      <= 1'b1;
                            cs_new <= 8'hAA + 8'h01;    // 补上已过的两字节
                            good   <= 1'b0;
                            nbyte  <= 6'd2;
                            st     <= S_BODY;
                        end else if (b == 8'h55) begin
                            p      <= 1'b0;
                            cs_old <= 8'd0;
                            good   <= 1'b0;
                            nbyte  <= 6'd2;
                            st     <= S_BODY;
                        end else if (b == 8'hAA) begin
                            nbyte <= 6'd1;              // 仍可能是新帧头，重新等
                        end else begin
                            st    <= S_HUNT;            // 不是帧头，重来
                            nbyte <= 6'd0;
                        end
                    end
                end

                // ── 收正文 ──────────────────────────────────────────────
                S_BODY: begin
                    if (bvalid) begin
                        rxb[nbyte] <= b;

                        if (p) begin
                            // 新协议：正文 2..33，34 是校验
                            if (nbyte <= 6'd33) cs_new <= cs_new + b;
                            if (nbyte == 6'd34) begin
                                good  <= (b == cs_new);
                                nbyte <= 6'd35;
                                st    <= S_UNPK;
                            end else begin
                                nbyte <= nbyte + 6'd1;
                            end
                        end else begin
                            // 旧协议：正文 4..51，52 是校验，53 必须是 0x0D
                            if ((nbyte >= 6'd4) && (nbyte <= 6'd51)) cs_old <= cs_old + b;
                            if (nbyte == 6'd52) begin
                                good  <= (b == cs_old);
                                nbyte <= 6'd53;
                            end else if (nbyte == 6'd53) begin
                                good  <= good & (b == 8'h0D);
                                st    <= S_UNPK;
                            end else begin
                                nbyte <= nbyte + 6'd1;
                            end
                        end
                    end
                end

                // ── 解包（仅在整帧校验通过时更新 vals）──────────────────
                S_UNPK: begin
                    if (good) begin
                        vals     <= unpacked;
                        proto    <= p;
                        frame_ok <= 1'b1;
                    end
                    st    <= S_HUNT;
                    nbyte <= 6'd0;
                end

                default: st <= S_HUNT;
            endcase
        end
    end

endmodule
