`timescale 1ns/1ps
// tb_tear.v — DMA-shadow TEAR reproduction for jtnslasher (obj0 / gfx3 5bpp).
//
// Reconstructs the EXACT spr0 DMA path from jtnslasher_vmem (u_spr0 LIVE + u_spr0_sh SHADOW +
// the dma0 engine) feeding the real jtnslasher_obj engine. Drives a CHANGING OAM:
//   frame A = f1800 OAM, frame B = f2400 OAM  (178 sprites differ).
// Three render passes, each dumped to its own frame buffer:
//   PASS 0 (clean A): load A live, trigger DMA, render A-line-scan  -> should == golden_obj(f1800)
//   PASS 1 (clean B): load B live, trigger DMA, render B-line-scan  -> the intended frame
//   PASS 2 (TEAR)   : shadow holds A; begin streaming B into LIVE and fire the DMA trigger at a
//                     mid-display scanline, so the obj engine reads a half-A/half-B SHADOW while
//                     it scans -> tear. Dump and diff vs clean-B.
//
// The gfx ROM is behavioral (combined f1800+f2400 tiles), 1-clk latency, always-ready — identical
// to tb_obj, so any difference is purely the OAM/DMA path, not gfx timing.
//
// Output: tear_pass0.hex / tear_pass1.hex / tear_pass2.hex (320x240 mix words), + $display stats.

module tb_tear;
    parameter BPP=5;
    reg clk=0, rst=1;
    always #5 clk=~clk;

    // ---- timing model: clk/4 pixel clock, 384 px/line, line=1536 sysclk (matches tb_vmem vtimer) ----
    // We synthesize HS / vrender / LHBL / LVBL by hand so we control exactly when (which line/phase)
    // the DMA trigger fires relative to the active scan.
    reg [1:0] ph=0; reg pxl_cen=0;
    always @(posedge clk) begin ph<=ph+2'd1; pxl_cen<=(ph==2'd3); end

    // ===== sprite tables: LIVE RAM (u_spr0) + SHADOW RAM (u_spr0_sh) =====
    // CPU side
    reg  [10:0] cpu_waddr=0; reg [15:0] cpu_wdata=0; reg cpu_we=0;
    // DMA engine (verbatim from jtnslasher_vmem.v lines 136-156)
    reg  dma_trig=0;
    localparam [10:0] SPR_LAST=11'd1023;
    reg  [10:0] dma0_raddr, dma0_waddr;
    reg         dma0_run, dma0_wen;
    wire [15:0] dma0_rdata;
    always @(posedge clk, posedge rst) begin
        if(rst) begin dma0_run<=0; dma0_raddr<=0; dma0_waddr<=0; dma0_wen<=0; end
        else begin
            dma0_wen   <= dma0_run;
            dma0_waddr <= dma0_raddr;
            if(dma_trig) begin dma0_run<=1; dma0_raddr<=0; end
            else if(dma0_run) begin
                if(dma0_raddr==SPR_LAST) dma0_run<=0;
                dma0_raddr <= dma0_raddr + 11'd1;
            end
        end
    end
    // LIVE RAM: CPU write (port0) + DMA read (port1)
    jtframe_dual_ram #(.DW(16),.AW(11)) u_spr0(
        .clk0(clk), .data0(cpu_wdata), .addr0(cpu_waddr),  .we0(cpu_we),  .q0(),
        .clk1(clk), .data1(16'd0),     .addr1(dma0_raddr), .we1(1'b0),    .q1(dma0_rdata) );
    // obj engine read of the SHADOW
    wire [9:0]  tbl_addr; wire [15:0] tbl_dout;
    // SHADOW RAM: DMA write (port0) + obj read (port1)
    jtframe_dual_ram #(.DW(16),.AW(11)) u_spr0_sh(
        .clk0(clk), .data0(dma0_rdata), .addr0(dma0_waddr),       .we0(dma0_wen), .q0(),
        .clk1(clk), .data1(16'd0),      .addr1({1'b0,tbl_addr}),  .we1(1'b0),     .q1(tbl_dout) );

    // ===== gfx ROM (behavioral, combined tiles, 1-clk latency, always ready) =====
    localparam MEMW = 1277440;
    reg [8*BPP-1:0] gfxrom [0:MEMW-1];
    initial $readmemh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/gfx3_combined.hex", gfxrom);
    wire        rom_cs;  wire [20:0] rom_addr; reg [8*BPP-1:0] rom_data; reg rom_ok=0;
    always @(posedge clk) begin rom_data<=gfxrom[rom_addr]; rom_ok<=rom_cs; end

    // ===== obj engine timing inputs =====
    reg  [8:0] vrender=0; reg [8:0] hdump=0;
    reg        HS=0, LHBL=1, LVBL=1;
    wire [15:0] pxl;

    jtnslasher_obj #(.BPP(BPP)) u_obj(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
        .vrender(vrender), .hdump(hdump),
        .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .pxl(pxl) );

    // ===== capture: snoop line-buffer writes (same as tb_obj) into per-pass framebuffers =====
    reg [15:0] fb [0:76799]; integer i;
    integer passid=0;
    always @(posedge clk)
        if (u_obj.buf_we && u_obj.buf_wdata[7:0]!=8'h0 && u_obj.buf_waddr<9'd320 && vrender<9'd240)
            fb[vrender*320 + u_obj.buf_waddr] <= u_obj.buf_wdata;

    // ===== OAM source caps =====
    reg [31:0] oamA [0:2047];   // f1800
    reg [31:0] oamB [0:2047];   // f2400
    initial begin
        $readmemh("/path/to/nightslashers/mame-dump/caps/f1800_spr0.hex", oamA);
        $readmemh("/path/to/nightslashers/mame-dump/caps/f2400_spr0.hex", oamB);
    end

    // ---- load N words of an OAM cap into LIVE RAM via the CPU write port ----
    task load_live(input integer src); integer k; begin
        for(k=0;k<1024;k=k+1) begin
            @(posedge clk); #1;
            cpu_waddr = k[10:0];
            cpu_wdata = (src==0) ? oamA[k][15:0] : oamB[k][15:0];
            cpu_we    = 1;
        end
        @(posedge clk); #1; cpu_we=0;
    end endtask

    // ---- one full DMA copy, then settle ----
    task do_dma; begin
        @(posedge clk); #1; dma_trig=1;
        @(posedge clk); #1; dma_trig=0;
        repeat(1100) @(posedge clk);   // let the 1024-word copy complete
    end endtask

    // ---- render 240 lines (line scan like tb_obj) ----
    task render_frame; integer ln,cyc; begin
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            for(cyc=0; cyc<6000; cyc=cyc+1) @(posedge clk);
        end
    end endtask

    // ---- render 240 lines, but fire the DMA trigger at a chosen active line (TEAR) ----
    // We ALSO stream the new OAM (B) into the LIVE RAM concurrently so the copy carries B.
    task render_frame_with_tear(input integer trigline); integer ln,cyc; begin
        LVBL=0; repeat(2) @(posedge clk); LVBL=1; repeat(2) @(posedge clk);
        for(ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            if(ln==trigline) begin
                // LIVE already holds B (we loaded it before this task). Fire the copy NOW, mid-display.
                #1; dma_trig=1; @(posedge clk) HS=0; #1; dma_trig=0;
            end
            for(cyc=0; cyc<6000; cyc=cyc+1) @(posedge clk);
        end
    end endtask

    task dump(input [255:0] fname); integer f; begin
        f=$fopen(fname,"w");
        for(i=0;i<76800;i=i+1) $fwrite(f,"%04x\n", fb[i]);
        $fclose(f);
    end endtask

    task clearfb; begin for(i=0;i<76800;i=i+1) fb[i]=16'h0; end endtask

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);

        // ===== PASS 0: clean A (f1800) =====
        load_live(0); do_dma; clearfb; render_frame;
        dump("tear_pass0.hex");
        $display("tb_tear: PASS0 (clean A=f1800) -> tear_pass0.hex");

        // ===== PASS 1: clean B (f2400) =====
        load_live(1); do_dma; clearfb; render_frame;
        dump("tear_pass1.hex");
        $display("tb_tear: PASS1 (clean B=f2400) -> tear_pass1.hex");

        // ===== PASS 2: TEAR. shadow currently holds B (from pass1). Reload shadow with A, then
        //      put B in LIVE and fire the copy at mid-display so the scan straddles the copy. =====
        load_live(0); do_dma;            // shadow := A
        load_live(1);                    // LIVE := B (shadow still A)
        clearfb;
        render_frame_with_tear(100);     // fire copy at active line 100
        dump("tear_pass2.hex");
        $display("tb_tear: PASS2 (TEAR: copy fired at active line 100) -> tear_pass2.hex");

        $finish;
    end
endmodule
