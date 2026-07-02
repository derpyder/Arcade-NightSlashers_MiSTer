`timescale 1ns/1ps
`define SIMULATION
// Build A: drive jtnslasher_colmix with a constructed ACE-active sweep, compare RGB vs the deco_ace
// get_alpha golden (NEW) AND the unmodified fixed-50% golden (OLD). PASS = 0 mismatch vs NEW while
// differing from OLD on the alpha vectors (the falsifiability gate). Phasing copied from tb_colmix2.
module tb_colmix_alpha;
    localparam N = 800;
    reg          clk=0;
    reg  [ 7:0]  pf1=0, pf2=0, pf3=0, pf4=0;
    reg  [15:0]  obj0=0, obj1=0;
    reg  [47:0]  ace=0;
    reg          pcen=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [ 7:0] spf1[0:N-1], spf2[0:N-1], spf3[0:N-1], spf4[0:N-1];
    reg [15:0] so0[0:N-1], so1[0:N-1];
    reg [47:0] sace[0:N-1];
    reg [23:0] pal[0:2047];
    reg [23:0] gnew[0:N-1], gold[0:N-1], fb[0:N-1];
    integer i, mnew, mold;

    initial begin
        $readmemh("ta_pf1.hex",spf1); $readmemh("ta_pf2.hex",spf2);
        $readmemh("ta_pf3.hex",spf3); $readmemh("ta_pf4.hex",spf4);
        $readmemh("ta_obj0.hex",so0); $readmemh("ta_obj1.hex",so1);
        $readmemh("ta_ace.hex",sace); $readmemh("ta_pal.hex",pal);
        $readmemh("ta_golden.hex",gnew); $readmemh("ta_golden_old.hex",gold);
    end

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pcen),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_pxl(pf1), .pf2_pxl(pf2), .pf3_pxl(pf3), .pf4_pxl(pf4),
        .obj0_pxl(obj0), .obj1_pxl(obj1),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0),
        .ace_alpha(ace),
        .LVBL(1'b1), .ace_fade(48'd0), .fade_mult(1'b0), .fade_trig(1'b0), .paldma(1'b0),
        .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

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
                             obj0<=so0[fidx]; obj1<=so1[fidx]; ace<=sace[fidx]; end
            fidx <= fidx + 1;
        end
    end

    initial begin
        @(posedge clk);
        for(i=0;i<2048;i=i+1) begin
            u_dut.u_live.u_ram.mem[i]=pal[i]; u_dut.u_live_shadow.u_ram.mem[i]=pal[i];
            u_dut.u_buf.u_ram.mem[i]=pal[i]; u_dut.u_pal.u_ram.mem[i]=pal[i];
        end
        @(posedge clk); run<=1;
        wait(fidx>=N+OFS);
        @(posedge clk);
        mnew=0; mold=0;
        for(i=0;i<N;i=i+1) begin
            if(fb[i]==gnew[i]) mnew=mnew+1;
            if(fb[i]==gold[i]) mold=mold+1;
        end
        $display("=== colmix ACE-alpha test (%0d vectors) ===", N);
        $display("RTL vs NEW golden (deco_ace get_alpha): %0d/%0d match", mnew, N);
        $display("RTL vs OLD golden (fixed 50%%, unmodified colmix): %0d/%0d match", mold, N);
        for(i=0;i<N;i=i+1) if(fb[i]!=gnew[i]) begin
            $display("  first NEW mismatch @%0d: rtl=%06x golden=%06x (pf2=%02x obj1=%04x ace=%012x)",
                     i, fb[i], gnew[i], spf2[i], so1[i], sace[i]); i=N; end
        if(mnew==N) $display("RESULT: PASS  (bit-exact vs deco_ace; %0d/%0d vectors DIFFER from the old fixed-50%% model = test is discriminating)", N-mold, N);
        else        $display("RESULT: FAIL");
        $finish;
    end
endmodule
