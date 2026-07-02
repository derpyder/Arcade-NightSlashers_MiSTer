`timescale 1ns/1ps
`ifndef TRIGLINE
 `define TRIGLINE 100
`endif
module tb_tear_sweep;
    parameter BPP=5;
    reg clk=0, rst=1; always #5 clk=~clk;
    reg [1:0] ph=0; reg pxl_cen=0;
    always @(posedge clk) begin ph<=ph+2'd1; pxl_cen<=(ph==2'd3); end
    reg [10:0] cpu_waddr=0; reg [15:0] cpu_wdata=0; reg cpu_we=0;
    reg dma_trig=0; localparam [10:0] SPR_LAST=11'd1023;
    reg [10:0] dma0_raddr,dma0_waddr; reg dma0_run,dma0_wen; wire [15:0] dma0_rdata;
    always @(posedge clk,posedge rst) begin
        if(rst) begin dma0_run<=0;dma0_raddr<=0;dma0_waddr<=0;dma0_wen<=0; end
        else begin dma0_wen<=dma0_run; dma0_waddr<=dma0_raddr;
            if(dma_trig) begin dma0_run<=1;dma0_raddr<=0; end
            else if(dma0_run) begin if(dma0_raddr==SPR_LAST) dma0_run<=0; dma0_raddr<=dma0_raddr+11'd1; end end
    end
    jtframe_dual_ram #(.DW(16),.AW(11)) u_spr0(.clk0(clk),.data0(cpu_wdata),.addr0(cpu_waddr),.we0(cpu_we),.q0(),
        .clk1(clk),.data1(16'd0),.addr1(dma0_raddr),.we1(1'b0),.q1(dma0_rdata));
    wire [9:0] tbl_addr; wire [15:0] tbl_dout;
    jtframe_dual_ram #(.DW(16),.AW(11)) u_spr0_sh(.clk0(clk),.data0(dma0_rdata),.addr0(dma0_waddr),.we0(dma0_wen),.q0(),
        .clk1(clk),.data1(16'd0),.addr1({1'b0,tbl_addr}),.we1(1'b0),.q1(tbl_dout));
    localparam MEMW=1277440; reg [8*BPP-1:0] gfxrom[0:MEMW-1];
    initial $readmemh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/gfx3_combined.hex",gfxrom);
    wire rom_cs; wire [20:0] rom_addr; reg [8*BPP-1:0] rom_data; reg rom_ok=0;
    always @(posedge clk) begin rom_data<=gfxrom[rom_addr]; rom_ok<=rom_cs; end
    reg [8:0] vrender=0,hdump=0; reg HS=0,LHBL=1,LVBL=1; wire [15:0] pxl;
    jtnslasher_obj #(.BPP(BPP)) u_obj(.rst(rst),.clk(clk),.pxl_cen(pxl_cen),.HS(HS),.LVBL(LVBL),.LHBL(LHBL),
        .vrender(vrender),.hdump(hdump),.tbl_addr(tbl_addr),.tbl_dout(tbl_dout),
        .rom_cs(rom_cs),.rom_addr(rom_addr),.rom_data(rom_data),.rom_ok(rom_ok),.pxl(pxl));
    reg [15:0] fb[0:76799]; integer i;
    always @(posedge clk) if(u_obj.buf_we&&u_obj.buf_wdata[7:0]!=8'h0&&u_obj.buf_waddr<9'd320&&vrender<9'd240)
        fb[vrender*320+u_obj.buf_waddr]<=u_obj.buf_wdata;
    reg [31:0] oamA[0:2047],oamB[0:2047];
    initial begin $readmemh("/path/to/nightslashers/mame-dump/caps/f1800_spr0.hex",oamA);
        $readmemh("/path/to/nightslashers/mame-dump/caps/f2400_spr0.hex",oamB); end
    task load_live(input integer s); integer k; begin
        for(k=0;k<1024;k=k+1) begin @(posedge clk);#1; cpu_waddr=k[10:0];
            cpu_wdata=(s==0)?oamA[k][15:0]:oamB[k][15:0]; cpu_we=1; end
        @(posedge clk);#1; cpu_we=0; end endtask
    task do_dma; begin @(posedge clk);#1;dma_trig=1; @(posedge clk);#1;dma_trig=0; repeat(1100)@(posedge clk); end endtask
    integer ln,cyc;
    initial begin
        rst=1; repeat(20)@(posedge clk); rst=0; repeat(5)@(posedge clk);
        load_live(0); do_dma; load_live(1);
        for(i=0;i<76800;i=i+1) fb[i]=16'h0;
        LVBL=0; repeat(2)@(posedge clk); LVBL=1; repeat(2)@(posedge clk);
        for(ln=0;ln<240;ln=ln+1) begin
            vrender=ln[8:0]; @(posedge clk) HS=1; @(posedge clk) HS=0;
            if(ln==`TRIGLINE) begin #1;dma_trig=1; @(posedge clk) HS=0; #1;dma_trig=0; end
            for(cyc=0;cyc<6000;cyc=cyc+1)@(posedge clk);
        end
        begin : dmp integer f; f=$fopen($sformatf("tear_trig%0d.hex",`TRIGLINE),"w");
            for(i=0;i<76800;i=i+1)$fwrite(f,"%04x\n",fb[i]); $fclose(f); end
        $display("sweep TRIGLINE=%0d done",`TRIGLINE); $finish;
    end
endmodule
