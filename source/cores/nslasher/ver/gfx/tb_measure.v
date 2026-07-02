`timescale 1ns/1ps
`include "obj_cfg_f2700.vh"
module tb_measure;
    reg clk=0, rst=1, pxl_cen=1;
    reg [8:0] vrender=0, hdump=0;
    reg HS=0, LHBL=1, LVBL=1;
    wire [9:0] tbl_addr; reg [15:0] tbl_dout;
    wire rom_cs; wire [20:0] rom_addr; reg [8*`BPP-1:0] rom_data; reg rom_ok=0;
    wire [15:0] pxl;
    always #5 clk=~clk;
    reg [31:0] sprtbl [0:2047];
    initial $readmemh(`SPRFILE, sprtbl);
    always @(posedge clk) tbl_dout <= sprtbl[tbl_addr][15:0];
    reg [8*`BPP-1:0] gfxrom [0:`MEMW-1];
    initial $readmemh(`GFXFILE, gfxrom);
    always @(posedge clk) begin rom_data <= gfxrom[rom_addr]; rom_ok <= rom_cs; end
    jtnslasher_obj #(.BPP(`BPP)) u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
        .vrender(vrender), .hdump(hdump), .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok), .pxl(pxl));
    integer ln,cyc; integer maxcnt=0; integer busyclks; integer maxbusy=0; integer activeline=0;
    // track parse_busy / draw activity duration per line
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        for(ln=0; ln<240; ln=ln+1) begin
            vrender=ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            busyclks=0;
            for(cyc=0; cyc<6000; cyc=cyc+1) begin
                @(posedge clk);
                if(u_dut.parse_busy || u_dut.draw_busy) busyclks=busyclks+1;
                if(u_dut.line_cnt>maxcnt) begin maxcnt=u_dut.line_cnt; activeline=ln; end
            end
            if(u_dut.line_cnt>maxcnt) begin maxcnt=u_dut.line_cnt; activeline=ln; end
            if(busyclks>maxbusy) maxbusy=busyclks;
        end
        $display("MAX line_cnt(sprites drawn/line)=%0d at line %0d ; MAX busy clks/line=%0d", maxcnt, activeline, maxbusy);
        $display("(budget at clk/8 pxl_cen, 384 px/line = 3072 clk/line; this tb uses behavioral 1-clk rom)");
        $finish;
    end
endmodule
