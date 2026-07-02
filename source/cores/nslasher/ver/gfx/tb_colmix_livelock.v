`timescale 1ns/1ps
`define SIMULATION
// ============================================================================
// DISCRIMINATING repro of the cab symptom (green dialog / warm-tan shadow), the ONE stimulus every
// prior colmix test skipped: CONTINUOUS CPU palette writes spanning the RESYNC window, PLUS a fade
// re-trigger arriving while the machine is busy. This reproduces the RESYNC LIVELOCK
// (jtnslasher_colmix.v:320-332): pal_a_touched is set by ANY pal_we during the ~4096-clk, non-VBLANK-
// gated resync pass, so the dirty-retry restarts forever -> the FSM never returns to IDLE -> a queued
// fade re-trigger (trig_pending) is never honored -> the FADED palette half is frozen at the OLD
// fade config even after the game programs a NEW one. That is exactly the measured HW symptom:
// the faded shadow/dialog pen stays at a stale (attract-era) warm additive fade = 0xDB,0xC3,0xA6.
//
// The golden is MAME-atomic: after the game programs fade F_NEW, MAME's palette_update() recomputes
// ALL faded pens instantly, so faded[] MUST equal fade_NEW(pal). The fade formula (additive
// min(c+ps,255)) is the independently-verified MAME deco_ace formula, NOT read back from the RTL --
// the discrimination here is the STIMULUS (continuous-write livelock), not the arithmetic.
//
//   CURRENT RTL  -> faded[] stuck at fade_OLD(pal)  (livelock; trig_pending never honored)  = FAIL (repro)
//   FIXED  RTL   -> faded[] tracks fade_NEW(pal)     (resync cannot livelock)                = PASS
// ============================================================================
module tb_colmix_livelock;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    reg  [47:0]  ace_fade=0; reg fade_mult=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg  [23:0] P[0:2047];               // the (stable) palette content
    reg  [23:0] goldOLD[0:2047], goldNEW[0:2047];
    integer i, mNEW, mOLD, mother;

    // F_OLD = additive warm strength (stale attract fade); F_NEW = additive identity (ps=0 -> faded=c)
    localparam [7:0] PS_OLD = 8'h40;     // additive: faded_OLD = min(c+0x40,255)
    localparam [7:0] PS_NEW = 8'h00;     // additive: faded_NEW = c  (the CURRENT, correct fade)

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(ace_fade), .fade_mult(fade_mult), .fade_trig(fade_trig), .paldma(paldma),
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    function [7:0] afade(input [7:0] c, input [7:0] ps);
        reg [8:0] s; begin s={1'b0,c}+{1'b0,ps}; afade=s[8]?8'hFF:s[7:0]; end
    endfunction

    // ---- CONTINUOUS-WRITE HAMMER: rewrites the SAME palette values every clock (content unchanged,
    // but every write sets pal_a_touched) -- models the in-game CPU rewriting the palette each frame.
    reg        hammer=0;
    reg [10:0] hidx=0;
    always @(posedge clk) begin
        if( hammer ) begin
            pal_we    <= 1'b1;
            pal_waddr <= hidx;
            pal_din   <= P[hidx];
            hidx      <= hidx + 11'd1;   // walks 0..2047 repeatedly
        end else if( !manual_we ) begin
            pal_we <= 1'b0;
        end
    end
    reg manual_we=0;   // guard so the preload loop isn't stomped by the hammer block

    task preload; integer j; begin
        manual_we=1;
        for(j=0;j<2048;j=j+1) begin
            @(posedge clk); pal_we<=1'b1; pal_waddr<=j[10:0]; pal_din<=P[j];
        end
        @(posedge clk); pal_we<=1'b0; manual_we=0;
    end endtask

    initial begin
        // moderate, per-index-distinct values so min(c+0x40,255) never saturates -> total discrimination
        for(i=0;i<2048;i=i+1) begin
            P[i] = { 8'h30 + i[6:0], 8'h20 + i[6:0], 8'h10 + i[6:0] };   // {B,G,R}
            goldOLD[i] = { afade(P[i][23:16],PS_OLD), afade(P[i][15:8],PS_OLD), afade(P[i][7:0],PS_OLD) };
            goldNEW[i] = { afade(P[i][23:16],PS_NEW), afade(P[i][15:8],PS_NEW), afade(P[i][7:0],PS_NEW) };
        end

        preload();                                   // pal_A/pal_B = P via the real CPU write path
        repeat(4) @(posedge clk);

        // ---- program the OLD (warm) fade + trigger, and IMMEDIATELY start continuous writes ----
        ace_fade = { PS_OLD, PS_OLD, PS_OLD, 24'h000000 };  // [47:40]=ps_b,[39:32]=ps_g,[31:24]=ps_r
        fade_mult = 1'b0;
        hammer = 1'b1;                                // continuous writes span the whole sweep+resync
        LVBL = 1'b0;                                  // VBLANK: sweep may run
        @(posedge clk); fade_trig<=1'b1;
        @(posedge clk); fade_trig<=1'b0;

        // give plenty of VBLANK for the F_OLD sweep to finish (2048*5 states) and reach RS/RS2,
        // where the continuous hammer traps it in the dirty-retry livelock.
        repeat(20000) @(posedge clk);
        $display("after F_OLD sweep: fstate=%0d fsm_idx=%0d freeze=%0b trig_pending=%0b pal_a_touched=%0b",
                  u_dut.fstate, u_dut.fsm_idx, u_dut.freeze, u_dut.trig_pending, u_dut.pal_a_touched);

        // ---- now the game programs the NEW (identity) fade + re-triggers, still writing continuously ----
        ace_fade = { PS_NEW, PS_NEW, PS_NEW, 24'h000000 };
        @(posedge clk); fade_trig<=1'b1;
        @(posedge clk); fade_trig<=1'b0;

        // run a long time across many simulated frames (toggle LVBL so any freed sweep COULD run),
        // with the hammer CONTINUOUSLY ON -- the true persistent cab condition (CPU never stops
        // writing the palette). This is the stimulus every prior test omitted.
        repeat(60) begin
            LVBL=1'b1; repeat(1200) @(posedge clk);   // active display (resync runs here, hits the hammer)
            LVBL=1'b0; repeat(1200) @(posedge clk);   // VBLANK (a freed sweep could run here)
        end

        // ---- CHECK WHILE THE HAMMER IS STILL ON (persistent continuous-write condition) ----
        $display("persistent (hammer ON): fstate=%0d freeze=%0b trig_pending=%0b pal_a_touched=%0b",
                  u_dut.fstate, u_dut.freeze, u_dut.trig_pending, u_dut.pal_a_touched);
        mNEW=0; mOLD=0; mother=0;
        for(i=0;i<2048;i=i+1) begin
            if     ( u_dut.u_pal.u_ram.mem[i]==goldNEW[i] ) mNEW=mNEW+1;
            else if( u_dut.u_pal.u_ram.mem[i]==goldOLD[i] ) mOLD=mOLD+1;
            else                                            mother=mother+1;
        end
        $display("=== LIVELOCK repro: CONTINUOUS writes + fade OLD->NEW re-trigger, checked mid-hammer ===");
        $display(" faded == fade_NEW(pal)  [MAME-atomic, CURRENT fade, CORRECT]  : %0d/2048", mNEW);
        $display(" faded == fade_OLD(pal)  [STALE, the livelock/cab symptom]      : %0d/2048", mOLD);
        $display(" faded == neither        [partial/torn]                         : %0d/2048", mother);
        $display("---- shadow-pen sample (idx 48): P=%06x goldNEW=%06x goldOLD=%06x  faded=%06x ----",
                  P[48], goldNEW[48], goldOLD[48], u_dut.u_pal.u_ram.mem[48]);
        $display("RESULT(persistent): %s", (mNEW==2048) ? "PASS -- faded tracks the CURRENT fade even under continuous writes (livelock CANNOT trap)" :
                               (mOLD>1024)  ? "FAIL -- faded STUCK at stale fade under continuous writes (LIVELOCK REPRODUCED = cab symptom)" :
                                              "FAIL -- faded incoherent");

        // ---- for reference: does it self-heal if writes ever PAUSE? (a brief gap gives a clean resync pass) ----
        hammer=1'b0; @(posedge clk); pal_we<=1'b0;
        LVBL=1'b0; repeat(30000) @(posedge clk);
        LVBL=1'b1; repeat(20) @(posedge clk);
        mNEW=0; for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]==goldNEW[i]) mNEW=mNEW+1;
        $display("after writes PAUSE (self-heal check): faded==fade_NEW = %0d/2048  fstate=%0d", mNEW, u_dut.fstate);
        $finish;
    end
endmodule
