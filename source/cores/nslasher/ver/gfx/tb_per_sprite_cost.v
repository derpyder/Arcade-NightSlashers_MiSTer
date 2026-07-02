`timescale 1ns/1ps
`include "obj_cfg_f2700.vh"
// Measure the EXACT per-sprite draw cost (in clk) of jtnslasher_obj.v at a given rom fetch
// latency LAT, by driving a sprite table with N identical single-tile sprites that all land
// on ONE scanline, then timing how long the engine takes to finish drawing that line.
// per-sprite slope = (finish_cyc(N) - finish_cyc(1)) / (N-1). Then project the worst real
// in-game line (70 sprites, per jtnslasher_obj.v comment) and the 127-cap special-move line.
`ifndef LAT
 `define LAT 1
`endif
module tb_per_sprite_cost;
    reg          clk=0, rst=1, pxl_cen=1;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1, LVBL=1;
    wire [ 9:0]  tbl_addr; reg [15:0] tbl_dout;
    wire         rom_cs;   wire [20:0] rom_addr; reg [8*`BPP-1:0] rom_data; reg rom_ok=0;
    wire [15:0]  pxl;
    always #5 clk=~clk;

    // synthetic sprite table: NSPR sprites, all y=vrender(test), single tile, code real.
    // word0 = y/flip/size : we set y so the sprite's vertical zone includes the test line.
    // The engine's inzone uses veff = vrender - y (single tile -> veff[6:4]==0). So set y==test line.
    integer NSPR;
    reg [15:0] tbl [0:2047];
    integer ti;
    initial begin
        NSPR = `NSPR;
        for(ti=0; ti<2048; ti=ti+1) tbl[ti]=16'h0000;   // word0 y=0 default -> harmless
        // build NSPR sprites at table slots 0..NSPR-1 (4 words each)
        for(ti=0; ti<NSPR; ti=ti+1) begin
            tbl[ti*4+0] = 16'd0  | (9'd100);     // word0: y=100, no flip/size bits
            tbl[ti*4+1] = 16'h4acb;              // word1: code (real tile)
            tbl[ti*4+2] = (ti*5) % 320;          // word2: x spread
            tbl[ti*4+3] = 16'h0000;              // word3
        end
        // terminate: leave the rest at y=0 (drawn off the test line)
    end
    always @(posedge clk) tbl_dout <= tbl[tbl_addr];

    reg [8*`BPP-1:0] gfxrom [0:65535];
    initial for(ti=0;ti<65536;ti=ti+1) gfxrom[ti]={ (`BPP){8'hA5} };

    integer latctr;
    always @(posedge clk) begin
        if (!rom_cs)            begin rom_ok<=0; latctr<=0; end
        else if (!rom_ok) begin
            if (latctr >= `LAT-1) begin rom_data <= gfxrom[rom_addr[15:0]]; rom_ok<=1; end
            else                   latctr <= latctr + 1;
        end
    end

    jtnslasher_obj #(.BPP(`BPP)) u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
        .vrender(vrender), .hdump(hdump),
        .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .pxl(pxl)
    );

    integer cyc, last_we_cyc, last_lc;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        vrender = 9'd100;                         // test the line where all sprites live
        @(posedge clk) HS=1;
        @(posedge clk) HS=0;
        last_we_cyc=0;
        for(cyc=0; cyc<60000; cyc=cyc+1) begin
            @(posedge clk);
            if (u_dut.buf_we) last_we_cyc = cyc;
        end
        last_lc = u_dut.line_cnt;
        $display("LAT=%0d NSPR=%0d -> line_cnt=%0d  last_pixel_write_cyc=%0d",
                 `LAT, NSPR, last_lc, last_we_cyc);
        $finish;
    end
endmodule
