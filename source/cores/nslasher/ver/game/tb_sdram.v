`timescale 1ns/1ps
`include "video_cfg.vh"
// M3k / task #7c-2 — gfx SDRAM SERVING sim. Same f1800 cap replay as tb_vmem, but the 6 render-engine
// gfx ROM buses are routed through jtnslasher_sdram (the fetch adapter: PF3/PF4 share gfx2, obj0 5bpp
// = 40-bit split obj0lo[31:0]+obj0hi[7:0] recombined) into a behavioral SDRAM model with PER-BANK
// arbitration + VARIABLE latency + a deliberate obj0lo/obj0hi latency SKEW. This proves the engines
// tolerate realistic multi-cycle rom_ok AND the 40-bit recombine is coherent under bank contention
// (vs the immediate-ok ROMs of tb_vmem). Judged bit-exact vs ref_render (cmp_video.py), same as 7b.
module tb_sdram;
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

    // ---- CPU video bus (driven by the replay) ----
    reg  [23:0] cpu_addr=0; reg [31:0] cpu_dout=0; reg [3:0] cpu_we=0; reg [1:0] pri=2'd1;

    // ---- engine gfx ROM buses (jtnslasher_video, via vmem) ----
    wire        pf1_rom_cs,pf2_rom_cs,pf3_rom_cs,pf4_rom_cs,obj0_rom_cs,obj1_rom_cs;
    wire [18:0] pf1_rom_addr,pf2_rom_addr,pf3_rom_addr,pf4_rom_addr;
    wire [20:0] obj0_rom_addr,obj1_rom_addr;
    wire [31:0] pf1_rom_data,pf2_rom_data,pf3_rom_data,pf4_rom_data,obj1_rom_data;
    wire [39:0] obj0_rom_data;
    wire        pf1_rom_ok,pf2_rom_ok,pf3_rom_ok,pf4_rom_ok,obj0_rom_ok,obj1_rom_ok;
    wire [7:0]  red,green,blue;

    // ---- framework SDRAM bus ports (adapter <-> model) ----
    wire        gfx1c_cs,gfx1t_cs,gfx2a_cs,gfx2b_cs,obj0lo_cs,obj0hi_cs,obj1_cs;
    wire [18:0] gfx1c_addr,gfx1t_addr,gfx2a_addr,gfx2b_addr;
    wire [20:0] obj0lo_addr,obj0hi_addr;
    wire [17:0] obj1_addr;
    reg  [31:0] gfx1c_data,gfx1t_data,gfx2a_data,gfx2b_data,obj0lo_data,obj1_data;
    reg  [ 7:0] obj0hi_data;
    reg         gfx1c_ok=0,gfx1t_ok=0,gfx2a_ok=0,gfx2b_ok=0,obj0lo_ok=0,obj0hi_ok=0,obj1_ok=0;

    // ================= DUT: video memory subsystem + the 7c fetch adapter =================
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
        .pf1_rom_cs(pf1_rom_cs),.pf1_rom_addr(pf1_rom_addr),.pf1_rom_data(pf1_rom_data),.pf1_rom_ok(pf1_rom_ok),
        .pf2_rom_cs(pf2_rom_cs),.pf2_rom_addr(pf2_rom_addr),.pf2_rom_data(pf2_rom_data),.pf2_rom_ok(pf2_rom_ok),
        .pf3_rom_cs(pf3_rom_cs),.pf3_rom_addr(pf3_rom_addr),.pf3_rom_data(pf3_rom_data),.pf3_rom_ok(pf3_rom_ok),
        .pf4_rom_cs(pf4_rom_cs),.pf4_rom_addr(pf4_rom_addr),.pf4_rom_data(pf4_rom_data),.pf4_rom_ok(pf4_rom_ok),
        .obj0_rom_cs(obj0_rom_cs),.obj0_rom_addr(obj0_rom_addr),.obj0_rom_data(obj0_rom_data),.obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(obj1_rom_cs),.obj1_rom_addr(obj1_rom_addr),.obj1_rom_data(obj1_rom_data),.obj1_rom_ok(obj1_rom_ok),
        .gfx1c_cs(gfx1c_cs),.gfx1c_addr(gfx1c_addr),.gfx1c_data(gfx1c_data),.gfx1c_ok(gfx1c_ok),
        .gfx1t_cs(gfx1t_cs),.gfx1t_addr(gfx1t_addr),.gfx1t_data(gfx1t_data),.gfx1t_ok(gfx1t_ok),
        .gfx2a_cs(gfx2a_cs),.gfx2a_addr(gfx2a_addr),.gfx2a_data(gfx2a_data),.gfx2a_ok(gfx2a_ok),
        .gfx2b_cs(gfx2b_cs),.gfx2b_addr(gfx2b_addr),.gfx2b_data(gfx2b_data),.gfx2b_ok(gfx2b_ok),
        .obj0lo_cs(obj0lo_cs),.obj0lo_addr(obj0lo_addr),.obj0lo_data(obj0lo_data),.obj0lo_ok(obj0lo_ok),
        .obj0hi_cs(obj0hi_cs),.obj0hi_addr(obj0hi_addr),.obj0hi_data(obj0hi_data),.obj0hi_ok(obj0hi_ok),
        .obj1_cs(obj1_cs),.obj1_addr(obj1_addr),.obj1_data(obj1_data),.obj1_ok(obj1_ok) );

    // ================= behavioral SDRAM: gfx contents = the reshuffled sets =================
    reg [31:0] g_c8[0:524287], g_t1[0:524287], g_t2[0:524287];
    reg [39:0] g_o0[0:`SPR0_MEMW-1];               // obj0: lo=[31:0] (obj0lo), hi=[39:32] (obj0hi)
    reg [31:0] g_o1[0:`SPR1_MEMW-1];
    initial begin
        $readmemh(`GFX1C8FILE,g_c8); $readmemh(`GFX1T16FILE,g_t1); $readmemh(`GFX2T16FILE,g_t2);
        $readmemh(`GFX3SPRFILE,g_o0); $readmemh(`GFX4SPRFILE,g_o1);
    end

    // --- per-bank arbitrated, variable-latency model. bus id: 0 gfx1c 1 gfx1t 2 gfx2a 3 gfx2b (BA2),
    //     4 obj0lo 5 obj0hi 6 obj1 (BA3). One bus served per bank at a time -> realistic contention.
    //     base latency skews obj0lo(3) vs obj0hi(6) to stress the recombine. +jitter per grant.
    reg  [4:0] cnt [0:6];       // latency countdown while counting
    reg  [6:0] cing=0;          // counting (occupies its bank)
    reg  [6:0] okr =0;          // latched ok
    wire [6:0] cs  = {obj1_cs,obj0hi_cs,obj0lo_cs,gfx2b_cs,gfx2a_cs,gfx1t_cs,gfx1c_cs};
    wire [6:0] req = cs & ~okr;
    wire ba2_free = ~(|cing[3:0]);
    wire ba3_free = ~(|cing[6:4]);

    function [4:0] base(input integer i);
        case(i) 0:base=5'd4; 1:base=5'd4; 2:base=5'd5; 3:base=5'd5;
                4:base=5'd3; 5:base=5'd6; 6:base=5'd4; default:base=5'd4; endcase
    endfunction
    integer b;
    task grant(input integer i);     // begin a latency for bus i (+0..3 jitter)
        begin cing[i]<=1; cnt[i]<=base(i) + ({$random}%4); end
    endtask
    task complete(input integer i);  // latch data + assert ok (frees the bank)
        begin cing[i]<=0; okr[i]<=1;
            case(i)
              0: gfx1c_data <= g_c8[gfx1c_addr];
              1: gfx1t_data <= g_t1[gfx1t_addr];
              2: gfx2a_data <= g_t2[gfx2a_addr];
              3: gfx2b_data <= g_t2[gfx2b_addr];
              4: obj0lo_data <= g_o0[obj0lo_addr][31:0];
              5: obj0hi_data <= g_o0[obj0hi_addr][39:32];
              6: obj1_data   <= g_o1[obj1_addr];
            endcase
        end
    endtask

    initial for(b=0;b<7;b=b+1) cnt[b]=0;
    always @(posedge clk) begin
        // release ok when the master drops cs
        for(b=0;b<7;b=b+1) if(!cs[b]) okr[b]<=0;
        // advance any counting bus; complete at 0
        for(b=0;b<7;b=b+1) if(cing[b]) begin
            if(cnt[b]==0) complete(b); else cnt[b]<=cnt[b]-5'd1;
        end
        // arbitrate each bank: grant the lowest-index requester when the bank is free
        if(ba2_free) begin
            if     (req[0]) grant(0); else if(req[1]) grant(1);
            else if(req[2]) grant(2); else if(req[3]) grant(3);
        end
        if(ba3_free) begin
            if     (req[4]) grant(4); else if(req[5]) grant(5); else if(req[6]) grant(6);
        end
    end
    always @(*) begin
        gfx1c_ok=okr[0]; gfx1t_ok=okr[1]; gfx2a_ok=okr[2]; gfx2b_ok=okr[3];
        obj0lo_ok=okr[4]; obj0hi_ok=okr[5]; obj1_ok=okr[6];
    end

    // ---- cap source ----
    reg [31:0] cpf1[0:2047],cpf2[0:2047],cpf3[0:2047],cpf4[0:2047],cspr0[0:2047],cspr1[0:2047],cpal[0:2047];
    reg [31:0] cctl12[0:7], cctl34[0:7];
    initial begin
        $readmemh(`PF1FILE,cpf1); $readmemh(`PF2FILE,cpf2); $readmemh(`PF3FILE,cpf3); $readmemh(`PF4FILE,cpf4);
        $readmemh(`SPR0FILE,cspr0); $readmemh(`SPR1FILE,cspr1); $readmemh(`PALFILE,cpal);
        $readmemh(`CTL12FILE,cctl12); $readmemh(`CTL34FILE,cctl34);
    end

    // ---- capture (raw hdump-indexed; cmp_video.py sweeps the offset) ----
    localparam HW=384;
    reg [23:0] fb [0:240*HW-1];
    integer i;
    initial for(i=0;i<240*HW;i=i+1) fb[i]=24'h0;
    reg cap=0;
    always @(posedge clk) if(cap && ph==2'd3 && vdump<9'd240 && H<9'd384)
        fb[vdump*HW + H] <= {blue,green,red};

    task cpuwr(input [23:0] a, input [31:0] d);
    begin
        @(posedge clk); #1; cpu_addr=a; cpu_dout=d; cpu_we=4'hf;
        @(posedge clk); #1; cpu_we=4'h0;
    end endtask

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
        $display("tb_sdram: replay done — priming + capturing through jtnslasher_sdram + contention model");
        repeat(2) begin @(negedge LVBL); @(posedge LVBL); end
        cap=1;
        forever begin
            @(posedge LVBL); got = u_dut.u_video.u_obj0.frame;
            @(negedge LVBL);
            if(got===1) begin
                f=$fopen({GFX,"frame_sdram.hex"},"w");
                for(i=0;i<240*HW;i=i+1) $fwrite(f,"%06x\n", fb[i]);
                $fclose(f);
                $display("tb_sdram: captured frame (obj.frame=%0d) -> frame_sdram.hex",got);
                $finish;
            end
        end
    end
endmodule
