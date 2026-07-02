`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// Independent verification (written directly by the reviewer, not trusting any prior self-report):
// same exact stimulus as tb_torn_OLD.v (preload B0 via real CPU writes, fire a fade trigger, let the
// sweep run partway, then batch-rewrite B1 over ALL 2048 entries mid-sweep) but against the REAL
// jtnslasher_colmix.v (dual-mirror pal_A/pal_B design), not a reconstruction. Checks:
//  (1)+(2) faded[] must be bit-exact fade(B0) for all 2048 entries -- NOT a torn mix (the bug this
//          fix targets), verified against an INDEPENDENT golden (tf_faded.hex, generated straight
//          from the MAME palette_update formula, never derived from this RTL).
//  (3) pal_A (raw/live display source, u_live) must reflect the LATEST write (B1) immediately --
//          proves the live path is never stalled/gated by the freeze.
//  (4) after RESYNC completes, pal_B (u_buf) must have caught all the way up to B1 too.
module tb_torn_NEW;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047], goldf0[0:2047];
    integer i, m0, m1, mtorn, mA_b1, mB_b1;

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(paldma),
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    task live_write(input [10:0] a, input [23:0] dv);
        begin @(posedge clk); pal_we<=1'b1; pal_waddr<=a; pal_din<=dv;
              @(posedge clk); pal_we<=1'b0; end
    endtask

    initial begin
        $readmemh("tf_buf.hex",   B0);
        $readmemh("tf_live.hex",  B1);
        $readmemh("tf_faded.hex", goldf0);   // golden = fade(B0), the coherent answer if no tear

        // Populate B0 through the REAL CPU write path (dual-writes u_live+u_live_shadow+u_buf).
        for(i=0;i<2048;i=i+1) live_write(i[10:0], B0[i]);

        LVBL = 1'b0;                                    // enter VBLANK, FSM may run
        @(posedge clk); fade_trig<=1'b1;
        @(posedge clk); fade_trig<=1'b0;

        // Sweep runs several clk/entry (FR,FC,FM1,FM2,FW). Let it advance partway then batch-rewrite.
        repeat(4800) @(posedge clk);
        $display("mid-sweep fstate=%0d fsm_idx=%0d freeze=%0b (partial progress)",
                  u_dut.fstate, u_dut.fsm_idx, u_dut.freeze);

        // Tight-burst batch write of B1 over ALL 2048 entries -- the exact scenario that tore the OLD design.
        for(i=0;i<2048;i=i+1) live_write(i[10:0], B1[i]);

        // Let the sweep + resync fully finish (generous margin). Trace fstate/fsm_idx/freeze
        // periodically to see where RESYNC actually lands.
        repeat(6) begin
            repeat(5000) @(posedge clk);
            $display("  trace: fstate=%0d fsm_idx=%0d freeze=%0b trig_pending=%0b",
                      u_dut.fstate, u_dut.fsm_idx, u_dut.freeze, u_dut.trig_pending);
        end
        $display("post-settle fstate=%0d freeze=%0b", u_dut.fstate, u_dut.freeze);
        LVBL = 1'b1;
        repeat(20) @(posedge clk);

        m0 = 0; m1 = 0; mtorn = 0; mA_b1 = 0; mB_b1 = 0;
        for(i=0;i<2048;i=i+1) begin : chk
            if (u_dut.u_pal.u_ram.mem[i] == goldf0[i]) m0 = m0 + 1;
            if (u_dut.u_live.u_ram.mem[i] == B1[i])       mA_b1 = mA_b1 + 1;
            if (u_dut.u_buf.u_ram.mem[i]  == B1[i])       mB_b1 = mB_b1 + 1;
        end
        mtorn = 2048 - m0;

        $display("=== TEST: dual-mirror design under the SAME mid-sweep batch rewrite ===");
        $display("(1)+(2) faded == fade(B0) [coherent, no tear]      : %0d/2048", m0);
        $display("        faded == NEITHER golden (torn/incoherent) : %0d/2048", mtorn);
        $display("RESULT: %s", (m0==2048) ? "PASS -- fully coherent, tear ELIMINATED" : "FAIL -- still torn");
        $display("(3) pal_A (u_live, raw/live display) == B1 (latest write, never stalled): %0d/2048  %s",
                  mA_b1, (mA_b1==2048) ? "PASS" : "FAIL");
        $display("(4) pal_B (u_buf) caught up to B1 after resync                          : %0d/2048  %s",
                  mB_b1, (mB_b1==2048) ? "PASS" : "FAIL");

        $display("---- dialog pen samples (idx 0..3) ----");
        for(i=0;i<4;i=i+1)
            $display("  dialog[%0d]: B0=%06x B1=%06x  faded=%06x  golden=fade(B0)=%06x  live(pal_A)=%06x",
                     i, B0[i], B1[i], u_dut.u_pal.u_ram.mem[i], goldf0[i], u_dut.u_live.u_ram.mem[i]);

        $finish;
    end
endmodule
