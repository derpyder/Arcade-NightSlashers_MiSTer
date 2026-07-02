`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// Build D (dual-mirror, SETTLED-PALETTE regression case, no-regression proof of the dual-mirror fix):
// pre-poke pal_A/pal_B (u_live, u_live_shadow, u_buf) directly with the settled image, fire fade_trig
// during VBLANK, let the FSM freeze+sweep+resync run, and compare u_pal's faded half (lower, address
// {0,idx}) vs the verbatim-C lerp golden. Since pal_B is already settled (== the image we want faded)
// and no CPU writes occur during the sweep, this must be bit-exact -- the dual-mirror fix must not
// regress the plain settled-palette case.
module tb_colmix_fade;
    reg          clk=0, LVBL=1, pal_we=0, pxl_cen=0, fade_trig=0;
    reg  [10:0]  pal_waddr=0;
    reg  [23:0]  pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] raw[0:2047], goldf[0:2047];
    integer i, m;

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(1'b0),
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    initial begin
        $readmemh("tf_buf.hex", raw);
        $readmemh("tf_faded.hex", goldf);
        @(posedge clk);
        for(i=0;i<2048;i=i+1) begin
            u_dut.u_buf.u_ram.mem[i]   = raw[i];      // pal_B (frozen mirror) = the settled image
            u_dut.u_live.u_ram.mem[i]  = raw[i];      // pal_A mirrors it too (settled, no pending writes)
            u_dut.u_live_shadow.u_ram.mem[i] = raw[i];
            u_dut.u_pal.u_ram.mem[i]   = 24'd0;       // faded half (lower, addr {0,idx}) cleared
        end
        @(posedge clk);
        LVBL = 1'b0;                                   // enter VBLANK so the FSM may run
        @(posedge clk); fade_trig = 1'b1;              // fade recompute (freeze+sweep pal_B, already settled)
        @(posedge clk); fade_trig = 1'b0;
        repeat(16000) @(posedge clk);                  // FSM: sweep (~5 clk/entry) + resync (~1 clk/entry) x 2048
        m = 0;
        for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]==goldf[i]) m=m+1;
        $display("=== fade FSM (cfg ace_fade=%012x mult=%b) ===", `ACE_FADE, `FADE_MULT);
        $display("faded entries: %0d/2048 match the verbatim-C lerp golden", m);
        for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]!=goldf[i]) begin
            $display("  first mismatch @%0d: rtl=%06x golden=%06x raw=%06x",
                     i, u_dut.u_pal.u_ram.mem[i], goldf[i], raw[i]); i=2048; end
        $display("RESULT: %s", (m==2048)?"PASS":"FAIL");
        $finish;
    end
endmodule
