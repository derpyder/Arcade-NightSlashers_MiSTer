`timescale 1ns/1ps
`include "obj_cfg_f3600.vh"
// Settled-render test of the IN-GAME frame f2700 through the REAL jtnslasher_obj engine.
// OAM is read DIRECTLY (no DMA, fully settled) so this isolates the multi-tile DECODE path.
// If frame_obj_f3600.hex == golden_obj_f2700.hex (0 diffs) -> decode is correct for tall in-game
// sprites and the in-game scramble must be a RUNTIME (DMA/tear) effect, not a decode bug.
module tb_obj_f3600;
    reg          clk=0, rst=1, pxl_cen=1;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1, LVBL=1;

    wire [ 9:0]  tbl_addr; reg [15:0] tbl_dout;
    wire         rom_cs;   wire [20:0] rom_addr; reg [8*`BPP-1:0] rom_data; reg rom_ok=0;
    wire [15:0]  pxl;

    always #5 clk=~clk;

    reg [31:0] sprtbl [0:2047];
    initial $readmemh(`SPRFILE, sprtbl);
    always @(posedge clk) tbl_dout <= sprtbl[tbl_addr][15:0];

    reg [8*`BPP-1:0] gfxrom [0:`MEMW-1];
    initial $readmemh(`GFXFILE, gfxrom);
    always @(posedge clk) begin rom_data <= gfxrom[rom_addr]; rom_ok <= rom_cs; end

    jtnslasher_obj #(.BPP(`BPP)) u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
        .vrender(vrender), .hdump(hdump),
        .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .pxl(pxl)
    );

    reg [15:0] fb [0:76799]; integer i;
    initial for(i=0;i<76800;i=i+1) fb[i]=16'h0;
    always @(posedge clk)
        if (u_dut.buf_we && u_dut.buf_wdata[7:0]!=8'h0 && u_dut.buf_waddr<9'd320 && vrender<9'd240)
            fb[vrender*320 + u_dut.buf_waddr] <= u_dut.buf_wdata;

    integer ln, cyc, f;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            for(cyc=0; cyc<6000; cyc=cyc+1) @(posedge clk);
        end
        f=$fopen("frame_obj_f3600.hex","w");
        for(i=0;i<76800;i=i+1) $fwrite(f,"%04x\n", fb[i]);
        $fclose(f);
        $display("tb_obj_f3600: 240 lines -> frame_obj_f3600.hex");
        $finish;
    end
endmodule
