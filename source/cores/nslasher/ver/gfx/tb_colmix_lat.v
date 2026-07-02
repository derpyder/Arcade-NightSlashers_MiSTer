`timescale 1ns/1ps
`define SIMULATION
// LATENCY-CORRECT pipeline probe. Same vectors/golden as tb_colmix_alpha, but the colmix inputs are delayed
// ONE clock (modelling the obj-buffer / tilemap RAM latency = inputs valid at pcen_d, NOT coincident with
// pxl_cen as the old TBs assume). A coherent mixer is latency-invariant and still matches the golden; a mixer
// that latches the under-pixel/control on pxl_cen (stale) while reading o1pen/mist on pcen_d/dd (fresh) will
// MISMATCH -> proves the comb/dithering slip. We sweep the capture offset so a pure capture-shift can't be
// mistaken for the slip.
module tb_colmix_lat;
    localparam N = 800;
    reg          clk=0;
    reg  [ 7:0]  pf1=0, pf2=0, pf3=0, pf4=0;
    reg  [15:0]  obj0=0, obj1=0;
    reg  [47:0]  ace=0;
    reg          pcen=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    // ---- 1-clk input latency (the real obj-buffer / tilemap delay the old TBs omit) ----
    reg [7:0] pf1_l, pf2_l, pf3_l, pf4_l; reg [15:0] obj0_l, obj1_l; reg [47:0] ace_l;
    always @(posedge clk) begin
        pf1_l<=pf1; pf2_l<=pf2; pf3_l<=pf3; pf4_l<=pf4; obj0_l<=obj0; obj1_l<=obj1; ace_l<=ace;
    end

    reg [ 7:0] spf1[0:N-1], spf2[0:N-1], spf3[0:N-1], spf4[0:N-1];
    reg [15:0] so0[0:N-1], so1[0:N-1];
    reg [47:0] sace[0:N-1];
    reg [23:0] pal[0:2047];
    reg [23:0] gnew[0:N-1], fb2[0:N-1], fb3[0:N-1];
    integer i, m2, m3;

    initial begin
        $readmemh("ta_pf1.hex",spf1); $readmemh("ta_pf2.hex",spf2);
        $readmemh("ta_pf3.hex",spf3); $readmemh("ta_pf4.hex",spf4);
        $readmemh("ta_obj0.hex",so0); $readmemh("ta_obj1.hex",so1);
        $readmemh("ta_ace.hex",sace); $readmemh("ta_pal.hex",pal);
        $readmemh("ta_golden.hex",gnew);
    end

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pcen),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_pxl(pf1_l), .pf2_pxl(pf2_l), .pf3_pxl(pf3_l), .pf4_pxl(pf4_l),     // DELAYED inputs
        .obj0_pxl(obj0_l), .obj1_pxl(obj1_l),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0),
        .ace_alpha(ace_l), .LVBL(1'b1), .ace_fade(48'd0), .fade_mult(1'b0), .fade_trig(1'b0), .paldma(1'b0),
        .ace_tile(64'd0), .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    reg [1:0] ph = 2'd0; reg run = 0; integer fidx = 0;
    always @(posedge clk) if(run) begin
        ph <= ph + 2'd1; pcen <= (ph==2'd3);
        if(ph==2'd3) begin
            if(fidx>=3 && fidx<=N+2) fb3[fidx-3] <= {blue,green,red};   // capture at latency-2 and latency-3
            if(fidx>=2 && fidx<=N+1) fb2[fidx-2] <= {blue,green,red};
            if(fidx<N) begin pf1<=spf1[fidx]; pf2<=spf2[fidx]; pf3<=spf3[fidx]; pf4<=spf4[fidx];
                             obj0<=so0[fidx]; obj1<=so1[fidx]; ace<=sace[fidx]; end
            fidx <= fidx + 1;
        end
    end

    initial begin
        @(posedge clk);
        for(i=0;i<2048;i=i+1) begin u_dut.u_pal.u_ram.mem[i]=pal[i]; u_dut.u_pal.u_ram.mem[2048+i]=pal[i]; end
        @(posedge clk); run<=1;
        wait(fidx>=N+3); @(posedge clk);
        m2=0; m3=0;
        for(i=0;i<N;i=i+1) begin if(fb2[i]==gnew[i]) m2=m2+1; if(fb3[i]==gnew[i]) m3=m3+1; end
        $display("=== LATENCY-CORRECT colmix probe (1-clk input delay, %0d vectors) ===", N);
        $display("vs coherent golden @capture-offset 2: %0d/%0d", m2, N);
        $display("vs coherent golden @capture-offset 3: %0d/%0d", m3, N);
        $display("BEST = %0d/%0d -> %s", (m2>m3?m2:m3), N,
                 ((m2==N)||(m3==N)) ? "COHERENT (no slip)" : "SLIP CONFIRMED (no capture offset is clean = real comb artifact)");
        for(i=0;i<N;i=i+1) if(fb2[i]!=gnew[i] && fb3[i]!=gnew[i]) begin
            $display("  first hard mismatch @%0d: fb2=%06x fb3=%06x golden=%06x (pf2=%02x obj1=%04x ace=%012x)",
                     i, fb2[i], fb3[i], gnew[i], spf2[i], so1[i], sace[i]); i=N; end
        $finish;
    end
endmodule
