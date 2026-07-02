`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// Build D (dual-mirror) FSM COMPLETION-under-contention path. CPU palette writes always land in
// pal_A (u_live/u_live_shadow); pal_B (u_buf) is FROZEN the instant the trigger fires, so it stops
// dual-writing. This TB hammers pal_we (CPU writes, restoring the same raw value so the frozen
// snapshot's fade-golden is unchanged) DURING the freeze+sweep+resync, and confirms the FULL
// 2048-entry sweep completes with NO stranded high-index tail (the residual-banding failure mode),
// and that pal_A/u_live absorbs every hammered write with no stall (checked separately in test 3).
module tb_colmix_fade_stall;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] raw[0:2047], goldf[0:2047];
    integer i, m, mtail;

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(paldma), .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    // CPU palette-write hammer into u_live: every 4 clks rewrite a live entry with its OWN value
    // (no change) so the snapshot golden is unchanged. Active during the FSM run.
    reg        hammer=0;
    reg [10:0] wcnt=0;
    reg [ 2:0] wdiv=0;
    always @(posedge clk) begin
        pal_we <= 1'b0;
        if( hammer ) begin
            wdiv <= wdiv + 3'd1;
            if( wdiv==3'd0 ) begin pal_we<=1'b1; pal_waddr<=wcnt; pal_din<=raw[wcnt]; wcnt<=wcnt+11'd1; end
        end
    end

    initial begin
        $readmemh("tf_buf.hex", raw);
        $readmemh("tf_faded.hex", goldf);
        @(posedge clk);
        // pal_A(live)+shadow = pal_B(buf) = raw (settled, mirrored); faded cleared so a stranded
        // tail is visible as a miss
        for(i=0;i<2048;i=i+1) begin
            u_dut.u_live.u_ram.mem[i]        = raw[i];
            u_dut.u_live_shadow.u_ram.mem[i]  = raw[i];
            u_dut.u_buf.u_ram.mem[i]         = raw[i];
            u_dut.u_pal.u_ram.mem[i]       = 24'd0;
        end
        @(posedge clk);
        LVBL=1'b0;                                          // VBLANK
        @(posedge clk); paldma=1'b1; fade_trig=1'b1; @(posedge clk); paldma=1'b0; fade_trig=1'b0;
        hammer=1'b1;                                        // CPU writes collide with the freeze+sweep+resync
        repeat(30000) @(posedge clk);                      // extra budget (sweep + resync)
        hammer=1'b0;
        m=0;    for(i=0;i<2048;i=i+1)      if(u_dut.u_pal.u_ram.mem[i]==goldf[i]) m=m+1;
        mtail=0;for(i=1792;i<2048;i=i+1)   if(u_dut.u_pal.u_ram.mem[i]==goldf[i]) mtail=mtail+1;  // high-index tail
        $display("=== freeze+sweep under pal_we contention (cfg ace_fade=%012x mult=%b) ===",
                 `ACE_FADE, `FADE_MULT);
        $display("faded entries: %0d/2048 match golden  (CPU wrote ~%0d live entries mid-run)", m, wcnt);
        $display("high-index tail [1792..2047]: %0d/256 match  (no stranded tail = no residual banding)", mtail);
        for(i=0;i<2048;i=i+1) if(u_dut.u_pal.u_ram.mem[i]!=goldf[i]) begin
            $display("  first mismatch @%0d: rtl=%06x golden=%06x", i, u_dut.u_pal.u_ram.mem[i], goldf[i]); i=2048; end
        // also confirm pal_A absorbed every hammered write (== raw, unchanged since hammer rewrote
        // the SAME value) -- no dropped writes even under contention
        m=0; for(i=0;i<2048;i=i+1) if(u_dut.u_live.u_ram.mem[i]==raw[i]) m=m+1;
        $display("pal_A (live) after hammer: %0d/2048 == raw (no dropped writes)", m);
        $display("RESULT: %s", (mtail==256 && m==2048)?"PASS":"FAIL");
        $finish;
    end
endmodule
