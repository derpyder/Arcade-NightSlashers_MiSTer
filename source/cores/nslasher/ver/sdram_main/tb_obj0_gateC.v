`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_obj0_gateC — GATE C for the nf24 SINGLE-FETCH obj0 repack.
//
//  CORRECTNESS + single-burst property, at the exact seam that garbled nf5:
//    DUT  = the on-disk jtnslasher_sdram.v (nf24 single-fetch FSM: read#1 planes
//           burst @ {nwi,0}, read#2 plane4 @ {nwi,1} = bcache DOUBLE-line HIT).
//    BA3  = the REAL jtframe_rom_1slot exactly as the regenerated
//           jtnslasher_game_sdram instantiates it: SDRAMW(23), SLOT0_AW(23),
//           SLOT0_DW(32), SLOT0_DOUBLE(1)  (JTFRAME_BA3_LEN=64 active).
//    plus real jtframe_sdram64 (BA3_LEN=64) + mt48lc16m16a2 loaded with the
//    GATE-B-CHAIN image (gen_objfold_gateC.py: REAL .mra -> big-endian mra2rom
//    -> dwnld word remap -> flat bytes). NOT a self-consistent model.
//
//  ASSERT: obj0_rom_data == golden (gfx3_spr contract) for ALL tile-halves,
//          AND read#2 is a cache HIT (<=4 clk) for ALL tile-halves (single
//          SDRAM burst per fetch — the whole point of the repack).
//  The unwritten slot words 4n+3 carry an 0xEEEE sentinel: any consumption of
//  them corrupts plane4 -> golden mismatch -> FAIL.
// =============================================================================
module tb_obj0_gateC;
    localparam SDRAMW=23;   // bank word-address width (matches the proven flat-preload mapping;
                            // the generated rom_1slot also gets SDRAMW=23 with SDRAM_LARGE)
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    // engine <-> adapter (obj0)
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    // adapter <-> BA3 slot
    wire        obj0_cs, obj1_cs;
    wire [21:0] obj0_addr;
    wire [17:0] obj1_addr;
    wire [31:0] obj0_data;
    wire        obj0_ok;

    // controller plumbing
    wire        rom_rd3;
    wire [SDRAMW-1:0] rom_saddr3;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd;
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    // ===== DUT: the REAL on-disk nf24 adapter (single-fetch FSM) =====
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
        .obj0_cs(obj0_cs), .obj0_addr(obj0_addr), .obj0_data(obj0_data), .obj0_ok(obj0_ok),
        .obj1_cs(obj1_cs), .obj1_addr(obj1_addr), .obj1_data(32'd0), .obj1_ok(1'b0)
    );

    // ===== REAL BA3: jtframe_rom_1slot exactly as the regenerated game_sdram wires it =====
    jtframe_rom_1slot #(
        .SDRAMW(SDRAMW),
        .SLOT0_AW(23), .SLOT0_DW(32),
        .SLOT0_DOUBLE(1)
    ) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data), .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rom_rd3), .sdram_addr(rom_saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    assign ba_rd = { rom_rd3, 3'b000 };

    jtframe_sdram64 #(
        .AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)
    ) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr({SDRAMW{1'b0}}), .ba2_addr({SDRAMW{1'b0}}), .ba3_addr(rom_saddr3),
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

    // ---- test vectors + GOLDEN (real engine cadence) ----
    reg [23:0] tv_addr [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin
        $readmemh("objfold_real_addr.hex", tv_addr);
        $readmemh("objfold_real_gold.hex", tv_gold);
    end

    // =========================================================================
    // faithful obj0 mini-engine: rom_cs / rom_good / consume, back-to-back.
    // ON EACH CONSUME EDGE: CAPTURE obj0_rom_data and COMPARE vs tv_gold[eng_i].
    // =========================================================================
    integer eng_i;
    reg     rom_good;
    reg     running, done;
    integer stall;
    reg     started;

    integer cs_cyc;
    integer lat_min, lat_max, lat_sum, lat_n;
    integer warm;

    integer chk_n, mism_n, blank_n, nonblank_ok;
    integer first_bad_i;
    reg [23:0] first_bad_addr;
    reg [39:0] first_bad_got, first_bad_exp;
    initial begin
        lat_min=999999; lat_max=0; lat_sum=0; lat_n=0; warm=0;
        chk_n=0; mism_n=0; blank_n=0; nonblank_ok=0; first_bad_i=-1;
    end

    localparam NMEAS = `OBJFOLD_N;   // check EVERY tile-half

    always @(posedge clk) begin
        if( rst ) begin
            eng_i<=0; obj0_rom_cs<=0; obj0_rom_addr<=0; rom_good<=0;
            running<=0; done<=0; started<=0; stall<=0; cs_cyc<=0;
        end else if( running && !done ) begin
            rom_good <= obj0_rom_cs & obj0_rom_ok;
            if( obj0_rom_cs ) cs_cyc <= cs_cyc + 1;
            if( obj0_rom_cs && !(obj0_rom_cs && rom_good && obj0_rom_ok) ) stall <= stall+1;

            if( obj0_rom_cs && rom_good && obj0_rom_ok ) begin
                chk_n <= chk_n + 1;
                if( obj0_rom_data !== tv_gold[eng_i] ) begin
                    mism_n <= mism_n + 1;
                    if( first_bad_i < 0 ) begin
                        first_bad_i    <= eng_i;
                        first_bad_addr <= tv_addr[eng_i];
                        first_bad_got  <= obj0_rom_data;
                        first_bad_exp  <= tv_gold[eng_i];
                    end
                    if( mism_n < 8 )
                        $display("  MISMATCH i=%0d engaddr=%06x  got=%010x  exp=%010x",
                                 eng_i, tv_addr[eng_i][20:0], obj0_rom_data, tv_gold[eng_i]);
                end else begin
                    if( tv_gold[eng_i]==40'd0 ) blank_n <= blank_n+1;
                    else                        nonblank_ok <= nonblank_ok+1;
                end

                warm <= warm + 1;
                if( warm >= 8 ) begin
                    if( cs_cyc < lat_min ) lat_min <= cs_cyc;
                    if( cs_cyc > lat_max ) lat_max <= cs_cyc;
                    lat_sum <= lat_sum + cs_cyc;
                    lat_n   <= lat_n + 1;
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
                    cs_cyc        <= 0;
                end
            end

            if( stall > 4000 ) begin
                $display("  STALL/HANG at i=%0d engaddr=%06x", eng_i, tv_addr[eng_i][20:0]);
                done <= 1;
            end
        end else if( started && !running ) begin
            running <= 1;
        end
    end

    // =========================================================================
    // read#2 (plane4) HIT/MISS classification by FSM state.
    //   o0st: O0_IDLE=0 O0_PL=1 O0_GAP=2 O0_P4=3 O0_DONE=4
    // The single-burst property REQUIRES every read#2 to be a cache HIT.
    // =========================================================================
    integer r2_min, r2_max, r2_sum, r2_n;
    integer r2_hit, r2_miss;
    integer t_p4cs;
    reg     seen_p4cs;
    reg [2:0] o0st_prev;
    initial begin
        r2_min=999999;r2_max=0;r2_sum=0;r2_n=0; r2_hit=0; r2_miss=0;
        seen_p4cs=0; o0st_prev=0;
    end
    always @(posedge clk) if(running && !done) begin
        o0st_prev <= u_dut.o0st;
        if( obj0_rom_cs && cs_cyc==0 ) seen_p4cs<=0;
        if( u_dut.o0st==3 && o0st_prev==2 && !seen_p4cs ) begin seen_p4cs<=1; t_p4cs<=cs_cyc; end
        if( u_dut.o0st==4 && o0st_prev==3 && seen_p4cs && warm>=8 ) begin
            r2_sum <= r2_sum + (cs_cyc - t_p4cs);
            r2_n   <= r2_n + 1;
            if( (cs_cyc-t_p4cs) < r2_min ) r2_min <= (cs_cyc-t_p4cs);
            if( (cs_cyc-t_p4cs) > r2_max ) r2_max <= (cs_cyc-t_p4cs);
            if( (cs_cyc-t_p4cs) <= 4 ) r2_hit <= r2_hit+1; else r2_miss <= r2_miss+1;
        end
    end

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_obj0_gateC: nf24 single-fetch FSM + REAL rom_1slot DOUBLE + sdram64 BA3_LEN=64 + mt48lc ---");
        $display("    image = GATE-B chain (.mra -> mra2rom -> dwnld remap); checking ALL %0d tile-halves", NMEAS);
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("CORRECTNESS:");
        $display("  checked          = %0d tile-halves", chk_n);
        $display("  MISMATCHES       = %0d", mism_n);
        $display("  blank-ok         = %0d", blank_n);
        $display("  nonblank-ok      = %0d", nonblank_ok);
        if( first_bad_i >= 0 )
            $display("  first bad: i=%0d addr=%06x got=%010x exp=%010x",
                     first_bad_i, first_bad_addr[20:0], first_bad_got, first_bad_exp);
        $display("LATENCY (per-tile-half rom_cs->rom_ok over %0d warm halves):", lat_n);
        $display("  min=%0d  max=%0d  mean=%0d clk", lat_min, lat_max, (lat_n>0)?(lat_sum/lat_n):0);
        $display("  read#2 (plane4): min=%0d max=%0d mean=%0d clk  HIT(<=4)=%0d  MISS=%0d  (n=%0d)",
                 r2_min, r2_max, (r2_n>0)?(r2_sum/r2_n):0, r2_hit, r2_miss, r2_n);
        if( mism_n==0 && chk_n==NMEAS && r2_miss==0 )
            $display("VERDICT: PASS  (all %0d tile-halves byte-exact; %0d non-blank; read#2 HIT for all %0d)",
                     chk_n, nonblank_ok, r2_n);
        else
            $display("VERDICT: FAIL  (%0d mismatches / %0d checked ; read#2 misses=%0d)", mism_n, chk_n, r2_miss);
        $display("==================================================");
        $finish;
    end
    initial begin #1500_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
