`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// ============================================================================
// PROOF (2): the SAME mid-sweep-batch-write stimulus as tb_colmix_midsweep_tear.v, but driven
// against the NEW dual-mirror colmix (pal_A=u_live/u_live_shadow, pal_B=u_buf, freeze+resync FSM).
// Preload via pal_we (real CPU write path) = B0. Fire fade_trig (freeze pal_B @ B0). Partway through
// the VBLANK sweep, slam pal_we with a tight-burst batch rewrite = B1 (same batch shape as proof 1).
// Because pal_B froze BEFORE the batch write lands (it only reaches pal_A while frozen), the sweep
// must read a pal_B that never moves -- so the result must be COMPLETELY coherent fade(B0), bit-exact
// against the independent golden, for both mult and additive fade configs.
// ============================================================================
module tb_colmix_midsweep_fixed;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047], goldB0[0:2047];
    integer i, m0, k;

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(paldma),
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    initial begin
        $readmemh("tf_buf.hex",  B0);
        $readmemh("tf_live.hex", B1);
        $readmemh("tf_faded.hex", goldB0);

        @(posedge clk);
        // clear pal_A/pal_B/u_pal to a known state via the CPU write path (B0), never poking .mem
        for(i=0;i<2048;i=i+1) begin
            @(posedge clk); pal_we<=1'b1; pal_waddr<=i[10:0]; pal_din<=B0[i];
        end
        @(posedge clk); pal_we<=1'b0;
        repeat(4) @(posedge clk);   // let pal_A/pal_B settle (they mirror on every write already)

        LVBL=1'b0;                                    // VBLANK: FSM may run
        @(posedge clk); fade_trig=1'b1; paldma=1'b1;
        @(posedge clk); fade_trig=1'b0; paldma=1'b0;   // pal_B FROZEN here, holding B0

        // let the sweep run PARTWAY (same window as proof 1: ~800/2048 entries)
        repeat(3600) @(posedge clk);

        // BATCH rewrite = B1, tight back-to-back burst (identical shape to proof 1). Since pal_B is
        // frozen, this can only ever reach pal_A -- pal_B (the sweep's source) must not move.
        for(i=0;i<2048;i=i+1) begin
            @(posedge clk); pal_we<=1'b1; pal_waddr<=i[10:0]; pal_din<=B1[i];
        end
        @(posedge clk); pal_we<=1'b0;

        // let the sweep (and the resync it triggers afterward) finish
        repeat(30000) @(posedge clk);
        LVBL=1'b1;
        repeat(20) @(posedge clk);

        m0=0;
        for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]==goldB0[i]) m0=m0+1;
        $display("=== PROOF(2) mid-sweep batch-write, NEW dual-mirror design (cfg ace_fade=%012x mult=%b) ===",
                 `ACE_FADE, `FADE_MULT);
        $display("faded[] == fade(B0) fully-coherent golden : %0d/2048", m0);
        $display("dialog pen[0]: rtl=%06x  fade(B0)=%06x", u_dut.u_pal.u_ram.mem[0], goldB0[0]);
        $display("dialog pen[1]: rtl=%06x  fade(B0)=%06x", u_dut.u_pal.u_ram.mem[1], goldB0[1]);
        $display("dialog pen[3]: rtl=%06x  fade(B0)=%06x", u_dut.u_pal.u_ram.mem[3], goldB0[3]);
        for(k=0;k<3;k=k+1) begin : grad
            i = 16 + k*80;
            $display("gradient pen[%0d]: rtl=%06x  fade(B0)=%06x", i, u_dut.u_pal.u_ram.mem[i], goldB0[i]);
        end
        if(m0!=2048) for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]!=goldB0[i]) begin
            $display("  first mismatch @%0d: rtl=%06x golden=%06x", i, u_dut.u_pal.u_ram.mem[i], goldB0[i]); i=2048; end
        $display("RESULT: %s", (m0==2048)?"PASS (bit-exact fade(B0), tear CLOSED)":"FAIL");

        // also confirm pal_A (u_live) picked up B1 (the mid-sweep batch write reached the raw copy
        // immediately, exactly as it should -- proof (3) does this more thoroughly)
        m0=0; for(i=0;i<2048;i=i+1) if(u_dut.u_live.u_ram.mem[i]==B1[i]) m0=m0+1;
        $display("sanity: pal_A(u_live) == B1 after the batch write : %0d/2048", m0);
        $finish;
    end
endmodule
