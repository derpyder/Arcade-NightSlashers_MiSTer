`timescale 1ns/1ps
`include "obj_cfg_f2700.vh"
// BYTE-EXACT-UNDER-LATENCY gate for the PIPELINED draw FSM (comb fix stage-B): render in-game
// frame f2700 through the REAL engine with a `LAT-clock rom_cs->rom_ok fetch model (same injector
// as tb_obj_f2700_lat.v) and byte-compare against the MAME golden IN the testbench. The plain
// tb_obj_f2700.v renders at ideal 1-clk latency, which cannot exercise the pipeline's overlapped
// paths (fetch completing DURING a drain, prefetch across sprites, stale-ok guards after the
// 1-cycle cs drop) -- this one does. Lines get an 8000-cycle budget so even over-budget lines
// complete: this gate proves the BYTES are right at any latency; the budget/comb measurement
// stays in tb_obj_f2700_lat.v.
`ifndef LAT
 `define LAT 14
`endif
module tb_obj_f2700_latexact;
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

    // parameterized fetch latency: rom_ok asserts `LAT clks after rom_cs rises, holds till cs drops
    integer latctr;
    always @(posedge clk) begin
        if (!rom_cs)      begin rom_ok<=0; latctr<=0; end
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

    reg [15:0] fb [0:76799]; integer i;
    initial for(i=0;i<76800;i=i+1) fb[i]=16'h0;
    always @(posedge clk)
        if (u_dut.buf_we && u_dut.buf_wdata[7:0]!=8'h0 && u_dut.buf_waddr<9'd320 && vrender<9'd240)
            fb[vrender*320 + u_dut.buf_waddr] <= u_dut.buf_wdata;

    reg [15:0] golden [0:76799];
    initial $readmemh("golden_obj_f2700.hex", golden);

    integer ln, cyc, mism;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            for(cyc=0; cyc<8000; cyc=cyc+1) @(posedge clk);
        end
        mism=0;
        for(i=0;i<76800;i=i+1) if(fb[i]!==golden[i]) begin
            if(mism<5) $display("  mismatch @%0d (line %0d x %0d): rtl=%04x golden=%04x",
                                 i, i/320, i%320, fb[i], golden[i]);
            mism=mism+1;
        end
        $display("tb_obj_f2700_latexact LAT=%0d: mismatches=%0d/76800", `LAT, mism);
        $display("RESULT: %s", (mism==0) ? "PASS -- byte-exact under injected latency" : "FAIL");
        $finish;
    end
endmodule
