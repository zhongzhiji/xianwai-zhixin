`timescale 1ns/1ps
// ============================================================================
//  touch_carrier.v
//
//  TouchCarrier R11（TWO-MPR121 TOUCH CARRIER）的 FPGA 驱动。
//
//  硬件事实（来自 PCB 源文件的真实网络名，见 docs/touchcarrier_netlist.csv）：
//    · 两颗 MPR121 共用一条 SCL / SDA，IRQ 开漏并联为 MPR_IRQ_N（线或）
//    · MPR_A  ADDR→GND  → 7-bit 地址 0x5A，ELE0..11 = KEY00..KEY11
//    · MPR_B  ADDR→3V3  → 7-bit 地址 0x5B，ELE0..3  = KEY12..KEY15
//                                        ELE4..9  = STRING1..STRING6
//                                        ELE10    = BEND（弯音轮）
//                                        ELE11    = VIB （颤音）
//
//  为什么必须做仲裁：
//    两条 MPR121 时序器各自要连续发 I2C 事务。若各自挂一个 i2c_register_master
//    并同时驱动 scl/sda，会互相拉低对方的数据位。这里只放**一个** I2C 主机，
//    两颗 MPR121 用 req/grant 轮询占用，总线永远只有一个驱动源。
//    仲裁策略：round-robin，避免 A 一直抢到导致 B（弦/弯音/颤音）饿死。
//
//  时钟域：整个模块跑在 sys_clk(50MHz)。I2C 主机参数 CLK_HZ 必须与之一致。
// ============================================================================
module touch_carrier #(
    parameter integer CLK_HZ            = 50000000,
    parameter integer I2C_HZ            = 100000,
    parameter integer BUS_TIMEOUT_US     = 2000,
    parameter integer POLL_US            = 2000,
    parameter integer POWER_WAIT_MS      = 20,     // 可调小以加快仿真
    parameter integer RESET_WAIT_MS      = 1,
    parameter integer SETTLE_MS          = 20,
    parameter integer RETRY_MS           = 100,
    parameter [6:0]   ADDR_A             = 7'h5a,     // MPR A（ADDR→GND）
    parameter [6:0]   ADDR_B             = 7'h5b,     // MPR B（ADDR→3V3）
    parameter [7:0]   TOUCH_THRESHOLD    = 8'd12,
    parameter [7:0]   RELEASE_THRESHOLD  = 8'd6
)(
    input  wire        clk,
    input  wire        reset_n,

    // 开漏总线：只能拉低或释放，依赖板载上拉到 3.3V
    inout  wire        scl,
    inout  wire        sda,
    input  wire        irq_n,             // MPR_IRQ_N：两颗开漏并联，低有效

    // 16 个琴键
    output wire [15:0] keys,             // 当前按下的位图
    output wire [15:0] key_press,        // 新按下（1 clk 脉冲）
    output wire [15:0] key_release,      // 新释放（1 clk 脉冲）

    // 6 条琴弦（音色/演奏法切换）
    output wire [5:0]  strings,
    output wire [5:0]  string_press,

    // 表情控制
    output wire        bend,             // 弯音轮
    output wire        vib,              // 颤音

    // 状态
    output wire        online,           // 两颗都成功读到过一次才算在线
    output wire        fault,
    output wire [2:0]  fault_code,
    output wire        clear_event,      // 掉线清音事件（music 层必须独立消费）
    output wire        error_event,
    output wire        sample_valid
);

    // ------------------------------------------------------------------
    // 1. 两个时序器的请求通道
    // ------------------------------------------------------------------
    wire        req_a, req_b;
    wire [7:0]  reg_a, reg_b, wdat_a, wdat_b;
    wire        rd_a, rd_b, two_a, two_b;

    // ------------------------------------------------------------------
    // 1. 唯一的 I2C 主机与总线信号（先声明，避免隐式线网）
    // ------------------------------------------------------------------
    wire        scl_low, sda_low, bus_busy, bus_done;
    wire [2:0]  bus_error;
    wire [15:0] bus_data;

    // ------------------------------------------------------------------
    // 1b. IRQ 同步（异步输入 → 两级同步 → 去抖到"仍在触摸"的电平）
    //     两颗 MPR121 的 IRQ 是开漏线或，任一颗有触摸都会拉低，
    //     因此两颗时序器同时收到 poll_now，轮询间隔一起减半。
    // ------------------------------------------------------------------
    reg [1:0] irq_sync;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) irq_sync <= 2'b11;
        else          irq_sync <= {irq_sync[0], irq_n};
    end
    wire irq_active = ~irq_sync[1];

    wire [11:0] touched_a, touched_b;
    wire [11:0] press_a,   press_b;
    wire [11:0] rel_a,     rel_b;
    wire        sv_a, sv_b, on_a, on_b, flt_a, flt_b, clr_a, clr_b, err_a, err_b;
    wire [2:0]  fcode_a, fcode_b;

    wire        done_a, done_b;

    mpr121_sequencer #(
        .CLK_HZ(CLK_HZ), .POLL_US(POLL_US),
        .POWER_WAIT_MS(POWER_WAIT_MS), .RESET_WAIT_MS(RESET_WAIT_MS),
        .SETTLE_MS(SETTLE_MS), .RETRY_MS(RETRY_MS),
        .TOUCH_THRESHOLD(TOUCH_THRESHOLD), .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .I2C_ADDRESS(ADDR_A)
    ) u_seq_a (
        .clk(clk), .reset_n(reset_n),
        .req(req_a), .req_address(), .req_register(reg_a), .req_write(wdat_a),
        .req_read(rd_a), .req_two(two_a),
        .xfer_done(done_a), .xfer_error(bus_error), .xfer_data(bus_data),
        .poll_now(irq_active),
        .touched(touched_a), .press_event(press_a), .release_event(rel_a),
        .sample_valid(sv_a), .online(on_a), .fault(flt_a),
        .clear_event(clr_a), .error_event(err_a), .fault_code(fcode_a));

    mpr121_sequencer #(
        .CLK_HZ(CLK_HZ), .POLL_US(POLL_US),
        .POWER_WAIT_MS(POWER_WAIT_MS), .RESET_WAIT_MS(RESET_WAIT_MS),
        .SETTLE_MS(SETTLE_MS), .RETRY_MS(RETRY_MS),
        .TOUCH_THRESHOLD(TOUCH_THRESHOLD), .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .I2C_ADDRESS(ADDR_B)
    ) u_seq_b (
        .clk(clk), .reset_n(reset_n),
        .req(req_b), .req_address(), .req_register(reg_b), .req_write(wdat_b),
        .req_read(rd_b), .req_two(two_b),
        .xfer_done(done_b), .xfer_error(bus_error), .xfer_data(bus_data),
        .poll_now(irq_active),
        .touched(touched_b), .press_event(press_b), .release_event(rel_b),
        .sample_valid(sv_b), .online(on_b), .fault(flt_b),
        .clear_event(clr_b), .error_event(err_b), .fault_code(fcode_b));

    // ------------------------------------------------------------------
    // 2. round-robin 仲裁器
    // ------------------------------------------------------------------
    reg [1:0] owner;        // 0=空闲 1=A 2=B
    reg [1:0] last;         // 上次服务者，用来交替
    reg       start_pulse;
    reg [1:0] pick;

    always @* begin
        if      (req_a && req_b) pick = (last == 2'd1) ? 2'd2 : 2'd1;
        else if (req_a)          pick = 2'd1;
        else if (req_b)          pick = 2'd2;
        else                     pick = 2'd0;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            owner <= 2'd0; last <= 2'd2; start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (owner == 2'd0) begin
                if (pick != 2'd0) begin
                    owner <= pick; last <= pick; start_pulse <= 1'b1;
                end
            end else if (bus_done) begin
                owner <= 2'd0;
            end
        end
    end

    wire owner_a = (owner == 2'd1);
    wire owner_b = (owner == 2'd2);

    assign done_a = bus_done & owner_a;
    assign done_b = bus_done & owner_b;

    // ------------------------------------------------------------------
    // 3. 实例化 I2C 主机（开漏，只能拉低或释放）
    // ------------------------------------------------------------------
    i2c_register_master #(
        .CLK_HZ(CLK_HZ), .BUS_HZ(I2C_HZ), .TIMEOUT_US(BUS_TIMEOUT_US)
    ) u_i2c (
        .clk(clk), .reset_n(reset_n),
        .start(start_pulse),
        .address(owner_a ? ADDR_A : ADDR_B),
        .register_address(owner_a ? reg_a  : reg_b),
        .write_data      (owner_a ? wdat_a : wdat_b),
        .read_request    (owner_a ? rd_a   : rd_b),
        .read_two_bytes  (owner_a ? two_a  : two_b),
        .scl_in(scl), .sda_in(sda),
        .scl_drive_low(scl_low), .sda_drive_low(sda_low),
        .busy(bus_busy), .done(bus_done), .error(bus_error), .read_data(bus_data));

    // 开漏：只能拉低或高阻，绝不能推挽输出 1
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    // ------------------------------------------------------------------
    // 4. 电极 → 功能映射（严格按 PCB 网络名）
    //    MPR_B: ELE0..3  = KEY12..15
    //           ELE4..9  = STRING1..6
    //           ELE10    = BEND
    //           ELE11    = VIB
    // ------------------------------------------------------------------
    assign keys         = {touched_b[3:0], touched_a[11:0]};
    assign key_press    = {press_b[3:0],   press_a[11:0]};
    assign key_release  = {rel_b[3:0],     rel_a[11:0]};

    assign strings      = touched_b[9:4];
    assign string_press = press_b[9:4];

    assign bend         = touched_b[10];
    assign vib          = touched_b[11];

    // ------------------------------------------------------------------
    // 5. 汇总状态
    // ------------------------------------------------------------------
    assign online       = on_a & on_b;
    assign fault        = flt_a | flt_b;
    assign fault_code   = flt_a ? fcode_a : fcode_b;
    assign clear_event  = clr_a | clr_b;
    assign error_event  = err_a | err_b;
    assign sample_valid = sv_a | sv_b;

endmodule
