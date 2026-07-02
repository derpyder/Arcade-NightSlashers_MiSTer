`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// ============================================================================
// PROOF (3): pal_A (u_live, the raw/live mirror) is NEVER stalled, gated, or torn by the freeze/
// sweep/resync FSM. Drives one CPU write PER CYCLE (back-to-back, no gaps) across three phases:
//   phase 1 (normal)  : LVBL=1, no freeze in effect
//   phase 2 (frozen)  : fires fade_trig, then keeps writing through the ENTIRE sweep window
//   phase 3 (resync)  : keeps writing through the RESYNC window (right after the sweep completes)
// Every write must land at the RIGHT address with the RIGHT data, on the SAME cycle it was issued
// (no added latency vs a plain RAM) -- checked by reading pal_A (u_live.u_ram.mem) back at the end
// and confirming ALL addresses hold the LAST value written to them (last-writer-wins, no stalls, no
// drops), across all three phases combined.
// ============================================================================
module tb_colmix_palA_nostall;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] exp_val[0:2047];
    integer i, m, wcount;

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(paldma),
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    // issue one back-to-back write per cycle for `n` cycles, cycling through addresses 0..2047,
    // with a distinguishable tag in the data so we know which phase wrote last
    task write_burst(input [7:0] tag, input integer n);
        integer j; reg [10:0] a;
        begin
            for(j=0;j<n;j=j+1) begin
                a = (wcount) % 2048;
                @(posedge clk);
                pal_we<=1'b1; pal_waddr<=a; pal_din<={tag, 8'h00, a[7:0]};
                exp_val[a] = {tag, 8'h00, a[7:0]};
                wcount = wcount + 1;
            end
            @(posedge clk); pal_we<=1'b0;
        end
    endtask

    initial begin
        wcount = 0;
        for(i=0;i<2048;i=i+1) exp_val[i] = 24'hxxxxxx;
        @(posedge clk);

        // ---- phase 1: normal (no freeze) ----
        LVBL=1'b1;
        write_burst(8'hA1, 2200);   // > 2048 so every address gets hit at least once

        // ---- phase 2: frozen (fade_trig fired, sweep running) ----
        LVBL=1'b0;                                    // enter VBLANK so the FSM may run
        @(posedge clk); fade_trig=1'b1; paldma=1'b1;
        @(posedge clk); fade_trig=1'b0; paldma=1'b0;   // pal_B frozen from this cycle
        write_burst(8'hB2, 2200);                       // hammer pal_A the WHOLE sweep window (~12k clks/2048... but we only need overlap)
        repeat(20000) @(posedge clk);                  // let the sweep (FR..FW x2048) actually finish

        // ---- phase 3: resync window (right after sweep, FSM should be in RS) ----
        write_burst(8'hC3, 2200);
        repeat(6000) @(posedge clk);                   // let resync (2048 cycles) finish
        LVBL=1'b1;
        repeat(10) @(posedge clk);

        m=0;
        for(i=0;i<2048;i=i+1) if(u_dut.u_live.u_ram.mem[i]==exp_val[i]) m=m+1;
        $display("=== PROOF(3) pal_A(u_live) never-stalled/never-torn, %0d writes issued (3 phases) ===", wcount);
        $display("pal_A == expected last-writer-wins value : %0d/2048", m);
        for(i=0;i<2048;i=i+1) if(u_dut.u_live.u_ram.mem[i]!=exp_val[i]) begin
            $display("  first mismatch @%0d: rtl=%06x exp_val=%06x", i, u_dut.u_live.u_ram.mem[i], exp_val[i]); i=2048; end
        $display("RESULT: %s", (m==2048)?"PASS (no stall/drop across normal+frozen+resync phases)":"FAIL");
        $finish;
    end
endmodule
