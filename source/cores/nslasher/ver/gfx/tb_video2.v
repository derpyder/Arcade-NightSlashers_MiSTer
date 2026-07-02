`timescale 1ns/1ps
`include "video_cfg.vh"
// M3 task #11 — full-frame video integration sim. jtframe_vtimer (320x240) -> jtnslasher_video
// (4x tilemap + 2x obj + colmix) -> RGB, scanned line-by-line through the real readout path with
// behavioral RAMs/ROMs (the f1800 caps + the 5 reshuffled gfx sets). A frame where the obj flash
// bit is set (frame==1, matching the golden which draws all sprites) is captured into a raw
// framebuffer indexed by (vdump, raw hdump); cmp_video.py sweeps the pipeline offset vs ref_render's
// cm_rgb.hex.  Phasing follows tb_colmix2: a clean clk/4 strobe (pcen high one clk, low the clk
// before); the colmix reads portA on the pcen clk, portB the next, RGB valid ~3 clk later.
module tb_video2;
    localparam DIR = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";
    reg clk=0, rst=1;
    always #5 clk = ~clk;

    // clean clk/4 pixel strobe (registered: pcen high during ph==0, low at ph==3 the clk before)
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

    // ---------------- DUT buses ----------------
    wire pf1_ram_cs,pf2_ram_cs,pf3_ram_cs,pf4_ram_cs;
    wire [10:0] pf1_ram_addr,pf2_ram_addr,pf3_ram_addr,pf4_ram_addr;
    reg  [15:0] pf1_ram_data,pf2_ram_data,pf3_ram_data,pf4_ram_data;
    reg  pf1_ram_ok=0,pf2_ram_ok=0,pf3_ram_ok=0,pf4_ram_ok=0;
    wire pf1_rom_cs,pf2_rom_cs,pf3_rom_cs,pf4_rom_cs;
    wire [18:0] pf1_rom_addr,pf2_rom_addr,pf3_rom_addr,pf4_rom_addr;
    reg  [31:0] pf1_rom_data,pf2_rom_data,pf3_rom_data,pf4_rom_data;
    reg  pf1_rom_ok=0,pf2_rom_ok=0,pf3_rom_ok=0,pf4_rom_ok=0;
    wire [9:0] obj0_tbl_addr,obj1_tbl_addr;
    reg  [15:0] obj0_tbl_dout,obj1_tbl_dout;
    wire obj0_rom_cs,obj1_rom_cs;
    wire [20:0] obj0_rom_addr,obj1_rom_addr;
    reg  [39:0] obj0_rom_data; reg [31:0] obj1_rom_data;
    reg  obj0_rom_ok=0,obj1_rom_ok=0;
    wire [7:0] red,green,blue;

    // ---------------- behavioral memories ----------------
    reg [31:0] pf1[0:2047], pf2[0:2047], pf3[0:2047], pf4[0:2047];
    reg [31:0] spr0[0:2047], spr1[0:2047];
    reg [31:0] g_c8 [0:524287];    // PF1 gfx1_chars8
    reg [31:0] g_t1 [0:524287];    // PF2 gfx1_tiles16
    reg [31:0] g_t2 [0:524287];    // PF3/PF4 gfx2_tiles16 (shared, two read ports)
    reg [39:0] g_o0 [0:`SPR0_MEMW-1];
    reg [31:0] g_o1 [0:`SPR1_MEMW-1];
    reg [31:0] pal[0:2047];
    initial begin
        $readmemh(`PF1FILE,pf1); $readmemh(`PF2FILE,pf2); $readmemh(`PF3FILE,pf3); $readmemh(`PF4FILE,pf4);
        $readmemh(`SPR0FILE,spr0); $readmemh(`SPR1FILE,spr1);
        $readmemh(`GFX1C8FILE,g_c8); $readmemh(`GFX1T16FILE,g_t1); $readmemh(`GFX2T16FILE,g_t2);
        $readmemh(`GFX3SPRFILE,g_o0); $readmemh(`GFX4SPRFILE,g_o1);
        $readmemh(`PALFILE,pal);
    end
    // PF data RAM (caps word = ffff_DDDD, low16 = tile|colour)
    always @(posedge clk) begin pf1_ram_data<=pf1[pf1_ram_addr][15:0]; pf1_ram_ok<=pf1_ram_cs; end
    always @(posedge clk) begin pf2_ram_data<=pf2[pf2_ram_addr][15:0]; pf2_ram_ok<=pf2_ram_cs; end
    always @(posedge clk) begin pf3_ram_data<=pf3[pf3_ram_addr][15:0]; pf3_ram_ok<=pf3_ram_cs; end
    always @(posedge clk) begin pf4_ram_data<=pf4[pf4_ram_addr][15:0]; pf4_ram_ok<=pf4_ram_cs; end
    // PF gfx ROM (reshuffled planar 32-bit words)
    always @(posedge clk) begin pf1_rom_data<=g_c8[pf1_rom_addr]; pf1_rom_ok<=pf1_rom_cs; end
    always @(posedge clk) begin pf2_rom_data<=g_t1[pf2_rom_addr]; pf2_rom_ok<=pf2_rom_cs; end
    always @(posedge clk) begin pf3_rom_data<=g_t2[pf3_rom_addr]; pf3_rom_ok<=pf3_rom_cs; end
    always @(posedge clk) begin pf4_rom_data<=g_t2[pf4_rom_addr]; pf4_rom_ok<=pf4_rom_cs; end
    // sprite tables (caps word = ffff_DDDD)
    always @(posedge clk) obj0_tbl_dout<=spr0[obj0_tbl_addr][15:0];
    always @(posedge clk) obj1_tbl_dout<=spr1[obj1_tbl_addr][15:0];
    // sprite gfx ROM (reshuffled planar, BPP bytes/half-row)
    always @(posedge clk) begin obj0_rom_data<=g_o0[obj0_rom_addr]; obj0_rom_ok<=obj0_rom_cs; end
    always @(posedge clk) begin obj1_rom_data<=g_o1[obj1_rom_addr]; obj1_rom_ok<=obj1_rom_cs; end

    jtnslasher_video u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pcen),
        .vrender(vrender), .hdump(H), .HS(HS), .LHBL(LHBL), .LVBL(LVBL),
        .pf1_scrx(`PF1_SCRX), .pf1_scry(`PF1_SCRY),
        .pf2_scrx(`PF2_SCRX), .pf2_scry(`PF2_SCRY),
        .pf3_scrx(`PF3_SCRX), .pf3_scry(`PF3_SCRY),
        .pf4_scrx(`PF4_SCRX), .pf4_scry(`PF4_SCRY),
        .pf2_bank(`PF2_BANK), .pf3_bank(`PF3_BANK), .pf4_bank(`PF4_BANK),
        .en1(`V_EN1), .en2(`V_EN2), .en3(`V_EN3), .en4(`V_EN4), .pri(`V_PRI),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_din(24'd0),
        .pf1_ram_cs(pf1_ram_cs),.pf1_ram_addr(pf1_ram_addr),.pf1_ram_data(pf1_ram_data),.pf1_ram_ok(pf1_ram_ok),
        .pf2_ram_cs(pf2_ram_cs),.pf2_ram_addr(pf2_ram_addr),.pf2_ram_data(pf2_ram_data),.pf2_ram_ok(pf2_ram_ok),
        .pf3_ram_cs(pf3_ram_cs),.pf3_ram_addr(pf3_ram_addr),.pf3_ram_data(pf3_ram_data),.pf3_ram_ok(pf3_ram_ok),
        .pf4_ram_cs(pf4_ram_cs),.pf4_ram_addr(pf4_ram_addr),.pf4_ram_data(pf4_ram_data),.pf4_ram_ok(pf4_ram_ok),
        .pf1_rom_cs(pf1_rom_cs),.pf1_rom_addr(pf1_rom_addr),.pf1_rom_data(pf1_rom_data),.pf1_rom_ok(pf1_rom_ok),
        .pf2_rom_cs(pf2_rom_cs),.pf2_rom_addr(pf2_rom_addr),.pf2_rom_data(pf2_rom_data),.pf2_rom_ok(pf2_rom_ok),
        .pf3_rom_cs(pf3_rom_cs),.pf3_rom_addr(pf3_rom_addr),.pf3_rom_data(pf3_rom_data),.pf3_rom_ok(pf3_rom_ok),
        .pf4_rom_cs(pf4_rom_cs),.pf4_rom_addr(pf4_rom_addr),.pf4_rom_data(pf4_rom_data),.pf4_rom_ok(pf4_rom_ok),
        .obj0_tbl_addr(obj0_tbl_addr),.obj0_tbl_dout(obj0_tbl_dout),
        .obj1_tbl_addr(obj1_tbl_addr),.obj1_tbl_dout(obj1_tbl_dout),
        .obj0_rom_cs(obj0_rom_cs),.obj0_rom_addr(obj0_rom_addr),.obj0_rom_data(obj0_rom_data),.obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(obj1_rom_cs),.obj1_rom_addr(obj1_rom_addr),.obj1_rom_data(obj1_rom_data),.obj1_rom_ok(obj1_rom_ok),
        .red(red), .green(green), .blue(blue) );

    // ---------------- capture (raw hdump-indexed; cmp_video.py sweeps the offset) ----------------
    localparam HW=384;
    reg [23:0] fb [0:240*HW-1];
    integer i;
    initial for(i=0;i<240*HW;i=i+1) fb[i]=24'h0;
    reg cap=0;
    always @(posedge clk) if(cap && ph==2'd3 && vdump<9'd240 && H<9'd384)
        fb[vdump*HW + H] <= {blue,green,red};

    integer f, got;
    initial begin
        // preload the palette directly (single RAM; jtframe_dual_ram NBA write quirk -> direct mem load)
        for(i=0;i<2048;i=i+1) u_dut.u_colmix.u_pal.u_ram.mem[i] = pal[i][23:0];
        rst=1; repeat(40) @(posedge clk); rst=0;
        // prime the per-line double buffers for two full frames
        repeat(2) begin @(negedge LVBL); @(posedge LVBL); end
        // capture a visible frame whose obj flash bit == 1 (golden draws all sprites incl. flash)
        cap=1;
        forever begin
            @(posedge LVBL);                 // start of a visible region
            got = u_dut.u_obj0.frame;        // flash phase governing this visible frame
            @(negedge LVBL);                 // end of visible -> fb holds this frame
            if(got===1) begin
                f=$fopen({DIR,"frame2_rgb.hex"},"w");
                for(i=0;i<240*HW;i=i+1) $fwrite(f,"%06x\n", fb[i]);
                $fclose(f);
                $display("tb_video2: captured frame (obj.frame=%0d) -> frame2_rgb.hex (%0dx%0d raw)",got,HW,240);
                $finish;
            end
        end
    end
endmodule
