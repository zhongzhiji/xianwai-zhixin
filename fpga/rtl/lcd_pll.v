// New wrapper for the Gowin GW5A-family PLL primitive, compiled in a
// GW5AST-138C / FPG676A project (no B-revision netlist or IP cache is used).
// 50 MHz / IDIV(1) * FBDIV(1) * MDIV(21) / ODIV0(30) = 35 MHz.
// Divider values also match Sipeed's 800_480_screen example. The installed
// Gowin primitive library leaves charge-pump/filter values for tool calculation.
module lcd_pll (
    input wire clkin,
    output wire clkout0,
    output wire locked
);
    PLL #(
        .FCLKIN("50"), .IDIV_SEL(1), .FBDIV_SEL(1),
        .MDIV_SEL(21), .MDIV_FRAC_SEL(0),
        .ODIV0_SEL(30), .ODIV0_FRAC_SEL(0),
        .CLKFB_SEL("INTERNAL"),
        .CLKOUT0_EN("TRUE"),
        .CLKOUT1_EN("FALSE"), .CLKOUT2_EN("FALSE"),
        .CLKOUT3_EN("FALSE"), .CLKOUT4_EN("FALSE"),
        .CLKOUT5_EN("FALSE"), .CLKOUT6_EN("FALSE")
    ) u_core (
        .CLKIN(clkin), .CLKOUT0(clkout0), .LOCK(locked),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT5(), .CLKOUT6(), .CLKFBOUT(),
        .CLKFB(1'b0), .RESET(1'b0), .PLLPWD(1'b0),
        .RESET_I(1'b0), .RESET_O(1'b0),
        .ENCLK0(1'b1), .ENCLK1(1'b1), .ENCLK2(1'b1),
        .ENCLK3(1'b1), .ENCLK4(1'b1), .ENCLK5(1'b1), .ENCLK6(1'b1),
        .FBDSEL(6'd0), .IDSEL(6'd0), .MDSEL(7'd0), .MDSEL_FRAC(3'd0),
        .ODSEL0(7'd0), .ODSEL0_FRAC(3'd0),
        .ODSEL1(7'd0), .ODSEL2(7'd0), .ODSEL3(7'd0),
        .ODSEL4(7'd0), .ODSEL5(7'd0), .ODSEL6(7'd0),
        .DT0(4'd0), .DT1(4'd0), .DT2(4'd0), .DT3(4'd0),
        .PSSEL(3'd0), .PSDIR(1'b0), .PSPULSE(1'b0),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'd0), .SSCMDSEL_FRAC(3'd0),
        .ICPSEL(6'd0), .LPFRES(3'd0), .LPFCAP(2'd0)
    );
endmodule
