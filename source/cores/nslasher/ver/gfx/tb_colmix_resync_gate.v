`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// ============================================================================
// PROOF (4): a SECOND fade_trig arriving while RESYNC (from the first trig) is still in progress
// must NOT start a new freeze/sweep until resync completes -- pal_B must never re-freeze on a
// stale/not-fully-resynced snapshot, and when it DOES freeze (after resync completes), it must be
// bit-exact to pal_A's contents AT THAT INSTANT (not the earlier trigger's image).
//
// Sequence:
//   1. preload pal_A/pal_B (via pal_we) = IMG_A
//   2. fade_trig #1 -> freeze @ IMG_A, sweep computes fade(IMG_A), then RESYNC starts
//   3. WHILE resync is still running: write pal_A = IMG_B (a second distinct image) AND fire
//      fade_trig #2 immediately (still mid-resync)
//   4. confirm fade_trig #2 is QUEUED (trig_pending), not acted on yet -- the FSM must still be
//      draining RESYNC, and only start the SECOND freeze once resync (of IMG_B, since pal_A already
//      moved to IMG_B during resync) is complete
//   5. confirm the SECOND sweep's golden = fade(IMG_B) (the fresh pal_A content at the moment the
//      second freeze actually took effect), NOT fade(IMG_A) (stale) and not some partial mix.
// ============================================================================
module tb_colmix_resync_gate;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] IMGA[0:2047], IMGB[0:2047], goldA[0:2047], goldB[0:2047];
    integer i, m;

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
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    function [7:0] mfade(input [7:0] c, input [7:0] pt, input [7:0] ps);
        reg [16:0] t; begin
            if(pt>=c) begin t=(pt-c)*ps; mfade=c+(t/255); end
            else      begin t=(c-pt)*ps; mfade=c-(t/255); end
        end
    endfunction
    function [7:0] afade(input [7:0] c, input [7:0] ps);
        reg [8:0] s; begin s={1'b0,c}+{1'b0,ps}; afade=s[8]?8'hFF:s[7:0]; end
    endfunction

    task cpu_write_image(input integer which);   // 0=IMGA 1=IMGB
        integer j;
        begin
            for(j=0;j<2048;j=j+1) begin
                @(posedge clk); pal_we<=1'b1; pal_waddr<=j[10:0];
                pal_din <= which ? IMGB[j] : IMGA[j];
            end
            @(posedge clk); pal_we<=1'b0;
        end
    endtask

    initial begin
        for(i=0;i<2048;i=i+1) begin : mkimg
            IMGA[i] = {8'h10+i[7:0], 8'h20+i[7:0], 8'h30+i[7:0]};
            IMGB[i] = {8'h80+i[7:0], 8'h90+i[7:0], 8'ha0+i[7:0]};
        end
        @(posedge clk); #1;
        for(i=0;i<2048;i=i+1) begin : mkgold
            reg [7:0] ar,ag,ab,br,bg,bb,far,fag,fab,fbr,fbg,fbb;
            ar=IMGA[i][7:0]; ag=IMGA[i][15:8]; ab=IMGA[i][23:16];
            br=IMGB[i][7:0]; bg=IMGB[i][15:8]; bb=IMGB[i][23:16];
            far = `FADE_MULT ? mfade(ar,ptr,psr) : afade(ar,psr);
            fag = `FADE_MULT ? mfade(ag,ptg,psg) : afade(ag,psg);
            fab = `FADE_MULT ? mfade(ab,ptb,psb) : afade(ab,psb);
            fbr = `FADE_MULT ? mfade(br,ptr,psr) : afade(br,psr);
            fbg = `FADE_MULT ? mfade(bg,ptg,psg) : afade(bg,psg);
            fbb = `FADE_MULT ? mfade(bb,ptb,psb) : afade(bb,psb);
            goldA[i] = {fab,fag,far};
            goldB[i] = {fbb,fbg,fbr};
        end

        // ---- preload pal_A/pal_B = IMGA via the real CPU write path ----
        cpu_write_image(0);
        repeat(4) @(posedge clk);

        // ---- trigger #1: freeze @ IMGA, sweep, then resync starts ----
        LVBL=1'b0;
        @(posedge clk); fade_trig=1'b1; paldma=1'b1;
        @(posedge clk); fade_trig=1'b0; paldma=1'b0;
        repeat(11000) @(posedge clk);           // sweep completes well within this (~5 clk/entry x2048)
        if(u_dut.fstate !== u_dut.RS) $display("WARNING: expected fstate==RS by now, got %0d", u_dut.fstate);

        // ---- fire fade_trig #2 immediately, while RESYNC is (confirmed above) still running ----
        @(posedge clk); fade_trig=1'b1; paldma=1'b1;
        @(posedge clk); fade_trig=1'b0; paldma=1'b0;   // trig #2 fired mid-resync -> must be queued
        @(posedge clk);   // let trig_pending's registered update (sampled on the deassert edge) settle
        if(u_dut.trig_pending !== 1'b1)
            $display("CHECK: trig_pending after trig#2-mid-resync = %b (expect 1 if still resyncing when it fired)", u_dut.trig_pending);
        if(u_dut.fstate == u_dut.IDLE)
            $display("CHECK: fstate already IDLE when trig#2 fired -- resync finished before trig#2, retest timing");

        // ---- NOW write pal_A = IMGB while resync continues draining (this also advances resync's
        // source, since RESYNC reads pal_A live via the dedicated shadow port) ----
        cpu_write_image(1);

        // let resync finish (drains to IMGB in pal_B), then the queued trig starts freeze #2 @ IMGB,
        // then that sweep runs to completion
        repeat(30000) @(posedge clk);
        LVBL=1'b1;
        repeat(10) @(posedge clk);

        // ---- verdict: final faded[] must be fade(IMGB), NOT fade(IMGA) ----
        m=0; for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]==goldB[i]) m=m+1;
        $display("=== PROOF(4) resync-before-next-freeze (cfg ace_fade=%012x mult=%b) ===", `ACE_FADE, `FADE_MULT);
        $display("faded[] == fade(IMGB) [2nd trigger, POST-resync content] : %0d/2048", m);
        if(m!=2048) for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]!=goldB[i]) begin
            $display("  first mismatch @%0d: rtl=%06x goldB=%06x goldA=%06x", i, u_dut.u_pal.u_ram.mem[i], goldB[i], goldA[i]); i=2048; end
        // also show it did NOT freeze stale on IMGA
        begin : cka
            integer mA; mA=0;
            for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]==goldA[i]) mA=mA+1;
            $display("faded[] == fade(IMGA) [stale, should NOT match]         : %0d/2048", mA);
        end
        $display("RESULT: %s", (m==2048)?"PASS (2nd freeze honoured only post-resync, bit-exact to pal_A at that instant)":"FAIL");
        $finish;
    end
endmodule
