`timescale 1ns/1ps
`include "colmix_cfg.vh"
// Validate jtnslasher_colmix (single-RAM, time-multiplexed read) vs ref_render. Drives a clean
// clk/4 pixel strobe (as the real jtframe_vtimer does): present pixel inputs at ph==3 so they're
// stable when pxl_cen pulses (ph==0); the colmix reads portA (ph0) then portB (ph1), out at ph3.
module tb_colmix2;
    reg          clk=0;
    reg  [ 7:0]  pf1=0, pf2=0, pf3=0, pf4=0;
    reg  [15:0]  obj0=0, obj1=0;
    reg          pcen=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [ 7:0] spf1[0:76799], spf2[0:76799], spf3[0:76799], spf4[0:76799];
    reg [15:0] so0 [0:76799], so1 [0:76799];
    reg [31:0] pal [0:2047];
    reg [23:0] golden[0:76799], fb[0:76799];
    integer i, match;

    initial begin
        $readmemh("cm_pf1.hex",spf1); $readmemh("cm_pf2.hex",spf2);
        $readmemh("cm_pf3.hex",spf3); $readmemh("cm_pf4.hex",spf4);
        $readmemh("cm_obj0.hex",so0); $readmemh("cm_obj1.hex",so1);
        $readmemh(`PALFILE,pal);      $readmemh("cm_rgb.hex",golden);
    end

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pcen),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_pxl(pf1), .pf2_pxl(pf2), .pf3_pxl(pf3), .pf4_pxl(pf4),
        .obj0_pxl(obj0), .obj1_pxl(obj1),
        .en1(`EN1), .en2(`EN2), .en3(`EN3), .en4(`EN4), .pri(`PRI),
        .red(red), .green(green), .blue(blue) );

    // clean clk/4 strobe; present inputs + capture at ph==3
    reg [1:0] ph = 2'd0;
    reg       run = 0;
    integer   fidx = 0;
    always @(posedge clk) if(run) begin
        ph   <= ph + 2'd1;
        pcen <= (ph==2'd3);                          // pcen high during ph==0 (0 the clk before)
        if(ph==2'd3) begin
            if(fidx>0 && fidx<=76800) fb[fidx-1] <= {blue,green,red};   // out for the prev presented pixel
            if(fidx<76800) begin pf1<=spf1[fidx]; pf2<=spf2[fidx]; pf3<=spf3[fidx]; pf4<=spf4[fidx]; obj0<=so0[fidx]; obj1<=so1[fidx]; end
            fidx <= fidx + 1;
        end
    end

    initial begin
        @(posedge clk);
        for(i=0;i<2048;i=i+1) u_dut.u_pal.u_ram.mem[i]=pal[i][23:0];   // direct palette load (single RAM)
        @(posedge clk); run<=1;
        wait(fidx>=76801);
        match=0;
        for(i=0;i<76800;i=i+1) if(fb[i]==golden[i]) match=match+1;
        $display("colmix compare: %0d/76800 match (%.3f%%)", match, 100.0*match/76800.0);
        for(i=0;i<76800;i=i+1) if(fb[i]!=golden[i]) begin
            $display("  first mismatch (%0d,%0d): rtl=%06x golden=%06x", i%320, i/320, fb[i], golden[i]); i=76800; end
        $finish;
    end
endmodule
