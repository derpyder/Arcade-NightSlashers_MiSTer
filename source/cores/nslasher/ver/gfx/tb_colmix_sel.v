`timescale 1ns/1ps
`define SIMULATION
// Build B coloffs select incl. the obj1 sprite1_drawn term (deco32_v.cpp:352/387). RAW and FADED
// halves loaded DISTINCT so the output reveals which half was read.
//   obj0            : raw when pri[2]==0          (coloffs = ~pri2)
//   obj1 + obj0-under: raw when pri[2]==0          (coloffs = ~pri2 & sprite1_drawn, drawn=1)
//   obj1 on floor   : FADED always                (sprite1_drawn=0 -> the shadow case)
//   PF              : FADED always
module tb_colmix_sel;
    localparam N = 5;
    reg          clk=0;
    reg  [ 7:0]  pf2=0;
    reg  [15:0]  obj0=0, obj1=0;
    reg  [ 2:0]  pri=0;
    reg          pcen=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    function [23:0] RAW (input [11:0] i); RAW  = {8'h11, 8'h22, i[7:0]}; endfunction // 0x1122_II
    function [23:0] FADE(input [11:0] i); FADE = {i[7:0], 8'h33, 8'h44}; endfunction // 0xII_3344

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pcen), .LVBL(1'b1),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_pxl(8'd0), .pf2_pxl(pf2), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(obj0), .obj1_pxl(obj1),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(pri), .ace_alpha(48'd0),
        .ace_fade(48'd0), .fade_mult(1'b0), .fade_trig(1'b0), .paldma(1'b0),
        .obj1_base(3'd6),
        .red(red), .green(green), .blue(blue) );

    // obj0 p0=0 col=2 pen=7 -> o0pen 0x447 ; obj1 opaque p1=2 col=3 pen=5 -> o1pen 0x635
    localparam [15:0] OBJ0 = (0<<13)|(2<<8)|8'h07;        // o0on, p0=0 -> o0draw
    localparam [11:0] O0PEN = 12'h447;
    localparam [15:0] OBJ1 = (0<<15)|(2<<13)|(3<<8)|8'h05; // opaque (no alpha bit), p1=2
    localparam [11:0] O1PEN = 12'h635;
    localparam [ 7:0] PF2V = 8'h24;
    localparam [11:0] PF2PEN = 12'h124;

    reg [2:0]  vpri  [0:N-1];
    reg [7:0]  vpf2  [0:N-1];
    reg [15:0] vo0   [0:N-1], vo1 [0:N-1];
    reg [23:0] vexp  [0:N-1], fb[0:N-1];
    integer i, m;

    initial begin
        for(i=0;i<2048;i=i+1) begin
            u_dut.u_pal.u_ram.mem[i]=FADE(i);
            u_dut.u_live.u_ram.mem[i]=RAW(i); u_dut.u_live_shadow.u_ram.mem[i]=RAW(i);
        end
        // v0: obj1 on bare floor (no obj0) pri2=0 -> sprite1_drawn=0 -> FADED  (the shadow case)
        vpri[0]=3'd0; vpf2[0]=0; vo0[0]=0;    vo1[0]=OBJ1; vexp[0]=FADE(O1PEN);
        // v1: obj1 over obj0, pri2=0 -> sprite1_drawn=1 -> RAW
        vpri[1]=3'd0; vpf2[1]=0; vo0[1]=OBJ0; vo1[1]=OBJ1; vexp[1]=RAW(O1PEN);
        // v2: obj0 only, pri2=0 -> RAW (obj0 coloffs = ~pri2)
        vpri[2]=3'd0; vpf2[2]=0; vo0[2]=OBJ0; vo1[2]=0;    vexp[2]=RAW(O0PEN);
        // v3: obj0 only, pri2=1 -> FADED
        vpri[3]=3'd4; vpf2[3]=0; vo0[3]=OBJ0; vo1[3]=0;    vexp[3]=FADE(O0PEN);
        // v4: PF only -> FADED
        vpri[4]=3'd0; vpf2[4]=PF2V; vo0[4]=0; vo1[4]=0;    vexp[4]=FADE(PF2PEN);
    end

    reg [1:0] ph=0; reg run=0; integer fidx=0;
    always @(posedge clk) if(run) begin
        ph <= ph+2'd1; pcen <= (ph==2'd3);
        if(ph==2'd3) begin
            if(fidx>=2 && fidx<=N+1) fb[fidx-2] <= {blue,green,red};   // 4-phase pipeline = +1 pixel latency
            if(fidx<N) begin pf2<=vpf2[fidx]; obj0<=vo0[fidx]; obj1<=vo1[fidx]; pri<=vpri[fidx]; end
            fidx <= fidx+1;
        end
    end

    initial begin
        @(posedge clk); @(posedge clk); run<=1;
        wait(fidx>=N+2); @(posedge clk);
        m=0;
        for(i=0;i<N;i=i+1) begin
            if(fb[i]==vexp[i]) m=m+1;
            $display("  v%0d pri2=%b o0=%04x o1=%04x : rtl=%06x exp=%06x %s",
                     i, vpri[i][2], vo0[i], vo1[i], fb[i], vexp[i], (fb[i]==vexp[i])?"OK":"<-- MISMATCH");
        end
        $display("=== select+sprite1_drawn test: %0d/%0d ===  RESULT: %s", m, N, (m==N)?"PASS":"FAIL");
        $finish;
    end
endmodule
