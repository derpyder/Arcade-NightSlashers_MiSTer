`timescale 1ns/1ps
`include "obj_cfg.vh"
// Same as tb_obj.v but with a CONFIGURABLE SDRAM-like ROM latency model (rom_ok delayed N clk after
// rom_cs rising, like the real jtnslasher_sdram 2-read FSM) AND a realistic per-line cycle budget.
// Goal: stress the obj engine's draw-FSM handshake + the line_cnt>=40 cap on a complex frame.
//   +define+LAT=<n>  ROM latency in clk (default 8); +define+BUDGET=<n> clk/line (default 3000)
module tb_obj_lat;
    reg          clk=0, rst=1, pxl_cen=1;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1, LVBL=1;

    wire [ 9:0]  tbl_addr; reg [15:0] tbl_dout;
    wire         rom_cs;   wire [20:0] rom_addr; reg [8*`BPP-1:0] rom_data; reg rom_ok=0;
    wire [15:0]  pxl;
`ifndef LAT
  `define LAT 8
`endif
`ifndef BUDGET
  `define BUDGET 3000
`endif
    always #5 clk=~clk;

    reg [31:0] sprtbl [0:2047];
    initial $readmemh(`SPRFILE, sprtbl);
    always @(posedge clk) tbl_dout <= sprtbl[tbl_addr][15:0];

    // gfx ROM with LAT-cycle latency: track rom_cs rising, count down, present data+ok when ready.
    reg [8*`BPP-1:0] gfxrom [0:`MEMW-1];
    initial $readmemh(`GFXFILE, gfxrom);
    reg rom_cs_d; integer latcnt; reg [20:0] addr_l;
    initial begin rom_cs_d=0; latcnt=0; rom_ok=0; end
    always @(posedge clk) begin
        rom_cs_d <= rom_cs;
        if( rom_cs & ~rom_cs_d ) begin          // new request
            latcnt <= `LAT; rom_ok <= 0; addr_l <= rom_addr;
        end else if( rom_cs ) begin
            if( rom_addr != addr_l ) begin       // address changed mid-cs (2nd half) -> re-latency
                latcnt <= `LAT; rom_ok <= 0; addr_l <= rom_addr;
            end else if( latcnt>0 ) begin
                latcnt <= latcnt-1;
                if( latcnt==1 ) begin rom_data <= gfxrom[addr_l]; rom_ok <= 1; end
            end
        end else begin
            rom_ok <= 0;
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

    integer ln, cyc, f;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            for(cyc=0; cyc<`BUDGET; cyc=cyc+1) @(posedge clk);
        end
        f=$fopen("frame_obj.hex","w");
        for(i=0;i<76800;i=i+1) $fwrite(f,"%04x\n", fb[i]);
        $fclose(f);
        $display("tb_obj_lat: LAT=%0d BUDGET=%0d -> frame_obj.hex", `LAT, `BUDGET);
        $finish;
    end
endmodule
