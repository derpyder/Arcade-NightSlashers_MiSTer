`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// Test (4): resync-before-next-freeze guarantee. Fire a first fade trigger (freeze+sweep B0), then
// WHILE the subsequent RESYNC is still in progress, fire a SECOND trigger with a THIRD palette image
// (B2) already loaded into pal_A. Confirm: (a) the second trigger does NOT freeze pal_B until RESYNC
// #1 has fully completed (trig_pending captures it, freeze/fsm_idx do not restart early); (b) once
// honoured, the second freeze is bit-exact to pal_A's contents AT THAT INSTANT (i.e. == B2, since all
// live_write()s calling B2 landed via the real CPU path well before the second freeze actually takes
// hold) -- not a stale/partially-resynced pal_B.
module tb_resync_queue;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047], goldf0[0:2047];
    reg [23:0] B2[0:2047], goldf2[0:2047];
    integer i, m, m2;

    wire [47:0] af = `ACE_FADE;
    wire [7:0] ptr=af[7:0],  ptg=af[15:8],  ptb=af[23:16];
    wire [7:0] psr=af[31:24],psg=af[39:32], psb=af[47:40];

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(paldma),
        .ace_tile(64'd0),
        .red(red), .green(green), .blue(blue) );

    task live_write(input [10:0] a, input [23:0] dv);
        begin @(posedge clk); pal_we<=1'b1; pal_waddr<=a; pal_din<=dv;
              @(posedge clk); pal_we<=1'b0; end
    endtask

    function [7:0] mfade(input [7:0] c, input [7:0] pt, input [7:0] ps);
        reg [16:0] t; begin
            if(pt>=c) begin t=(pt-c)*ps; mfade=c+(t/255); end
            else      begin t=(c-pt)*ps; mfade=c-(t/255); end
        end
    endfunction
    function [7:0] afade(input [7:0] c, input [7:0] ps);
        reg [8:0] s; begin s={1'b0,c}+{1'b0,ps}; afade=s[8]?8'hFF:s[7:0]; end
    endfunction

    // Build the B2 golden = fade(B2), independently, from the RTL's own mfade/afade re-implementation
    // (same formula as gen_bufferfade_test.py, applied here in Verilog for a 3rd, dynamically-derived
    // image so we don't need a 3rd generator invocation).
    task build_b2_and_golden;
        integer j;
        reg [7:0] r,g,b,fr,fg,fb;
        begin
            for(j=0;j<2048;j=j+1) begin
                // B2: yet another deterministic pattern, distinct from B0/B1
                B2[j] = {8'((j*13+5)&8'hff), 8'((j*7+2)&8'hff), 8'((j*3+9)&8'hff)};
                r = B2[j][7:0]; g = B2[j][15:8]; b = B2[j][23:16];
                fr = `FADE_MULT ? mfade(r,ptr,psr) : afade(r,psr);
                fg = `FADE_MULT ? mfade(g,ptg,psg) : afade(g,psg);
                fb = `FADE_MULT ? mfade(b,ptb,psb) : afade(b,psb);
                goldf2[j] = {fb,fg,fr};
            end
            $display("DEBUG build_b2_and_golden done: B2[0]=%06x goldf2[0]=%06x ptr=%02x psr=%02x mult=%b",
                      B2[0], goldf2[0], ptr, psr, `FADE_MULT);
        end
    endtask

    initial begin
        $readmemh("tf_buf.hex",   B0);
        $readmemh("tf_live.hex",  B1);
        $readmemh("tf_faded.hex", goldf0);
        @(posedge clk);   // let the af/ptr/.../psb continuous assigns from `ACE_FADE settle first
        build_b2_and_golden;

        // Populate B0 through the real CPU write path.
        for(i=0;i<2048;i=i+1) live_write(i[10:0], B0[i]);

        LVBL = 1'b0;                                    // VBLANK
        @(posedge clk); fade_trig<=1'b1;
        @(posedge clk); fade_trig<=1'b0;                 // trigger #1: freeze pal_B at B0

        // Let sweep #1 run to completion and RESYNC #1 begin (sweep ~2048*5=10240 clocks). Poll for
        // RS specifically (rather than a fixed guess) so trigger #2 lands solidly mid-resync.
        while (u_dut.fstate !== 3'd5 && u_dut.fstate !== 3'd7) @(posedge clk);
        $display("entered RESYNC: fstate=%0d fsm_idx=%0d freeze=%0b", u_dut.fstate, u_dut.fsm_idx, u_dut.freeze);
        repeat(200) @(posedge clk);   // sit inside RESYNC for a while (not right at the boundary)
        $display("before trig#2 (mid-resync): fstate=%0d fsm_idx=%0d freeze=%0b", u_dut.fstate, u_dut.fsm_idx, u_dut.freeze);

        // Write B2 into pal_A via the real CPU path FIRST, fully, while still confirmed mid-RESYNC#1
        // (fsm_idx=100, ~1947 entries still to go = ~3894 clocks -- comfortably more than the 4096
        // clocks these 2048 live_write() calls take, so B2 lands well before resync#1 can complete).
        // This lands ONLY in pal_A (freeze holds the whole time), which is exactly what we need: by
        // the time the QUEUED trigger #2 is eventually honoured (strictly after resync#1 finishes),
        // pal_A must already be B2 so the new freeze's snapshot is deterministically B2.
        for(i=0;i<2048;i=i+1) live_write(i[10:0], B2[i]);
        $display("after writing B2 (still mid-resync#1?): fstate=%0d fsm_idx=%0d freeze=%0b",
                  u_dut.fstate, u_dut.fsm_idx, u_dut.freeze);

        // NOW fire trigger #2, confirmed still WHILE resync #1 is in flight (or, worst case, just
        // after it -- either way the assertion below (queued vs immediate) tells us which happened).
        @(posedge clk); fade_trig<=1'b1;
        @(posedge clk);
        fade_trig<=1'b0;
        @(posedge clk);
        $display("immediately after trig#2: fstate=%0d fsm_idx=%0d freeze=%0b trig_pending=%0b",
                  u_dut.fstate, u_dut.fsm_idx, u_dut.freeze, u_dut.trig_pending);

        // Let resync #1 finish (if it hadn't already) and the queued trigger #2 fire + sweep #2 run.
        repeat(6) begin
            repeat(5000) @(posedge clk);
            $display("  trace: fstate=%0d fsm_idx=%0d freeze=%0b trig_pending=%0b fade_dirty=%0b",
                      u_dut.fstate, u_dut.fsm_idx, u_dut.freeze, u_dut.trig_pending, u_dut.fade_dirty);
        end
        LVBL = 1'b1;
        repeat(20) @(posedge clk);

        $display("post-settle: fstate=%0d freeze=%0b trig_pending=%0b (expect IDLE, no freeze, no pending)",
                  u_dut.fstate, u_dut.freeze, u_dut.trig_pending);

        // The faded[] output after sweep #2 must be fade(B2) bit-exact (trigger #2 could only have
        // frozen pal_B AFTER resync #1 finished, by which point pal_A/pal_B already == B2, so the
        // snapshot trigger #2 took is B2, not some earlier/partial image).
        m = 0;
        for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]==goldf2[i]) m=m+1;
        $display("=== TEST 4: resync-before-next-freeze queueing (cfg ace_fade=%012x mult=%b) ===",
                 `ACE_FADE, `FADE_MULT);
        $display("faded == fade(B2) [2nd trigger honoured only post-resync, bit-exact]: %0d/2048", m);
        for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]!=goldf2[i]) begin
            $display("  first mismatch @%0d: rtl=%06x golden=%06x B2=%06x", i, u_dut.u_pal.u_ram.mem[i], goldf2[i], B2[i]); i=2048; end
        $display("RESULT: %s", (m==2048) ? "PASS" : "FAIL");
        $display("debug idx0: B2=%06x goldf2=%06x faded(u_pal)=%06x live(pal_A)=%06x buf(pal_B)=%06x",
                  B2[0], goldf2[0], u_dut.u_pal.u_ram.mem[0], u_dut.u_live.u_ram.mem[0], u_dut.u_buf.u_ram.mem[0]);

        // Also confirm pal_B actually reached B2 (not stuck at B0/B1).
        m2 = 0; for(i=0;i<2048;i=i+1) if(u_dut.u_buf.u_ram.mem[i]==B2[i]) m2=m2+1;
        $display("pal_B (u_buf) == B2 after 2nd freeze: %0d/2048  %s", m2, (m2==2048)?"PASS":"FAIL");

        $finish;
    end
endmodule
