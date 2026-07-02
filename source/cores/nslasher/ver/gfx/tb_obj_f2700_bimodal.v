`timescale 1ns/1ps
`include "obj_cfg_f2700.vh"
// BIMODAL latency model: faithfully reproduces the FOLD's measured rom_cs->rom_ok cadence on real
// SDRAM, where the DW32-DOUBLE slot caches the partner half of each tile pair:
//   - the FIRST half fetched in a (code,row) pair = fresh burst  -> LAT_HI clks
//   - the SECOND (partner) half = cache hit in the just-burst DOUBLE word -> LAT_LO clks
// The obj engine emits halves as adjacent rom_addr differing in bit0; we treat bit0 as the
// hit/miss selector (matches the measured 2-clk vs 13-clk bimodal: ~half each).
// -DLAT_HI / -DLAT_LO. line budget as before.
`ifndef LAT_HI
 `define LAT_HI 13
`endif
`ifndef LAT_LO
 `define LAT_LO 2
`endif
`ifndef LINEBUDGET
 `define LINEBUDGET 3072
`endif
module tb_obj_f2700_bimodal;
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

    // bimodal: partner-half (bit0==1) = cache hit (LAT_LO); fresh half (bit0==0) = miss (LAT_HI)
    integer latctr;
    reg [31:0] this_lat;
    always @(posedge clk) begin
        if (!rom_cs)            begin rom_ok<=0; latctr<=0; end
        else if (!rom_ok) begin
            this_lat = rom_addr[0] ? `LAT_LO : `LAT_HI;
            if (latctr >= this_lat-1) begin rom_data <= gfxrom[rom_addr]; rom_ok<=1; end
            else                        latctr <= latctr + 1;
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

    integer ln, cyc, last_we_cyc, over_budget;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        over_budget=0;
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            last_we_cyc = 0;
            for(cyc=0; cyc<8000; cyc=cyc+1) begin
                @(posedge clk);
                if (u_dut.buf_we && u_dut.buf_wdata[7:0]!=8'h0 && u_dut.buf_waddr<9'd320)
                    last_we_cyc = cyc;
            end
            if (last_we_cyc > `LINEBUDGET) over_budget = over_budget + 1;
        end
        $display("BIMODAL LAT_HI=%0d LAT_LO=%0d budget=%0d -> %0d/240 lines do NOT finish drawing in budget",
                 `LAT_HI, `LAT_LO, `LINEBUDGET, over_budget);
        $finish;
    end
endmodule
