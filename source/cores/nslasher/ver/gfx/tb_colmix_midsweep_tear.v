`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// ============================================================================
// PROOF (1): genuine MID-SWEEP torn-snapshot repro against the OLD single-RAM
// Build B design (jtnslasher_colmix.v.orig-buffered-fix-bak — real undamaged
// baseline, raw/faded address-split in ONE RAM, FSM sweeps the SAME raw half
// pal_we writes to).
//
// Preload raw half (upper, addr 2048+i) = B0. Fire fade_trig to start the sweep
// (fsm_idx 0..2047). Let the sweep run PARTWAY (a fixed number of clocks so only
// some idx have been swept), then slam the ENTIRE raw half with a batch of writes
// = B1 in a tight back-to-back burst (one pal_we per clock, no gaps). Let the
// sweep finish. Because the FSM reads the raw half LIVE (p1_addr={1,fsm_idx}),
// any index not-yet-swept at the moment the batch write to that index lands will
// pick up (parts of) B1 instead of B0 -> a torn mix that is neither fade(B0) nor
// fade(B1) as a whole.
// ============================================================================
module tb_colmix_midsweep_tear;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047], goldB0[0:2047], goldB1[0:2047];
    integer i, m0, m1, torn, k;

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
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    // independent fade math re-derivation (cross-check only; golden files are the real source)
    function [7:0] mfade(input [7:0] c, input [7:0] pt, input [7:0] ps);
        reg [16:0] t; begin
            if(pt>=c) begin t=(pt-c)*ps; mfade=c+(t/255); end
            else      begin t=(c-pt)*ps; mfade=c-(t/255); end
        end
    endfunction
    function [7:0] afade(input [7:0] c, input [7:0] ps);
        reg [8:0] s; begin s={1'b0,c}+{1'b0,ps}; afade=s[8]?8'hFF:s[7:0]; end
    endfunction

    initial begin
        $readmemh("tf_buf.hex",  B0);   // buffered/B0 image (also the "raw" preload here)
        $readmemh("tf_live.hex", B1);   // the mid-sweep batch rewrite image
        $readmemh("tf_faded.hex", goldB0); // golden fade(B0)
        #1;   // let the ACE_FADE-derived wires (ptr/ptg/.../psb) settle past X before use
        for(i=0;i<2048;i=i+1) begin : mkg1
            reg [7:0] r,g,b,fr,fg,fb;
            r=B1[i][7:0]; g=B1[i][15:8]; b=B1[i][23:16];
            fr = `FADE_MULT ? mfade(r, ptr, psr) : afade(r, psr);
            fg = `FADE_MULT ? mfade(g, ptg, psg) : afade(g, psg);
            fb = `FADE_MULT ? mfade(b, ptb, psb) : afade(b, psb);
            goldB1[i] = {fb,fg,fr};
        end

        @(posedge clk);
        for(i=0;i<4096;i=i+1) u_dut.u_pal.u_ram.mem[i]=24'd0;
        for(i=0;i<2048;i=i+1) u_dut.u_pal.u_ram.mem[2048+i]=B0[i];   // raw half = B0
        @(posedge clk);

        LVBL=1'b0;                                    // VBLANK: FSM may run
        @(posedge clk); fade_trig=1'b1;
        @(posedge clk); fade_trig=1'b0;

        // let the sweep run PARTWAY: ~4-5 clk/entry (FR,FC,FM1,FM2,FW) -> ~800 entries in 3600 clks
        repeat(3600) @(posedge clk);

        // BATCH rewrite: slam the WHOLE raw half with B1 in a tight back-to-back burst
        for(i=0;i<2048;i=i+1) begin
            @(posedge clk); pal_we<=1'b1; pal_waddr<=i[10:0]; pal_din<=B1[i];
        end
        @(posedge clk); pal_we<=1'b0;

        // let the sweep finish
        repeat(20000) @(posedge clk);
        LVBL=1'b1;

        m0=0; m1=0; torn=0;
        for(i=0;i<2048;i=i+1) begin
            if(u_dut.u_pal.u_ram.mem[i]==goldB0[i]) m0=m0+1;
            if(u_dut.u_pal.u_ram.mem[i]==goldB1[i]) m1=m1+1;
            if(u_dut.u_pal.u_ram.mem[i]!=goldB0[i]) torn=torn+1;
        end
        $display("=== PROOF(1) mid-sweep TORN-SNAPSHOT repro, OLD single-RAM design (cfg ace_fade=%012x mult=%b) ===",
                 `ACE_FADE, `FADE_MULT);
        $display("faded[] == fade(B0) fully-coherent golden : %0d/2048", m0);
        $display("faded[] == fade(B1) fully-coherent golden : %0d/2048", m1);
        $display("faded[] MISMATCHING fade(B0) (torn count)  : %0d/2048", torn);
        $display("dialog pen[0]: rtl=%06x  fade(B0)=%06x  fade(B1)=%06x",
                 u_dut.u_pal.u_ram.mem[0], goldB0[0], goldB1[0]);
        $display("dialog pen[1]: rtl=%06x  fade(B0)=%06x  fade(B1)=%06x",
                 u_dut.u_pal.u_ram.mem[1], goldB0[1], goldB1[1]);
        $display("dialog pen[3]: rtl=%06x  fade(B0)=%06x  fade(B1)=%06x",
                 u_dut.u_pal.u_ram.mem[3], goldB0[3], goldB1[3]);
        for(k=0;k<3;k=k+1) begin : grad
            i = 16 + k*80;   // a few gradient entries spread across the sweep window
            $display("gradient pen[%0d]: rtl=%06x  fade(B0)=%06x  fade(B1)=%06x",
                     i, u_dut.u_pal.u_ram.mem[i], goldB0[i], goldB1[i]);
        end
        $display("RESULT: %s", (torn>0 && m0<2048 && m1<2048) ?
            "TORN MIX CONFIRMED (neither fully fade(B0) nor fully fade(B1))" : "NOT torn (unexpected)");
        $finish;
    end
endmodule
