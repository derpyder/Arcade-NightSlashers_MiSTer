`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
// Test (1): reproduce the torn-snapshot bug on the RECONSTRUCTED nf16-style OLD design
// (jtnslasher_colmix_OLD_nf16.v). Preload live=B0, fire a paldma trigger to start the FSM
// sweep in VBLANK, then MID-SWEEP (after idx has passed some entries, before others) issue a
// tight-burst batch of CPU writes replacing live with B1 over the SAME dialog+gradient range.
// Let the sweep finish. Expect: u_pal upper (buffered) / lower (faded) is a TORN MIX -- NOT
// equal to fade(B0) nor fade(B1) as a whole.
module tb_torn_OLD;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047], goldf0[0:2047];
    integer i, m0, m1, mtorn, k;

    // fade regs unpacked into named bytes (can't bit-select a macro literal directly)
    wire [47:0] af = `ACE_FADE;
    wire [7:0] ptr=af[7:0],  ptg=af[15:8],  ptb=af[23:16];
    wire [7:0] psr=af[31:24],psg=af[39:32], psb=af[47:40];

    jtnslasher_colmix_OLD_nf16 u_dut(
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
        $readmemh("tf_buf.hex",   B0);
        $readmemh("tf_live.hex",  B1);
        $readmemh("tf_faded.hex", goldf0);   // golden = fade(B0), the coherent answer if no tear

        @(posedge clk);
        for(i=0;i<4096;i=i+1) u_dut.u_pal.u_ram.mem[i]=24'd0;
        for(i=0;i<2048;i=i+1) u_dut.u_live.u_ram.mem[i]=B0[i];
        @(posedge clk);

        LVBL = 1'b0;                                    // enter VBLANK, FSM may run
        @(posedge clk); paldma<=1'b1; fade_trig<=1'b1;
        @(posedge clk); paldma<=1'b0; fade_trig<=1'b0;

        // Sweep runs ~6 clk/entry (FR,FC,FM1,FM2,FW,FW2). Let it advance partway (idx ~ 800/2048)
        // then fire the batch rewrite. 800*6 = 4800 clocks.
        repeat(4800) @(posedge clk);
        $display("mid-sweep fsm_idx=%0d (partial progress, some entries done, most not)", u_dut.fsm_idx);

        // Tight-burst batch write of B1 over ALL 2048 entries (worst case: covers dialog [0:15]
        // and gradient [16:271] entirely), simulating a scene-transition palette load.
        for(i=0;i<2048;i=i+1) live_write(i[10:0], B1[i]);

        // Let the sweep finish.
        repeat(15000) @(posedge clk);
        LVBL = 1'b1;

        m0 = 0; m1 = 0; mtorn = 0;
        for(i=0;i<2048;i=i+1) begin : chk
            reg [7:0] r1,g1,b1_,fr,fg,fb; reg [23:0] wantB1;
            if (u_dut.u_pal.u_ram.mem[i]==goldf0[i]) m0=m0+1;
            r1=B1[i][7:0]; g1=B1[i][15:8]; b1_=B1[i][23:16];
            fr = `FADE_MULT ? mfade(r1, ptr, psr) : afade(r1, psr);
            fg = `FADE_MULT ? mfade(g1, ptg, psg) : afade(g1, psg);
            fb = `FADE_MULT ? mfade(b1_,ptb, psb) : afade(b1_,psb);
            wantB1 = {fb,fg,fr};
            if (u_dut.u_pal.u_ram.mem[i]==wantB1) m1=m1+1;
        end
        mtorn = 2048 - m0 - m1;  // neither fade(B0) nor fade(B1) -- outright garbage/mixed state possible too

        $display("=== TEST 1: torn-snapshot repro on OLD (nf16-style live-sweep) design ===");
        $display("faded == fade(B0) [coherent pre-batch answer] : %0d/2048", m0);
        $display("faded == fade(B1) [coherent post-batch answer]: %0d/2048", m1);
        $display("faded == NEITHER (torn/incoherent)            : %0d/2048", mtorn);
        $display("RESULT: %s", (m0!=2048 && m0!=0) ? "TORN MIX REPRODUCED (bug confirmed)" :
                                 (m0==2048 ? "NOT REPRODUCED (all fade(B0) -- unexpected)" :
                                             "NOT REPRODUCED (all fade(B1) -- unexpected)"));

        $display("---- dialog pen samples (idx 0..3) ----");
        for(i=0;i<4;i=i+1) begin : dlg
            reg [7:0] fr1,fg1,fb1; reg [23:0] fadeB1;
            fr1 = `FADE_MULT ? mfade(B1[i][7:0],  ptr,psr) : afade(B1[i][7:0],  psr);
            fg1 = `FADE_MULT ? mfade(B1[i][15:8], ptg,psg) : afade(B1[i][15:8], psg);
            fb1 = `FADE_MULT ? mfade(B1[i][23:16],ptb,psb) : afade(B1[i][23:16],psb);
            fadeB1 = {fb1,fg1,fr1};
            $display("  dialog[%0d]: B0=%06x B1=%06x  RTL=%06x  fade(B0)=%06x  fade(B1)=%06x",
                     i, B0[i], B1[i], u_dut.u_pal.u_ram.mem[i], goldf0[i], fadeB1);
        end

        $display("---- gradient pen samples (idx 16,50,100,200,271) ----");
        for(k=0;k<5;k=k+1) begin : grad
            reg [10:0] gi;
            case(k) 0: gi=16; 1:gi=50; 2:gi=100; 3:gi=200; default: gi=271; endcase
            $display("  grad[%0d]: B0=%06x B1=%06x  RTL=%06x  fade(B0)=%06x",
                     gi, B0[gi], B1[gi], u_dut.u_pal.u_ram.mem[gi], goldf0[gi]);
        end

        $finish;
    end
endmodule
