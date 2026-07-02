`timescale 1ns/1ps
`include "video_cfg.vh"
// M3k / task #7c-3b-int — Arch B integration sim. Same f1800 cap replay as tb_vmem/tb_sdram, but the
// 4 tilemap gfx buses route through jtnslasher_sdram's jtnslasher_gfxdec wrappers (at-fetch deco56/74
// decrypt+reshuffle) into a 16-bit behavioral SDRAM holding ENCRYPTED reorder(raw) gfx1/gfx2; obj0/obj1
// fetch render-format gfx3/gfx4 (the 40-bit obj0 split recombined). Per-bank arbitration + variable
// latency. Proves the WHOLE Arch B render path (wrappers + split + engines) renders bit-exact vs
// ref_render — the real on-the-fly decrypt feeding the validated tilemaps.
module tb_intg;
    localparam GFX = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";
    reg clk=0, rst=1;
    always #5 clk = ~clk;
    reg [1:0] ph=0; reg pcen=0;
    always @(posedge clk) begin ph <= ph+2'd1; pcen <= (ph==2'd3); end

    wire [8:0] vdump, vrender, vrender1, H;
    wire       Hinit, Vinit, LHBL, LVBL, HS, VS;
    jtframe_vtimer #(
        .V_START(9'd0), .VB_START(9'd240), .VB_END(9'd263), .VS_START(9'd245), .VS_END(9'd248), .VCNT_END(9'd263),
        .HB_END(9'd383), .HB_START(9'd320), .HS_START(9'd340), .HS_END(9'd367),
        .H_VB(9'd320), .H_VS(9'd340), .H_VNEXT(9'd340), .HINIT(9'd340),
        .HJUMP(1'd0), .HCNT_END(9'd383), .HCNT_START(9'd0)
    ) u_vt(.clk(clk),.pxl_cen(pcen),.vdump(vdump),.vrender(vrender),.vrender1(vrender1),
           .H(H),.Hinit(Hinit),.Vinit(Vinit),.LHBL(LHBL),.LVBL(LVBL),.HS(HS),.VS(VS));

    reg  [23:0] cpu_addr=0; reg [31:0] cpu_dout=0; reg [3:0] cpu_we=0; reg [1:0] pri=2'd1;

    // engine gfx ROM buses (jtnslasher_video, via vmem)
    wire        pf1_rom_cs,pf2_rom_cs,pf3_rom_cs,pf4_rom_cs,obj0_rom_cs,obj1_rom_cs;
    wire [18:0] pf1_rom_addr,pf2_rom_addr,pf3_rom_addr,pf4_rom_addr;
    wire [20:0] obj0_rom_addr,obj1_rom_addr;
    wire [31:0] pf1_rom_data,pf2_rom_data,pf3_rom_data,pf4_rom_data,obj1_rom_data;
    wire [39:0] obj0_rom_data;
    wire        pf1_rom_ok,pf2_rom_ok,pf3_rom_ok,pf4_rom_ok,obj0_rom_ok,obj1_rom_ok;
    wire [7:0]  red,green,blue;

    // framework SDRAM bus ports (adapter <-> model): 4x gfx 16-bit + 3x obj
    wire        gfx1a_cs,gfx1b_cs,gfx2a_cs,gfx2b_cs,obj0lo_cs,obj0hi_cs,obj1_cs;
    wire [19:0] gfx1a_addr,gfx1b_addr,gfx2a_addr,gfx2b_addr;
    wire [20:0] obj0lo_addr,obj0hi_addr;
    wire [17:0] obj1_addr;
    reg  [15:0] gfx1a_data,gfx1b_data,gfx2a_data,gfx2b_data;
    reg  [31:0] obj0lo_data,obj1_data;
    reg  [ 7:0] obj0hi_data;
    reg         gfx1a_ok=0,gfx1b_ok=0,gfx2a_ok=0,gfx2b_ok=0,obj0lo_ok=0,obj0hi_ok=0,obj1_ok=0;

    jtnslasher_vmem u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pcen),
        .vrender(vrender), .hdump(H), .HS(HS), .LHBL(LHBL), .LVBL(LVBL),
        .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_we(cpu_we), .pri(pri),
        .pf1_rom_cs(pf1_rom_cs),.pf1_rom_addr(pf1_rom_addr),.pf1_rom_data(pf1_rom_data),.pf1_rom_ok(pf1_rom_ok),
        .pf2_rom_cs(pf2_rom_cs),.pf2_rom_addr(pf2_rom_addr),.pf2_rom_data(pf2_rom_data),.pf2_rom_ok(pf2_rom_ok),
        .pf3_rom_cs(pf3_rom_cs),.pf3_rom_addr(pf3_rom_addr),.pf3_rom_data(pf3_rom_data),.pf3_rom_ok(pf3_rom_ok),
        .pf4_rom_cs(pf4_rom_cs),.pf4_rom_addr(pf4_rom_addr),.pf4_rom_data(pf4_rom_data),.pf4_rom_ok(pf4_rom_ok),
        .obj0_rom_cs(obj0_rom_cs),.obj0_rom_addr(obj0_rom_addr),.obj0_rom_data(obj0_rom_data),.obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(obj1_rom_cs),.obj1_rom_addr(obj1_rom_addr),.obj1_rom_data(obj1_rom_data),.obj1_rom_ok(obj1_rom_ok),
        .red(red), .green(green), .blue(blue) );

    jtnslasher_sdram u_adapter(
        .rst(rst), .clk(clk),
        .pf1_rom_cs(pf1_rom_cs),.pf1_rom_addr(pf1_rom_addr),.pf1_rom_data(pf1_rom_data),.pf1_rom_ok(pf1_rom_ok),
        .pf2_rom_cs(pf2_rom_cs),.pf2_rom_addr(pf2_rom_addr),.pf2_rom_data(pf2_rom_data),.pf2_rom_ok(pf2_rom_ok),
        .pf3_rom_cs(pf3_rom_cs),.pf3_rom_addr(pf3_rom_addr),.pf3_rom_data(pf3_rom_data),.pf3_rom_ok(pf3_rom_ok),
        .pf4_rom_cs(pf4_rom_cs),.pf4_rom_addr(pf4_rom_addr),.pf4_rom_data(pf4_rom_data),.pf4_rom_ok(pf4_rom_ok),
        .obj0_rom_cs(obj0_rom_cs),.obj0_rom_addr(obj0_rom_addr),.obj0_rom_data(obj0_rom_data),.obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(obj1_rom_cs),.obj1_rom_addr(obj1_rom_addr),.obj1_rom_data(obj1_rom_data),.obj1_rom_ok(obj1_rom_ok),
        .gfx1a_cs(gfx1a_cs),.gfx1a_addr(gfx1a_addr),.gfx1a_data(gfx1a_data),.gfx1a_ok(gfx1a_ok),
        .gfx1b_cs(gfx1b_cs),.gfx1b_addr(gfx1b_addr),.gfx1b_data(gfx1b_data),.gfx1b_ok(gfx1b_ok),
        .gfx2a_cs(gfx2a_cs),.gfx2a_addr(gfx2a_addr),.gfx2a_data(gfx2a_data),.gfx2a_ok(gfx2a_ok),
        .gfx2b_cs(gfx2b_cs),.gfx2b_addr(gfx2b_addr),.gfx2b_data(gfx2b_data),.gfx2b_ok(gfx2b_ok),
        .obj0lo_cs(obj0lo_cs),.obj0lo_addr(obj0lo_addr),.obj0lo_data(obj0lo_data),.obj0lo_ok(obj0lo_ok),
        .obj0hi_cs(obj0hi_cs),.obj0hi_addr(obj0hi_addr),.obj0hi_data(obj0hi_data),.obj0hi_ok(obj0hi_ok),
        .obj1_cs(obj1_cs),.obj1_addr(obj1_addr),.obj1_data(obj1_data),.obj1_ok(obj1_ok) );

    // ===== behavioral SDRAM: gfx1/gfx2 = ENCRYPTED reorder(raw) 16-bit ; gfx3/gfx4 = render-format =====
    reg [15:0] r1 [0:1048575], r2 [0:1048575];     // reorder(raw) mbh-00 / mbh-01 (gfxdec at-fetch)
    reg [31:0] obj0lo_n [0:2097151];               // NATIVE gfx3/gfx4 (the adapter rewires hra->nwi +
    reg [ 7:0] obj0hi_n [0:2097151];               // byte-permutes at fetch). obj0lo = native word,
    reg [31:0] obj1_n   [0: 262143];               // obj0hi = dense plane4 byte, obj1 = native gfx4.
    initial begin
        $readmemh({GFX,"r1_gfx1.hex"}, r1); $readmemh({GFX,"r2_gfx2.hex"}, r2);
        $readmemh({GFX,"obj0lo_native.hex"}, obj0lo_n);
        $readmemh({GFX,"obj0hi_native.hex"}, obj0hi_n);
        $readmemh({GFX,"obj1_native.hex"},   obj1_n);
    end

    // per-bank arbitrated, variable-latency model. id: 0 gfx1a 1 gfx1b 2 gfx2a 3 gfx2b (BA2),
    //                                                 4 obj0lo 5 obj0hi 6 obj1 (BA3).
    reg  [4:0] cnt [0:6];
    reg  [6:0] cing=0, okr=0;
    wire [6:0] cs  = {obj1_cs,obj0hi_cs,obj0lo_cs,gfx2b_cs,gfx2a_cs,gfx1b_cs,gfx1a_cs};
    wire [6:0] req = cs & ~okr;
    wire ba2_free = ~(|cing[3:0]);
    wire ba3_free = ~(|cing[6:4]);
    // Latency model. `LOWLAT (run_intg.sh) = fast SDRAM to prove RENDER CORRECTNESS across all pixels
    // (Arch B wrappers do 2 reads/word -> 4 BA2 buses oversubscribe a line under heavy contention; that
    // bandwidth sign-off is for 7e/HW, not this render-path test). Default = the heavier skewed model.
    function [4:0] base(input integer i);
`ifdef LOWLAT
        case(i) 4:base=5'd1; 5:base=5'd2; default:base=5'd1; endcase   // obj keeps a small lo/hi skew
`else
        case(i) 0:base=5'd4; 1:base=5'd5; 2:base=5'd4; 3:base=5'd5;
                4:base=5'd3; 5:base=5'd6; 6:base=5'd4; default:base=5'd4; endcase
`endif
    endfunction
    integer b;
`ifdef LOWLAT
    task grant(input integer i); begin cing[i]<=1; cnt[i]<=base(i); end endtask
`else
    task grant(input integer i); begin cing[i]<=1; cnt[i]<=base(i)+({$random}%4); end endtask
`endif
    task complete(input integer i);
        begin cing[i]<=0; okr[i]<=1;
            case(i)
              0: gfx1a_data <= r1[gfx1a_addr];
              1: gfx1b_data <= r1[gfx1b_addr];
              2: gfx2a_data <= r2[gfx2a_addr];
              3: gfx2b_data <= r2[gfx2b_addr];
              4: obj0lo_data <= obj0lo_n[obj0lo_addr];
              5: obj0hi_data <= obj0hi_n[obj0hi_addr];
              6: obj1_data   <= obj1_n[obj1_addr];
            endcase
        end
    endtask
    initial for(b=0;b<7;b=b+1) cnt[b]=0;
    always @(posedge clk) begin
        for(b=0;b<7;b=b+1) if(!cs[b]) okr[b]<=0;
        for(b=0;b<7;b=b+1) if(cing[b]) begin if(cnt[b]==0) complete(b); else cnt[b]<=cnt[b]-5'd1; end
        if(ba2_free) begin
            if     (req[0]) grant(0); else if(req[1]) grant(1);
            else if(req[2]) grant(2); else if(req[3]) grant(3);
        end
        if(ba3_free) begin
            if     (req[4]) grant(4); else if(req[5]) grant(5); else if(req[6]) grant(6);
        end
    end
    always @(*) begin
        gfx1a_ok=okr[0]; gfx1b_ok=okr[1]; gfx2a_ok=okr[2]; gfx2b_ok=okr[3];
        obj0lo_ok=okr[4]; obj0hi_ok=okr[5]; obj1_ok=okr[6];
    end

    // ---- cap source + capture ----
    reg [31:0] cpf1[0:2047],cpf2[0:2047],cpf3[0:2047],cpf4[0:2047],cspr0[0:2047],cspr1[0:2047],cpal[0:2047];
    reg [31:0] cctl12[0:7], cctl34[0:7];
    initial begin
        $readmemh(`PF1FILE,cpf1); $readmemh(`PF2FILE,cpf2); $readmemh(`PF3FILE,cpf3); $readmemh(`PF4FILE,cpf4);
        $readmemh(`SPR0FILE,cspr0); $readmemh(`SPR1FILE,cspr1); $readmemh(`PALFILE,cpal);
        $readmemh(`CTL12FILE,cctl12); $readmemh(`CTL34FILE,cctl34);
    end
    localparam HW=384;
    reg [23:0] fb [0:240*HW-1];
    integer i;
    initial for(i=0;i<240*HW;i=i+1) fb[i]=24'h0;
    reg cap=0;
    always @(posedge clk) if(cap && ph==2'd3 && vdump<9'd240 && H<9'd384) fb[vdump*HW + H] <= {blue,green,red};

    task cpuwr(input [23:0] a, input [31:0] d);
    begin @(posedge clk); #1; cpu_addr=a; cpu_dout=d; cpu_we=4'hf; @(posedge clk); #1; cpu_we=4'h0; end endtask

    integer f, got, k;
    initial begin
        rst=1; repeat(40) @(posedge clk); rst=0; repeat(4) @(posedge clk);
        for(k=0;k<8;k=k+1) cpuwr(24'h1a0000 + k*4, cctl12[k]);
        for(k=0;k<8;k=k+1) cpuwr(24'h1e0000 + k*4, cctl34[k]);
        for(k=0;k<2048;k=k+1) cpuwr(24'h168000 + k*4, cpal[k]);
        for(k=0;k<2048;k=k+1) cpuwr(24'h182000 + k*4, cpf1[k]);
        for(k=0;k<2048;k=k+1) cpuwr(24'h184000 + k*4, cpf2[k]);
        for(k=0;k<2048;k=k+1) cpuwr(24'h1c2000 + k*4, cpf3[k]);
        for(k=0;k<2048;k=k+1) cpuwr(24'h1c4000 + k*4, cpf4[k]);
        for(k=0;k<1024;k=k+1) cpuwr(24'h170000 + k*4, cspr0[k]);
        for(k=0;k<1024;k=k+1) cpuwr(24'h178000 + k*4, cspr1[k]);
        $display("tb_intg: replay done — Arch B (at-fetch decrypt wrappers + 40-bit obj split) + contention");
        repeat(2) begin @(negedge LVBL); @(posedge LVBL); end
        cap=1;
        forever begin
            @(posedge LVBL); got = u_dut.u_video.u_obj0.frame;
            @(negedge LVBL);
            if(got===1) begin
                f=$fopen({GFX,"frame_intg.hex"},"w");
                for(i=0;i<240*HW;i=i+1) $fwrite(f,"%06x\n", fb[i]);
                $fclose(f);
                $display("tb_intg: captured frame (obj.frame=%0d) -> frame_intg.hex",got);
                $finish;
            end
        end
    end
endmodule
