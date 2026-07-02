`timescale 1ns/1ps
// M3c — validate jtnslasher_tilemap: render PF2 (the captured Data East logo frame) and
// dump the per-pixel pxl={colour,pix} so it can be diffed bit-exact vs golden_pxl.hex.
// Feeds the behavioral PF data RAM (vram_pf2) + reshuffled planar gfx (gfx1_tiles16) and
// snoops the line-buffer writes (the scan/draw output) directly, line by line.
module tb_tilemap;
    localparam DIR = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";

    reg          clk=0, rst=1, pxl_cen=1;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1;
    reg  [ 9:0]  scrx=10'd256;
    reg  [ 8:0]  scry=9'd256;

    wire         ram_cs;  wire [10:0] ram_addr; reg [15:0] ram_data; reg ram_ok=0;
    wire         rom_cs;  wire [16:0] rom_addr; reg [31:0] rom_data; reg rom_ok=0;
    wire [ 7:0]  pxl;

    always #5 clk = ~clk;

    // PF data RAM: low 16 bits of each captured 32-bit word
    reg [31:0] pf2 [0:2047];
    initial $readmemh({DIR,"vram_pf2.hex"}, pf2);
    always @(posedge clk) begin ram_data <= pf2[ram_addr][15:0]; ram_ok <= ram_cs; end

    // gfx ROM: reshuffled planar 32-bit words
    reg [31:0] gfxrom [0:524287];
    initial $readmemh({DIR,"gfx1_tiles16.hex"}, gfxrom);
    always @(posedge clk) begin rom_data <= gfxrom[rom_addr]; rom_ok <= rom_cs; end

    jtnslasher_tilemap u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .flip_en(2'b00),
        .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
        .scrx(scrx), .scry(scry),
        .ram_cs(ram_cs), .ram_addr(ram_addr), .ram_data(ram_data), .ram_ok(ram_ok),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .pxl(pxl)
    );

    // capture the scan/draw output (line-buffer writes) for the visible 320 px of each line
    reg [7:0] fb [0:76799];
    integer i;
    initial for (i=0;i<76800;i=i+1) fb[i]=8'h00;
    always @(posedge clk)
        if (u_dut.buf_we && u_dut.buf_waddr < 9'd320 && vrender < 9'd240)
            fb[vrender*320 + u_dut.buf_waddr] <= u_dut.buf_wdata;

    integer ln, cyc, f;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        for (ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;          // HS rising
            @(posedge clk) HS=0;          // HS falling -> triggers the line scan
            for (cyc=0; cyc<900; cyc=cyc+1) @(posedge clk);   // let scan+draw fill the line
        end
        f = $fopen({DIR,"frame_pxl.hex"},"w");
        for (i=0;i<76800;i=i+1) $fwrite(f,"%02x\n", fb[i]);
        $fclose(f);
        $display("rendered 240 lines -> frame_pxl.hex");
        $finish;
    end
endmodule
