`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// ============================================================================
// LIVE-vs-BUFFERED timing TB for the deco_ace buffered-palette fix.
//
// The confirmed bug: the RTL computed faded[i]=fade(LIVE pal[i]); MAME computes
// faded[i]=fade(BUFFERED pal[i]) — a DMA-frozen snapshot. So mid-frame CPU
// palette writes bloom the faded dialog/bio pens (green dialog, banded bio).
//
// This TB drives the LIVE write ports and a DISTINCT paldma pulse to expose the
// difference. Compile-time switches:
//   -DHAVE_PALDMA : connect the new .paldma() port (the FIXED colmix). Omit it
//                   to build against the ORIGINAL backup (no paldma port) — the
//                   proof-of-repro run.
//   -DUNFIXED     : label output as the unfixed (repro) run.
//
// The golden tf_faded.hex = fade(B0) computed INDEPENDENTLY from deco_ace.cpp by
// gen_bufferfade_test.py — never derived from this RTL.
// ============================================================================
module tb_colmix_bufferfade;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047], goldf[0:2047];
    integer i, m, ndrift, k;

    // fade regs unpacked into named bytes (can't bit-select a macro literal directly)
    wire [47:0] af = `ACE_FADE;
    wire [7:0] ptr=af[7:0],  ptg=af[15:8],  ptb=af[23:16];
    wire [7:0] psr=af[31:24],psg=af[39:32], psb=af[47:40];

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig),
`ifdef HAVE_PALDMA
        .paldma(paldma),
`endif
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    // one CPU palette write into the LIVE port
    task live_write(input [10:0] a, input [23:0] dv);
        begin @(posedge clk); pal_we<=1'b1; pal_waddr<=a; pal_din<=dv;
              @(posedge clk); pal_we<=1'b0; end
    endtask

    // pulse a full palette DMA (snapshot live->buffered + recompute faded)
    task pulse_paldma;
        begin @(posedge clk); paldma<=1'b1; fade_trig<=1'b1;   // paldma implies fade_trig (vmem.v)
              @(posedge clk); paldma<=1'b0; fade_trig<=1'b0; end
    endtask

    // pulse a fade-reg-ONLY recompute (NO snapshot) — re-fade the frozen buffered image
    task pulse_fadereg;
        begin @(posedge clk); fade_trig<=1'b1;
              @(posedge clk); fade_trig<=1'b0; end
    endtask

    function integer count_match;
        input dummy;
        integer c;
        begin c=0; for(k=0;k<2048;k=k+1) if(u_dut.u_pal.u_ram.mem[k]==goldf[k]) c=c+1;
              count_match=c; end
    endfunction

    initial begin
        $readmemh("tf_buf.hex",   B0);
        $readmemh("tf_live.hex",  B1);
        $readmemh("tf_faded.hex", goldf);
        @(posedge clk);
        // clear both halves of the displayed RAM + the live RAM (defined start state)
        for(i=0;i<4096;i=i+1) u_dut.u_pal.u_ram.mem[i]=24'd0;
`ifdef HAVE_PALDMA
        for(i=0;i<2048;i=i+1) u_dut.u_live.u_ram.mem[i]=24'd0;
`endif
        @(posedge clk);

        // ================= STEP (a): snapshot B0 via a real DMA, fade it =================
`ifdef HAVE_PALDMA
        // Load LIVE=B0 through the CPU write path, then DMA-snapshot it.
        for(i=0;i<2048;i=i+1) u_dut.u_live.u_ram.mem[i]=B0[i];
        LVBL=1'b0;                                   // VBLANK: FSM may run
        pulse_paldma;                                // snapshot live(B0)->buffered + faded=fade(B0)
        repeat(20000) @(posedge clk);
        LVBL=1'b1;
`else
        // ORIGINAL RTL has no live/buffered split: the CPU writes land in the displayed
        // raw half directly. Load that half = B0 and fire a fade recompute.
        for(i=0;i<2048;i=i+1) u_dut.u_pal.u_ram.mem[2048+i]=B0[i];
        LVBL=1'b0; pulse_fadereg; repeat(20000) @(posedge clk); LVBL=1'b1;
`endif
        m = count_match(0);
        $display("=== deco_ace buffered-fade TB (cfg ace_fade=%012x mult=%b) ===", `ACE_FADE, `FADE_MULT);
`ifdef UNFIXED
        $display("[UNFIXED / repro build]");
`else
        $display("[FIXED build]");
`endif
        $display("STEP (a) faded=fade(B0) snapshot : %0d/2048 match golden -> %s",
                 m, (m==2048)?"PASS":"FAIL");

        // ================= STEP (b): mid-next-frame LIVE writes of B1, NO new DMA =========
        // Drive the live-write ports over the dialog+gradient indices, then fire a
        // fade-reg-only recompute (a per-frame fade tweak with no palette DMA).
        LVBL=1'b1;                                    // active display (writes happen mid-frame)
        for(i=0;i<2048;i=i+1) live_write(i[10:0], B1[i]);
        // a fade-reg recompute happens next VBLANK (no DMA => must re-fade the FROZEN image)
        LVBL=1'b0; pulse_fadereg; repeat(20000) @(posedge clk); LVBL=1'b1;

        m = count_match(0);
        ndrift = 2048 - m;
        $display("STEP (b) after LIVE B1 writes + fade-reg recompute (NO DMA):");
        $display("         faded still == fade(B0) on %0d/2048 ; DRIFTED on %0d", m, ndrift);
        // show the dialog pens (idx 0..3): near-black should stay near-black, not bloom green
        for(i=0;i<4;i=i+1)
            $display("         dialog[%0d]: faded=%06x  golden(fadeB0)=%06x  fade(B1)would=%06x",
                     i, u_dut.u_pal.u_ram.mem[i], goldf[i], u_dut.u_pal.u_ram.mem[i]); // rtl vs golden
`ifdef UNFIXED
        $display("         EXPECT (unfixed): faded DRIFTS toward fade(B1) -> ndrift>0 -> BUG REPRODUCED");
        $display("RESULT: %s", (ndrift>0)?"REPRODUCED (faded followed live B1 -> the HW bug)":"NOT-REPRODUCED");
`else
        // ============ STEP (c): the fix — faded must STILL equal fade(B0) bit-exact =======
        $display("STEP (c) buffered-snapshot fix: faded frozen despite live B1 -> %s",
                 (m==2048)?"PASS (bit-exact fade(B0), all 2048)":"FAIL");
        if(m!=2048) for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]!=goldf[i]) begin
            $display("   first mismatch @%0d rtl=%06x golden=%06x", i,u_dut.u_pal.u_ram.mem[i],goldf[i]); i=2048; end

        // ============ STEP (c2): now a REAL DMA must adopt B1 (snapshot advances) =========
        // Prove the freeze is DMA-gated, not a dead path: a paldma snapshots live(B1) and
        // faded becomes fade(B1). (buffered half also == B1.)
        LVBL=1'b0; pulse_paldma; repeat(20000) @(posedge clk); LVBL=1'b1;
        m=0; for(i=0;i<2048;i=i+1) begin : chk
            reg [7:0] r,g,b, fr,fg,fb; reg [23:0] want;
            r=B1[i][7:0]; g=B1[i][15:8]; b=B1[i][23:16];
            // recompute fade(B1) here to compare (mult/add per cfg) — independent of RTL
            fr = `FADE_MULT ? mfade(r, ptr, psr) : afade(r, psr);
            fg = `FADE_MULT ? mfade(g, ptg, psg) : afade(g, psg);
            fb = `FADE_MULT ? mfade(b, ptb, psb) : afade(b, psb);
            want = {fb,fg,fr};
            if(u_dut.u_pal.u_ram.mem[i]==want) m=m+1;
        end
        $display("STEP (c2) after a REAL DMA of live B1: faded==fade(B1) on %0d/2048 -> %s",
                 m, (m==2048)?"PASS (snapshot advances on DMA)":"FAIL");
        $display("RESULT: %s", (ndrift==0 && m==2048)?"PASS":"FAIL");
`endif
        $finish;
    end

    // independent fade math (for the step-c2 fade(B1) recompute)
    function [7:0] mfade(input [7:0] c, input [7:0] pt, input [7:0] ps);
        reg [16:0] t; begin
            if(pt>=c) begin t=(pt-c)*ps; mfade=c+(t/255); end
            else      begin t=(c-pt)*ps; mfade=c-(t/255); end
        end
    endfunction
    function [7:0] afade(input [7:0] c, input [7:0] ps);
        reg [8:0] s; begin s={1'b0,c}+{1'b0,ps}; afade=s[8]?8'hFF:s[7:0]; end
    endfunction
endmodule
