`timescale 1ns/1ps
// M3 — full readout-path validation: jtframe_vtimer -> jtnslasher_video (tilemap + linebuf
// readout + colmix) -> RGB, scanned for real. Captures RGB at (vdump,hdump) over a primed
// frame and dumps it (screen order) for a bit-exact diff vs the golden (cmp_rgb.py).
module tb_video;
    localparam DIR = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";
    reg clk=0, rst=1;
    always #5 clk = ~clk;
    reg [1:0] cen=0;
    always @(posedge clk) cen <= cen+1'b1;
    wire pxl_cen = cen==2'd0;          // clk/4

    wire [8:0] vdump, vrender, vrender1, H;
    wire       Hinit, Vinit, LHBL, LVBL, HS, VS;
    jtframe_vtimer #(
        .V_START(9'd0), .VB_START(9'd240), .VB_END(9'd263), .VS_START(9'd245), .VS_END(9'd248), .VCNT_END(9'd263),
        .HB_END(9'd383), .HB_START(9'd320), .HS_START(9'd340), .HS_END(9'd367),
        .H_VB(9'd320), .H_VS(9'd340), .H_VNEXT(9'd340), .HINIT(9'd340),
        .HJUMP(1'd0), .HCNT_END(9'd383), .HCNT_START(9'd0)
    ) u_vt(.clk(clk),.pxl_cen(pxl_cen),.vdump(vdump),.vrender(vrender),.vrender1(vrender1),
           .H(H),.Hinit(Hinit),.Vinit(Vinit),.LHBL(LHBL),.LVBL(LVBL),.HS(HS),.VS(VS));

    reg [9:0] scrx=10'd256; reg [8:0] scry=9'd256;
    wire        ram_cs; wire [10:0] ram_addr; reg [15:0] ram_data; reg ram_ok=0;
    wire        rom_cs; wire [16:0] rom_addr; reg [31:0] rom_data; reg rom_ok=0;
    wire [7:0]  red, green, blue;

    reg [31:0] pf2 [0:2047];
    initial $readmemh({DIR,"vram_pf2.hex"}, pf2);
    always @(posedge clk) begin ram_data <= pf2[ram_addr][15:0]; ram_ok <= ram_cs; end
    reg [31:0] gfxrom [0:524287];
    initial $readmemh({DIR,"gfx1_tiles16.hex"}, gfxrom);
    always @(posedge clk) begin rom_data <= gfxrom[rom_addr]; rom_ok <= rom_cs; end

    jtnslasher_video u_dut(
        .rst(rst),.clk(clk),.pxl_cen(pxl_cen),
        .vrender(vrender),.hdump(H),.HS(HS),.LHBL(LHBL),
        .scrx(scrx),.scry(scry),
        .pal_we(1'b0),.pal_waddr(11'd0),.pal_din(24'd0),
        .ram_cs(ram_cs),.ram_addr(ram_addr),.ram_data(ram_data),.ram_ok(ram_ok),
        .rom_cs(rom_cs),.rom_addr(rom_addr),.rom_data(rom_data),.rom_ok(rom_ok),
        .red(red),.green(green),.blue(blue));

    // capture the scanned frame (account for the 1-pxl_cen colmix latency: RGB at H is pxl H-1)
    reg [23:0] fb [0:76799];
    integer i;
    initial for (i=0;i<76800;i=i+1) fb[i]=24'h0;
    always @(posedge clk) if (pxl_cen && LVBL && vdump<9'd240 && H>=9'd1 && H<=9'd320)
        fb[vdump*320 + (H-9'd1)] <= {red,green,blue};

    integer f, frame;
    initial begin
        $readmemh({DIR,"vram_pal.hex"}, u_dut.u_colmix.pal);   // preload palette (low 24 bits)
        rst=1; repeat(40) @(posedge clk); rst=0;
        // let several frames scan so the linebuf pipeline is primed, then dump the last one
        for (frame=0; frame<3; frame=frame+1) begin
            @(negedge LVBL); @(posedge LVBL);   // one full frame
        end
        @(negedge LVBL);                        // start of the frame we keep; capture runs during it
        @(posedge LVBL);
        f = $fopen({DIR,"frame_rgb.hex"},"w");
        for (i=0;i<76800;i=i+1) $fwrite(f,"%06x\n", fb[i]);
        $fclose(f);
        $display("scanned frame -> frame_rgb.hex");
        $finish;
    end
endmodule
