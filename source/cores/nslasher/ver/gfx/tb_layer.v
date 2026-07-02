`timescale 1ns/1ps
`include "layer_cfg.vh"
// Generalized per-layer validation tb for jtnslasher_tilemap. gen_layer.py writes layer_cfg.vh
// (TILE8/BANK/SCRX/SCRY + PFFILE/GFXFILE for the captured MAME frame) and golden_pxl.hex.
// Renders 240 lines line-by-line via the scan/draw pipeline, snoops the line-buffer writes,
// dumps frame_pxl.hex -> cmp_frame.py diffs bit-exact vs golden_pxl.hex.
module tb_layer;
    reg          clk=0, rst=1, pxl_cen=1;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1;

    wire         ram_cs;  wire [10:0] ram_addr; reg [15:0] ram_data; reg ram_ok=0;
    wire         rom_cs;  wire [18:0] rom_addr; reg [31:0] rom_data; reg rom_ok=0;
    wire [ 7:0]  pxl;

    always #5 clk = ~clk;

    // PF data RAM (caps dump: each word = ffff_TTTT, low16 = tile|colour)
    reg [31:0] pf [0:2047];
    initial $readmemh(`PFFILE, pf);
    always @(posedge clk) begin ram_data <= pf[ram_addr][15:0]; ram_ok <= ram_cs; end

    // gfx ROM: reshuffled planar 32-bit words (up to 512K words)
    reg [31:0] gfxrom [0:524287];
    initial $readmemh(`GFXFILE, gfxrom);
    always @(posedge clk) begin rom_data <= gfxrom[rom_addr]; rom_ok <= rom_cs; end

    jtnslasher_tilemap u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .tile8(`TILE8), .bank(`BANK), .flip_en(2'b00),   // caps never enable flips (FIX C2 regression = identical)
        .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
        .scrx(`SCRX), .scry(`SCRY),
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
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            for (cyc=0; cyc<1100; cyc=cyc+1) @(posedge clk);   // fill the line (8x8 = 42 tiles)
        end
        f = $fopen("frame_pxl.hex","w");
        for (i=0;i<76800;i=i+1) $fwrite(f,"%02x\n", fb[i]);
        $fclose(f);
        $display("tb_layer: 240 lines -> frame_pxl.hex (tile8=%0d bank=%0d scrx=%0d scry=%0d)", `TILE8, `BANK, `SCRX, `SCRY);
        $finish;
    end
endmodule
