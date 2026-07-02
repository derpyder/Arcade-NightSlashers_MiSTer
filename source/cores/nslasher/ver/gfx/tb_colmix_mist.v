`timescale 1ns/1ps
`define SIMULATION
// Build C alpha-tilemap (mist) + obj1-alpha — FIX C harness (2026-07-02).
// Drives per-vector pf1/pf2/pf3/obj0/obj1/pri/ace-tile/ace-obj and compares vs the 0284-faithful
// golden (NEW) and the pre-FIX-C golden (OLD), so one run proves correctness AND that the fix
// actually changed the output. Vector count from tm_cfg.vh (gen_mist_test.py).
`include "tm_cfg.vh"
module tb_colmix_mist;
    localparam N = `TMN;
    reg          clk=0;
    reg  [ 7:0]  pf1=0, pf2=0, pf3=0;
    reg  [15:0]  obj0=0, obj1=0;
    reg  [ 2:0]  pri=0;
    reg  [63:0]  ace=0;
    reg  [47:0]  aob=0;
    reg          pcen=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [ 7:0] spf1[0:N-1], spf2[0:N-1], spf3[0:N-1];
    reg [15:0] sobj0[0:N-1], sobj1[0:N-1];
    reg [ 2:0] spri[0:N-1];
    reg [63:0] sace[0:N-1];
    reg [47:0] saob[0:N-1];
    reg [23:0] palr[0:2047], palf[0:2047];
    reg [23:0] gnew[0:N-1], gold[0:N-1], fb[0:N-1];
    integer i, mnew, mold;

    initial begin
        $readmemh("tm_pf1.hex",spf1); $readmemh("tm_pf2.hex",spf2); $readmemh("tm_pf3.hex",spf3);
        $readmemh("tm_obj0.hex",sobj0); $readmemh("tm_obj1.hex",sobj1);
        $readmemh("tm_pri.hex",spri); $readmemh("tm_ace.hex",sace); $readmemh("tm_aob.hex",saob);
        $readmemh("tm_palr.hex",palr); $readmemh("tm_palf.hex",palf);
        $readmemh("tm_golden.hex",gnew); $readmemh("tm_golden_old.hex",gold);
    end

    // LATENCY-CORRECT: 1-clk input delay (the obj-buffer/tilemap RAM latency the real HW has)
    reg [7:0] pf1_l, pf2_l, pf3_l; reg [15:0] obj0_l, obj1_l; reg [2:0] pri_l; reg [63:0] ace_l; reg [47:0] aob_l;
    always @(posedge clk) begin
        pf1_l<=pf1; pf2_l<=pf2; pf3_l<=pf3; obj0_l<=obj0; obj1_l<=obj1; pri_l<=pri; ace_l<=ace; aob_l<=aob;
    end

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pcen), .LVBL(1'b1),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_pxl(pf1_l), .pf2_pxl(pf2_l), .pf3_pxl(pf3_l), .pf4_pxl(8'd0),
        .obj0_pxl(obj0_l), .obj1_pxl(obj1_l),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(pri_l), .ace_alpha(aob_l),
        .ace_fade(48'd0), .fade_mult(1'b0), .fade_trig(1'b0), .paldma(1'b0), .ace_tile(ace_l),
        .obj1_base(3'd6), .tm_bank0(3'd2), .tm_bank1(3'd3),
        .red(red), .green(green), .blue(blue) );

    // cen spacing: default 4-clk (the historical tb ratio) or +CEN8 = the HARDWARE ratio
    // (JTFRAME_PXLCLK=6 from clk=48 -> pxl_cen every 8 clk). The FIX C-CEN no-op bug is ONLY
    // expressible at 8; a correct colmix must pass BOTH. Capture offset: out_rgb for vector V
    // latches at pcen_d4; at 4-clk that is the next pcen edge (offset 2 sampling), at 8-clk it is
    // mid-period so the sample edge sees it one vector earlier (offset 1).
    reg [2:0] ph=0; reg run=0; integer fidx=0;
    reg cen8=0; integer OFS;
    wire [2:0] phmax = cen8 ? 3'd7 : 3'd3;
    initial begin cen8 = $test$plusargs("CEN8"); OFS = cen8 ? 1 : 2; end
    always @(posedge clk) if(run) begin
        ph <= (ph==phmax) ? 3'd0 : ph+3'd1; pcen <= (ph==phmax);
        if(ph==phmax) begin
            if(fidx>=OFS && fidx<=N+OFS-1) fb[fidx-OFS] <= {blue,green,red};
            if(fidx<N) begin pf1<=spf1[fidx]; pf2<=spf2[fidx]; pf3<=spf3[fidx];
                             obj0<=sobj0[fidx]; obj1<=sobj1[fidx]; pri<=spri[fidx];
                             ace<=sace[fidx]; aob<=saob[fidx]; end
            fidx <= fidx+1;
        end
    end

    initial begin
        @(posedge clk);
        for(i=0;i<2048;i=i+1) begin
            // RAW half (pal_A live + mirrors) and FADED half (u_pal lower) are DISTINCT tables so
            // the raw/faded coloffs selects (selA/selB/selC + FIX C-PF1RAW) are discriminated.
            u_dut.u_live.u_ram.mem[i]=palr[i]; u_dut.u_live_shadow.u_ram.mem[i]=palr[i];
            u_dut.u_buf.u_ram.mem[i]=palr[i];
            u_dut.u_pal.u_ram.mem[i]=palf[i];          // lower = FADED
            u_dut.u_pal.u_ram.mem[2048+i]=palr[i];     // upper = raw mirror
        end
        @(posedge clk); run<=1;
        wait(fidx>=N+OFS); @(posedge clk);
        mnew=0; mold=0;
        for(i=0;i<N;i=i+1) begin if(fb[i]==gnew[i]) mnew=mnew+1; if(fb[i]==gold[i]) mold=mold+1; end
        $display("=== mist+obj1 test (%0d vectors, FIX C, cen=%0d clk) ===", N, cen8 ? 8 : 4);
        $display("RTL vs NEW (0284-faithful):   %0d/%0d", mnew, N);
        $display("RTL vs OLD (pre-FIX-C model): %0d/%0d", mold, N);
        for(i=0;i<N;i=i+1) if(fb[i]!=gnew[i]) begin
            $display("  first mismatch @%0d: rtl=%06x golden=%06x (pf1=%02x pf2=%02x pf3=%02x obj0=%04x obj1=%04x pri=%0d ace=%016x aob=%012x)",
                     i, fb[i], gnew[i], spf1[i], spf2[i], spf3[i], sobj0[i], sobj1[i], spri[i], sace[i], saob[i]); i=N; end
        $display("RESULT: %s  (%0d/%0d differ from old-wrong = discriminating)",
                 (mnew==N) ? "PASS" : "FAIL", N-mold, N);
        $finish;
    end
endmodule
