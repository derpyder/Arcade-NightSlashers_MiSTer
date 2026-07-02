`timescale 1ns/1ps
// =============================================================================
// tb_obj_engine_cont — REAL obj engine (jtnslasher_obj) + REAL fold FSM
// (jtnslasher_sdram obj0 path) + REAL jtframe_sdram64 + mt48lc16m16a2, UNDER
// REFRESH CONTENTION (varied/irregular obj0_ok latency).
//
// PURPOSE: the existing tb_objfold_real_cont uses a faithful *mini*-engine that
// only checks the 40-bit fold word. This tb instead drives the ACTUAL
// jtnslasher_obj.v draw FSM (rom_good registered + 2nd-ok consume + draw_data
// latch + 8-pixel shift) so we can test the UNIFORM-COLLAPSE hypothesis:
// under irregular obj0_ok, does the engine latch a STALE/CONSTANT draw_data and
// write the SAME pixels for many DIFFERENT tiles?  We snoop the line-buffer
// write stream (buf_we/buf_wdata) and report the DISTINCT pen/word histogram.
//
// A small sprite table is preloaded with several DISTINCT sprites at distinct
// codes so their gfx differs; if the buffer write stream collapses to one
// repeated pen/value across tiles, the uniform-collapse mechanism is CONFIRMED.
// =============================================================================
module tb_obj_engine_cont;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    // ---- video timing stimulus ----
    reg pxl_cen=0; reg [1:0] cendiv=0;
    always @(posedge clk) begin cendiv<=cendiv+1; pxl_cen<=(cendiv==0); end

    reg        HS=0, LVBL=1, LHBL=1;
    reg  [8:0] vrender=0, hdump=0;

    // ---- engine <-> fold FSM ----
    wire        obj0_rom_cs;
    wire [20:0] obj0_rom_addr;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    // ---- engine <-> sprite table RAM ----
    wire [9:0]  tbl_addr;
    reg  [15:0] tbl [0:1023];
    reg  [15:0] tbl_dout;
    always @(posedge clk) tbl_dout <= tbl[tbl_addr];

    // ---- fold FSM <-> real slot ----
    wire        obj0_cs;
    wire [21:0] obj0_addr;
    wire [31:0] obj0_data;
    wire        obj0_ok;

    // ---- controller plumbing ----
    wire        rd3; wire [SDRAMW-1:0] saddr3;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = { rd3, 3'b0 };
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq; wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba; wire init;

    // ===== DUT 1: REAL obj engine =====
    wire [15:0] pxl;
    jtnslasher_obj #(.BPP(5)) u_eng(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
        .vrender(vrender), .hdump(hdump),
        .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(obj0_rom_cs), .rom_addr(obj0_rom_addr),
        .rom_data(obj0_rom_data), .rom_ok(obj0_rom_ok),
        .pxl(pxl)
    );

    // ===== DUT 2: REAL fold FSM (obj0 path of jtnslasher_sdram) =====
    jtnslasher_sdram u_fold(
        .rst(rst), .clk(clk),
        .pf1_rom_cs(1'b0), .pf1_rom_addr(19'd0), .pf1_rom_data(), .pf1_rom_ok(),
        .pf2_rom_cs(1'b0), .pf2_rom_addr(19'd0), .pf2_rom_data(), .pf2_rom_ok(),
        .pf3_rom_cs(1'b0), .pf3_rom_addr(19'd0), .pf3_rom_data(), .pf3_rom_ok(),
        .pf4_rom_cs(1'b0), .pf4_rom_addr(19'd0), .pf4_rom_data(), .pf4_rom_ok(),
        .obj0_rom_cs(obj0_rom_cs), .obj0_rom_addr(obj0_rom_addr),
        .obj0_rom_data(obj0_rom_data), .obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(1'b0), .obj1_rom_addr(21'd0), .obj1_rom_data(), .obj1_rom_ok(),
        .gfx1a_cs(), .gfx1a_addr(), .gfx1a_data(16'd0), .gfx1a_ok(1'b0),
        .gfx1b_cs(), .gfx1b_addr(), .gfx1b_data(16'd0), .gfx1b_ok(1'b0),
        .gfx2a_cs(), .gfx2a_addr(), .gfx2a_data(16'd0), .gfx2a_ok(1'b0),
        .gfx2b_cs(), .gfx2b_addr(), .gfx2b_data(16'd0), .gfx2b_ok(1'b0),
        .obj0_cs(obj0_cs), .obj0_addr(obj0_addr), .obj0_data(obj0_data), .obj0_ok(obj0_ok),
        .obj1_cs(), .obj1_addr(), .obj1_data(32'd0), .obj1_ok(1'b0)
    );

    jtframe_rom_1slot #(.SDRAMW(SDRAMW), .SLOT0_AW(23), .SLOT0_DW(32), .SLOT0_DOUBLE(1)) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data),
        .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rd3), .sdram_addr(saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    // ---- refresh-pulse contention to vary obj0 latency ----
    reg  [7:0] rfsh_cnt=0;  reg rfsh_pulse=0;
    wire       en = ~init & ~rst;
    always @(posedge clk) begin
        if(!en) begin rfsh_cnt<=0; rfsh_pulse<=0; end
`ifdef NOCONT
        else begin rfsh_cnt<=0; rfsh_pulse<=0; end
`else
        else begin rfsh_cnt<=rfsh_cnt+8'd1; rfsh_pulse<=(rfsh_cnt==8'd97); end
`endif
    end

    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1), .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr({SDRAMW{1'b0}}), .ba2_addr({SDRAMW{1'b0}}), .ba3_addr(saddr3),
        .rd(ba_rd), .wr(ba_wr),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(1'b0), .prog_addr({SDRAMW{1'b0}}), .prog_rd(1'b0), .prog_wr(1'b0),
        .prog_din(16'd0), .prog_dsn(2'b11), .prog_ba(2'b00),
        .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
        .rfsh(rfsh_pulse),
        .ack(ba_ack), .dst(ba_dst), .dok(ba_dok), .rdy(ba_rdy), .dout(dout),
        .sdram_dq(sdram_dq), .sdram_a(sdram_a),
        .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
        .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
        .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
    );

    mt48lc16m16a2 u_sdram(
        .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba), .Clk(clk), .Cke(sdram_cke),
        .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
        .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
    );

    // ===== sprite table preload: N distinct sprites, distinct codes, same line =====
    integer i;
    initial begin
        for(i=0;i<1024;i=i+1) tbl[i]=16'h0000;
        // place 8 sprites at y=0, msz=0 (16 tall), distinct codes, distinct x, distinct colour
        for(i=0;i<8;i=i+1) begin
            tbl[i*4+0] = 16'h0000;                 // y=0, no flip, msz=0, colhi=0
            tbl[i*4+1] = (i+1);                    // code 1..8 (real gfx in preload)
            tbl[i*4+2] = { 7'(i+1), 9'(i*16+8) };  // colour=i+1, x=i*16+8
            tbl[i*4+3] = 16'h0000;
        end
        // sentinel so parse stops cleanly (sprite 8 off-zone: y far)
        tbl[8*4+0] = 16'd200;  // y=200 -> off zone for vrender=4
    end

    // ===== snoop the line-buffer write stream (the actual pixels going to the buffer) =====
    // probe internal engine signals
    wire        s_buf_we   = u_eng.buf_we;
    wire [15:0] s_buf_wd   = u_eng.buf_wdata;
    wire [4:0]  s_pen      = u_eng.buf_wdata[4:0];   // BPP=5 -> pen in low 5
    // distinct value tracking
    integer nwr=0, nopaque=0;
    // crude distinct-pen histogram (32 pens)
    integer pen_hist [0:31];
    // crude distinct draw_data tracking: record first/last latched draw_data
    reg [39:0] s_drawdata;
    integer ndd=0;
    reg [39:0] dd_seen [0:255];
    integer dd_n=0;
    integer j; reg found;

    always @(posedge clk) if(en && !rst) begin
        if( s_buf_we ) begin
            nwr <= nwr+1;
            if( s_buf_wd[7:0]!=8'h0 ) nopaque<=nopaque+1;   // opaque (pen!=0)
            pen_hist[s_pen] <= pen_hist[s_pen]+1;
        end
    end

    // track DISTINCT draw_data values latched (line 154 of obj: draw_data<=rom_data on consume)
    // detect that event: consume = !buf_we && rom_cs && rom_good && rom_ok && draw_cnt==0 in engine
    wire consume = (!u_eng.buf_we) && u_eng.rom_cs && u_eng.rom_good && obj0_rom_ok && (u_eng.draw_cnt==0);
    always @(posedge clk) if(en && !rst && consume) begin
        found=0;
        for(j=0;j<dd_n;j=j+1) if(dd_seen[j]===obj0_rom_data) found=1;
        if(!found && dd_n<256) begin dd_seen[dd_n]=obj0_rom_data; dd_n=dd_n+1; end
        ndd=ndd+1;
        if(ndd<=24) $display("  CONSUME #%0d draw_data=%010x (distinct so far=%0d)", ndd, obj0_rom_data, dd_n);
    end

    initial for(i=0;i<32;i=i+1) pen_hist[i]=0;

    // ===== orchestration: run one render line =====
    integer pen_distinct;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_obj_engine_cont: REAL engine + REAL fold + REFRESH contention ---");
        vrender = 9'd4;     // a line inside the sprites (y=0, 16 tall)
        // pulse HS low->high->low to trigger new-line parse
        HS=1; repeat(2) @(posedge clk);
        HS=0; repeat(2) @(posedge clk);
        HS=1; @(posedge clk);  // HSl<=HS; next cycle HSl&&!HS triggers
        HS=0;
        // let the engine parse + draw all sprites for this line
        repeat(6000) @(posedge clk);
        // results
        pen_distinct=0;
        for(i=0;i<32;i=i+1) if(pen_hist[i]>0) pen_distinct=pen_distinct+1;
        $display("==================================================");
        $display("  buffer writes total=%0d, opaque(pen!=0)=%0d", nwr, nopaque);
        $display("  DISTINCT pens written to line buffer: %0d", pen_distinct);
        for(i=0;i<32;i=i+1) if(pen_hist[i]>0) $display("    pen %2d : %0d writes", i, pen_hist[i]);
        $display("  consumes=%0d, DISTINCT draw_data words latched=%0d", ndd, dd_n);
        $display("==================================================");
        if( ndd>=2 && dd_n<=1 )
            $display("  *** UNIFORM-COLLAPSE CONFIRMED: %0d consumes but only %0d distinct draw_data ***", ndd, dd_n);
        else if( pen_distinct<=1 && nopaque>0 )
            $display("  *** UNIFORM PEN: all opaque pixels share one pen ***");
        else
            $display("  NOT uniform: engine produced %0d distinct draw_data / %0d distinct pens", dd_n, pen_distinct);
        $finish;
    end
    initial begin #200_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
