`timescale 1ns/1ps
`include "obj_cfg_maxload.vh"
// SYNTHETIC WORST-CASE line-load harness (the full-screen fire-effect comb, handoff §9.5).
// Renders the gen_maxload.py sprite table (120/127/140 sprites per line bands) through the REAL
// obj engine with a parameterized fetch latency, and measures per line:
//   - the cycle (since HS) of the last pixel write  -> over-budget lines at `LINEBUDGET
//   - the max parser line_cnt                        -> 127-cap engagements (lost frontmost sprites)
// LAT via -DLAT=n, budget via -DLINEBUDGET=n (3072 = 1-line lead today; 6144 = a 2-line-lead engine).
`ifndef LAT
 `define LAT 1
`endif
`ifndef LINEBUDGET
 `define LINEBUDGET 3072
`endif
module tb_obj_maxload;
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

    integer ln, cyc, last_we_cyc, over_budget, worst_cyc, worst_ln;
    integer lc_max, cap_lines, spr_max;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        over_budget=0; worst_cyc=0; worst_ln=-1; cap_lines=0; spr_max=0;
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            last_we_cyc = 0; lc_max = 0;
            for(cyc=0; cyc<16000; cyc=cyc+1) begin
                @(posedge clk);
                if (u_dut.buf_we && u_dut.buf_wdata[7:0]!=8'h0 && u_dut.buf_waddr<9'd320)
                    last_we_cyc = cyc;
                if (u_dut.line_cnt > lc_max) lc_max = u_dut.line_cnt;
            end
            if (lc_max > spr_max) spr_max = lc_max;
            if (lc_max >= 127) cap_lines = cap_lines + 1;
            if (last_we_cyc > `LINEBUDGET) begin
                over_budget = over_budget + 1;
                if (last_we_cyc > worst_cyc) begin worst_cyc = last_we_cyc; worst_ln = ln; end
            end
        end
        $display("LAT=%0d budget=%0d : %0d/240 lines OVER (worst %0d clk @line %0d, need x%0d.%02d), cap(127) hit on %0d lines, max sprites/line=%0d",
                 `LAT, `LINEBUDGET, over_budget, worst_cyc, worst_ln,
                 worst_cyc/`LINEBUDGET, (worst_cyc%`LINEBUDGET)*100/`LINEBUDGET, cap_lines, spr_max);
        $finish;
    end
endmodule
