`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_obj0_lat_nonfold — MEASURE the TRUE per-tile-half obj0 fetch latency for the
// CURRENT (committed) NON-FOLD obj0 path, on REAL SDRAM.
//
// DUT = the real jtnslasher_sdram adapter (obj0 -> obj0lo DW32 + obj0hi DW8, both
// BA3, recombined to 40-bit, obj0_rom_ok = obj0lo_ok & obj0hi_ok) + the real
// jtframe_rom_3slots BA3 (SLOT0=obj0lo DW32 DOUBLE, SLOT1=obj0hi DW8 DOUBLE,
// SLOT2=obj1 DW32 DOUBLE) wired EXACTLY as mister/jtnslasher_game_sdram.v +
// jtframe_sdram64 + mt48lc16m16a2.
//
// A faithful mini-engine (mirrors jtnslasher_obj rom_cs/rom_good/2nd-ok consume)
// drives back-to-back tile fetches at REAL scattered addresses (= row misses).
// We TIME, for each fetch, the cycles from rom_cs-rise to the consume edge
// (rom_cs && rom_good && rom_ok), i.e. the engine-observable rom_cs->rom_ok
// latency for the SERIALIZED obj0lo+obj0hi pair. Report min/max/mean/histogram.
// =============================================================================
module tb_obj0_lat_nonfold;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    // engine <-> adapter
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    // adapter <-> BA3 slots
    wire        obj0lo_cs, obj0hi_cs, obj1_cs;
    wire [20:0] obj0lo_addr, obj0hi_addr;
    wire [17:0] obj1_addr;
    wire [31:0] obj0lo_data, obj1_data;
    wire [ 7:0] obj0hi_data;
    wire        obj0lo_ok, obj0hi_ok, obj1_ok;

    // controller plumbing (bank3 only used)
    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {rom_rd, 3'b0};
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    localparam [21:0] OBJ0HI_OFFSET = 22'h20_0000; // obj0hi region (16-bit-word space, within bank model)
    localparam [21:0] GFX4_OFFSET   = 22'h30_0000;

    // ===== DUT: the REAL non-fold adapter =====
    jtnslasher_sdram u_dut(
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
        .obj0lo_cs(obj0lo_cs), .obj0lo_addr(obj0lo_addr), .obj0lo_data(obj0lo_data), .obj0lo_ok(obj0lo_ok),
        .obj0hi_cs(obj0hi_cs), .obj0hi_addr(obj0hi_addr), .obj0hi_data(obj0hi_data), .obj0hi_ok(obj0hi_ok),
        .obj1_cs(obj1_cs), .obj1_addr(obj1_addr), .obj1_data(obj1_data), .obj1_ok(obj1_ok)
    );

    // ===== REAL BA3: jtframe_rom_3slots (obj0lo DW32 + obj0hi DW8 + obj1 DW32, all DOUBLE) =====
    // Mirrors mister/jtnslasher_game_sdram.v u_bank3 exactly.
    jtframe_rom_3slots #(
        .SDRAMW(SDRAMW),
        .SLOT0_AW(22), .SLOT0_DW(32),
        .SLOT1_OFFSET({1'b0,OBJ0HI_OFFSET[20:0]}), .SLOT1_AW(21), .SLOT1_DW(8),
        .SLOT2_OFFSET({1'b0,GFX4_OFFSET[20:0]}),   .SLOT2_AW(19), .SLOT2_DW(32),
        .SLOT0_DOUBLE(1), .SLOT1_DOUBLE(1), .SLOT2_DOUBLE(1)
    ) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0lo_addr, 1'b0}), .slot0_dout(obj0lo_data), .slot0_cs(obj0lo_cs), .slot0_ok(obj0lo_ok),
        .slot1_addr(obj0hi_addr),         .slot1_dout(obj0hi_data), .slot1_cs(obj0hi_cs), .slot1_ok(obj0hi_ok),
        .slot2_addr({obj1_addr, 1'b0}),   .slot2_dout(obj1_data),   .slot2_cs(obj1_cs),   .slot2_ok(obj1_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rom_rd), .sdram_addr(rom_saddr),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    jtframe_sdram64 #(
        .AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)
    ) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr({SDRAMW{1'b0}}), .ba2_addr({SDRAMW{1'b0}}), .ba3_addr(rom_saddr),
        .rd(ba_rd), .wr(ba_wr),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(1'b0), .prog_addr({SDRAMW{1'b0}}), .prog_rd(1'b0), .prog_wr(1'b0),
        .prog_din(16'd0), .prog_dsn(2'b11), .prog_ba(2'b00),
        .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
        .rfsh(1'b0),
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

    // ---- test vectors (addresses only; data correctness already proven elsewhere) ----
    reg [23:0] tv_addr [0:8191];
    initial $readmemh("objfold_real_addr.hex", tv_addr);

    // =========================================================================
    // faithful mini-engine: rom_cs / rom_good / 2nd-ok consume, back-to-back tiles
    // =========================================================================
    integer eng_i;
    reg     rom_good;
    reg     running, done;
    integer stall;
    reg     started;

    // ---- latency instrumentation ----
    integer cs_cyc;         // cycles since this fetch's rom_cs rose
    integer lat_min, lat_max, lat_sum, lat_n;
    integer lat_hist [0:127];
    integer warm;           // ignore the first few (cold-bank) fetches
    integer hi;
    initial begin
        for(hi=0;hi<128;hi=hi+1) lat_hist[hi]=0;
        lat_min=999999; lat_max=0; lat_sum=0; lat_n=0; warm=0;
    end

    localparam NMEAS = (`OBJFOLD_N < 512) ? `OBJFOLD_N : 512;

    always @(posedge clk) begin
        if( rst ) begin
            eng_i<=0; obj0_rom_cs<=0; obj0_rom_addr<=0; rom_good<=0;
            running<=0; done<=0; started<=0; stall<=0; cs_cyc<=0;
        end else if( running && !done ) begin
            rom_good <= obj0_rom_cs & obj0_rom_ok;

            if( obj0_rom_cs ) cs_cyc <= cs_cyc + 1;

            if( obj0_rom_cs && !(obj0_rom_cs && rom_good && obj0_rom_ok) ) stall <= stall+1;

            if( obj0_rom_cs && rom_good && obj0_rom_ok ) begin
                // CONSUME: this is the engine-observable completion. cs_cyc = rom_cs->consume latency.
                warm <= warm + 1;
                if( warm >= 8 ) begin   // skip cold-bank settling
                    if( cs_cyc < lat_min ) lat_min <= cs_cyc;
                    if( cs_cyc > lat_max ) lat_max <= cs_cyc;
                    lat_sum <= lat_sum + cs_cyc;
                    lat_n   <= lat_n + 1;
                    if( cs_cyc < 128 ) lat_hist[cs_cyc] <= lat_hist[cs_cyc] + 1;
                end
                obj0_rom_cs <= 0;
                rom_good    <= 0;
                stall       <= 0;
                if( eng_i == NMEAS-1 ) done <= 1;
                else                   eng_i <= eng_i+1;
            end else if( !obj0_rom_cs ) begin
                if( !done ) begin
                    obj0_rom_addr <= tv_addr[eng_i][20:0];
                    obj0_rom_cs   <= 1;
                    rom_good      <= 0;
                    cs_cyc        <= 0;   // start timing this fetch
                end
            end

            if( stall > 2000 ) begin
                $display("  STALL/HANG at i=%0d engaddr=%06x", eng_i, tv_addr[eng_i][20:0]);
                done <= 1;
            end
        end else if( started && !running ) begin
            running <= 1;
        end
    end

    // ---- serialization probe: time obj0lo_ok and obj0hi_ok rise within mid-stream fetches ----
    reg lo_seen, hi_seen; integer lo_t, hi_t, pf;
    always @(posedge clk) if(running && !done) begin
        if(!obj0_rom_cs) begin lo_seen<=0; hi_seen<=0; end
        else begin
            if(obj0lo_ok && !lo_seen) begin lo_seen<=1; lo_t<=cs_cyc; end
            if(obj0hi_ok && !hi_seen) begin hi_seen<=1; hi_t<=cs_cyc; end
            if(obj0lo_ok && obj0hi_ok && !(lo_seen&&hi_seen) && pf<6 && warm>=8) begin
                $display("  fetch warm#%0d: obj0lo_ok@cyc%0d obj0hi_ok@cyc%0d (both@%0d)", warm, lo_t, hi_t, cs_cyc);
                pf<=pf+1;
            end
        end
    end

    integer k;
    initial begin
        pf=0; lo_seen=0; hi_seen=0;
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_obj0_lat_nonfold: REAL non-fold (obj0lo DW32 + obj0hi DW8, both BA3) ---");
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("NON-FOLD obj0  rom_cs->rom_ok latency over %0d back-to-back fetches:", lat_n);
        $display("  min=%0d  max=%0d  mean=%0d clk", lat_min, lat_max, (lat_n>0)?(lat_sum/lat_n):0);
        $display("  histogram (lat clk : count):");
        for(k=0;k<128;k=k+1) if(lat_hist[k]>0) $display("    %3d : %0d", k, lat_hist[k]);
        $display("==================================================");
        $finish;
    end
    initial begin #800_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
