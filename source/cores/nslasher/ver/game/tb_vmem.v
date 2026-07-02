`timescale 1ns/1ps
`include "video_cfg.vh"
// M3k / task #7b — deco32 video memory subsystem sim. Replays the f1800 caps through the CPU
// video-write bus (cpu_addr/cpu_dout/cpu_we, as jtnslasher_main surfaces them) into jtnslasher_vmem
// — palette / spriteram / PF-data / ctl — then scans a full frame through jtnslasher_video and diffs
// vs ref_render's cm_rgb.hex (cmp_video.py). This exercises the CPU write decode + the on-chip video
// RAMs + the ctl->scroll/bank/en decode, all the way to RGB.  gfx ROMs are behavioral (the 5
// reshuffled sets), as in tb_video2.  Phasing follows tb_video2 (clean clk/4 strobe, capture ph==3).
module tb_vmem;
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

    // ---- gfx ROM buses (behavioral, as in tb_video2) ----
    wire pf1_rom_cs,pf2_rom_cs,pf3_rom_cs,pf4_rom_cs;
    wire [18:0] pf1_rom_addr,pf2_rom_addr,pf3_rom_addr,pf4_rom_addr;
    reg  [31:0] pf1_rom_data,pf2_rom_data,pf3_rom_data,pf4_rom_data;
    reg  pf1_rom_ok=0,pf2_rom_ok=0,pf3_rom_ok=0,pf4_rom_ok=0;
    wire obj0_rom_cs,obj1_rom_cs;
    wire [20:0] obj0_rom_addr,obj1_rom_addr;
    reg  [39:0] obj0_rom_data; reg [31:0] obj1_rom_data;
    reg  obj0_rom_ok=0,obj1_rom_ok=0;
    wire [7:0] red,green,blue;

    reg [31:0] g_c8[0:524287], g_t1[0:524287], g_t2[0:524287];
    reg [39:0] g_o0[0:`SPR0_MEMW-1];
    reg [31:0] g_o1[0:`SPR1_MEMW-1];
    initial begin
        $readmemh(`GFX1C8FILE,g_c8); $readmemh(`GFX1T16FILE,g_t1); $readmemh(`GFX2T16FILE,g_t2);
        $readmemh(`GFX3SPRFILE,g_o0); $readmemh(`GFX4SPRFILE,g_o1);
    end
    always @(posedge clk) begin pf1_rom_data<=g_c8[pf1_rom_addr]; pf1_rom_ok<=pf1_rom_cs; end
    always @(posedge clk) begin pf2_rom_data<=g_t1[pf2_rom_addr]; pf2_rom_ok<=pf2_rom_cs; end
    always @(posedge clk) begin pf3_rom_data<=g_t2[pf3_rom_addr]; pf3_rom_ok<=pf3_rom_cs; end
    always @(posedge clk) begin pf4_rom_data<=g_t2[pf4_rom_addr]; pf4_rom_ok<=pf4_rom_cs; end
    always @(posedge clk) begin obj0_rom_data<=g_o0[obj0_rom_addr]; obj0_rom_ok<=obj0_rom_cs; end
    always @(posedge clk) begin obj1_rom_data<=g_o1[obj1_rom_addr]; obj1_rom_ok<=obj1_rom_cs; end

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

    // robust CPU write: hold addr/data/we stable across the DUT's sampling edge (avoids the iverilog
    // tight-loop NBA write-drop quirk noted in M3i). One committed write per call.
    task cpuwr(input [23:0] a, input [31:0] d);
    begin
        @(posedge clk); #1; cpu_addr=a; cpu_dout=d; cpu_we=4'hf;
        @(posedge clk); #1; cpu_we=4'h0;
    end endtask

    integer f, got, k;
    initial begin
        rst=1; repeat(40) @(posedge clk); rst=0; repeat(4) @(posedge clk);
        // ---- replay the captured frame into the video RAMs via the CPU bus ----
        for(k=0;k<8;k=k+1) cpuwr(24'h1a0000 + k*4, cctl12[k]);     // PF12 control
        for(k=0;k<8;k=k+1) cpuwr(24'h1e0000 + k*4, cctl34[k]);     // PF34 control
        for(k=0;k<2048;k=k+1) cpuwr(24'h168000 + k*4, cpal[k]);    // palette
        for(k=0;k<2048;k=k+1) cpuwr(24'h182000 + k*4, cpf1[k]);    // PF1 data
        for(k=0;k<2048;k=k+1) cpuwr(24'h184000 + k*4, cpf2[k]);    // PF2
        for(k=0;k<2048;k=k+1) cpuwr(24'h1c2000 + k*4, cpf3[k]);    // PF3
        for(k=0;k<2048;k=k+1) cpuwr(24'h1c4000 + k*4, cpf4[k]);    // PF4
        for(k=0;k<1024;k=k+1) cpuwr(24'h170000 + k*4, cspr0[k]);   // spriteram (obj0 table)
        for(k=0;k<1024;k=k+1) cpuwr(24'h178000 + k*4, cspr1[k]);   // spriteram2 (obj1 table)
        $display("tb_vmem: replay done (%0d writes) — priming + capturing", 16+7168+2048);
        // prime two full frames so the per-line double buffers are valid, then capture a frame==1 frame
        repeat(2) begin @(negedge LVBL); @(posedge LVBL); end
        cap=1;
        forever begin
            @(posedge LVBL); got = u_dut.u_video.u_obj0.frame;
            @(negedge LVBL);
            if(got===1) begin
                f=$fopen({GFX,"frame_vmem.hex"},"w");
                for(i=0;i<240*HW;i=i+1) $fwrite(f,"%06x\n", fb[i]);
                $fclose(f);
                $display("tb_vmem: captured frame (obj.frame=%0d) -> frame_vmem.hex",got);
                $finish;
            end
        end
    end
endmodule
