`timescale 1ns/1ps
`include "obj_cfg_f2700.vh"
// BANDWIDTH test: render in-game frame f2700 through the REAL obj engine, but model the gfx fetch as
// taking `LAT clocks per engine-fetch (rom_cs -> rom_ok) instead of the ideal 1. For the NON-FOLD obj0
// the engine's single rom_cs fans out to obj0lo+obj0hi (both BA3, serialized) so its effective LAT is
// ~2x a single burst; the FOLD would be ~1x. We MEASURE, per line, the cycle (since HS) of the LAST
// pixel write, and count lines whose draw does not finish within the real ~3072-clk line budget.
// LAT passed via -DLAT=n. line_cnt cap is whatever is compiled into jtnslasher_obj.v (now 127).
`ifndef LAT
 `define LAT 1
`endif
`ifndef LINEBUDGET
 `define LINEBUDGET 3072
`endif
module tb_obj_f2700_lat;
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

    // ---- parameterized fetch latency: rom_ok asserts LAT clks after rom_cs rises, holds till cs drops ----
    integer latctr;
    always @(posedge clk) begin
        if (!rom_cs)            begin rom_ok<=0; latctr<=0; end
        else if (!rom_ok) begin
            if (latctr >= `LAT-1) begin rom_data <= gfxrom[rom_addr]; rom_ok<=1; end
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

    // per-line: cycles since HS-fall, and the cycle index of the last pixel write
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
                    last_we_cyc = cyc;   // last meaningful pixel drawn this line
            end
            if (last_we_cyc > `LINEBUDGET) begin
                over_budget = over_budget + 1;
                if (last_we_cyc > 0)
                    $display("  line %0d: last pixel at cyc %0d  (OVER %0d-budget by %0d)",
                             ln, last_we_cyc, `LINEBUDGET, last_we_cyc-`LINEBUDGET);
            end
        end
        $display("LAT=%0d  budget=%0d  -> %0d/240 lines do NOT finish drawing in budget",
                 `LAT, `LINEBUDGET, over_budget);
        $finish;
    end
endmodule
