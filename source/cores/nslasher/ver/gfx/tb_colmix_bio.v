`timescale 1ns/1ps
`define SIMULATION
// FIX B gate: drive jtnslasher_colmix with the captured Jake-bio frame (vancaps f03000, pri=6 =
// JOINT-8bpp mode, ground truth attract_pri.txt) and compare RGB against the bio_render.py golden,
// which is itself 0/76800 vs MAME's own snapshot of the same frame. Streams/golden from
// bio_render.py (cmb_*.hex). Phasing copied from tb_colmix_alpha (4-phase pxl_cen, +1 px latency).
// Expected: FAIL (green-banded ghost) on pre-FIX-B colmix; PASS 76800/76800 after.
`include "cmb_cfg.vh"
module tb_colmix_bio;
    localparam N = 76800;
    reg          clk=0;
    reg  [ 7:0]  pf1=0, pf2=0, pf3=0, pf4=0;
    reg  [15:0]  obj0=0, obj1=0;
    reg          pcen=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [ 7:0] spf1[0:N-1], spf2[0:N-1], spf3[0:N-1], spf4[0:N-1];
    reg [15:0] so0[0:N-1], so1[0:N-1];
    reg [23:0] pal[0:2047], fad[0:2047];
    reg [23:0] gold[0:N-1], fb[0:N-1];
    integer i, m;

    initial begin
        $readmemh("cmb_pf1.hex",spf1); $readmemh("cmb_pf2.hex",spf2);
        $readmemh("cmb_pf3.hex",spf3); $readmemh("cmb_pf4.hex",spf4);
        $readmemh("cmb_obj0.hex",so0); $readmemh("cmb_obj1.hex",so1);
        $readmemh("cmb_pal.hex",pal);  $readmemh("cmb_fade.hex",fad);
        $readmemh("cmb_rgb.hex",gold);
    end

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pcen),
        .LVBL(1'b1),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_pxl(pf1), .pf2_pxl(pf2), .pf3_pxl(pf3), .pf4_pxl(pf4),
        .obj0_pxl(obj0), .obj1_pxl(obj1),
        .en1(`EN1), .en2(`EN2), .en3(`EN3), .en4(`EN4), .pri(`PRI),
        .ace_alpha(`ACEAL),
        .ace_fade(48'd0), .fade_mult(1'b0), .fade_trig(1'b0), .paldma(1'b0),
        .ace_tile(64'd0),
        .obj1_base(`O1BASE), .tm_bank0(`TMB0), .tm_bank1(`TMB1),
        .red(red), .green(green), .blue(blue), .dbg_pixcap(), .dbg_mist() );

    // cen spacing: default 4-clk or +CEN8 = the HARDWARE ratio (JTFRAME_PXLCLK=6 @ clk48 -> 8 clk).
    // out_rgb latches at pcen_d4: capture offset 2 at 4-clk (same edge as the next pcen), 1 at 8-clk.
    reg [2:0] ph = 3'd0;
    reg       run = 0;
    integer   fidx = 0;
    reg cen8=0; integer OFS;
    wire [2:0] phmax = cen8 ? 3'd7 : 3'd3;
    initial begin cen8 = $test$plusargs("CEN8"); OFS = cen8 ? 1 : 2; end
    always @(posedge clk) if(run) begin
        ph   <= (ph==phmax) ? 3'd0 : ph + 3'd1;
        pcen <= (ph==phmax);
        if(ph==phmax) begin
            if(fidx>=OFS && fidx<=N+OFS-1) fb[fidx-OFS] <= {blue,green,red};
            if(fidx<N) begin pf1<=spf1[fidx]; pf2<=spf2[fidx]; pf3<=spf3[fidx]; pf4<=spf4[fidx];
                             obj0<=so0[fidx]; obj1<=so1[fidx]; end
            fidx <= fidx + 1;
        end
    end

    initial begin
        @(posedge clk);
        for(i=0;i<2048;i=i+1) begin
            u_dut.u_live.u_ram.mem[i]=pal[i]; u_dut.u_live_shadow.u_ram.mem[i]=pal[i];
            u_dut.u_buf.u_ram.mem[i]=pal[i];
            u_dut.u_pal.u_ram.mem[i]=fad[i];              // lower half = FADED (bio fade = identity)
            u_dut.u_pal.u_ram.mem[2048+i]=pal[i];         // upper half = raw mirror
        end
        @(posedge clk); run<=1;
        wait(fidx>=N+OFS);
        @(posedge clk);
        m=0;
        for(i=0;i<N;i=i+1) if(fb[i]==gold[i]) m=m+1;
        $display("=== colmix JOINT-8bpp bio replay (%0d px) ===", N);
        $display("RTL vs bio_render golden (== MAME snapshot): %0d/%0d match", m, N);
        for(i=0;i<N;i=i+1) if(fb[i]!=gold[i]) begin
            $display("  first mismatch @%0d (x=%0d y=%0d): rtl=%06x golden=%06x (pf3=%02x pf4=%02x pf1=%02x)",
                     i, i%320, i/320, fb[i], gold[i], spf3[i], spf4[i], spf1[i]); i=N; end
        if(m==N) $display("RESULT: PASS");
        else     $display("RESULT: FAIL (%0d mismatches)", N-m);
        $finish;
    end
endmodule
