`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_obj0_lat_realfold — MEASURE the per-tile-half rom_cs->rom_ok latency of the
// REAL IMPLEMENTED obj0 DENSE-FOLD 2-read FSM on REAL SDRAM.
//
// DUT = the ACTUAL committed jtnslasher_sdram.v (single obj0 DW32 port +
//   O0_IDLE->PL->GAP->P4->DONE 2-read FSM) + jtframe_rom_2slots BA3
//   (SLOT0=obj0 DW32 DOUBLE, SLOT1=obj1 DW32 DOUBLE) wired EXACTLY as the
//   committed mister/jtnslasher_game_sdram.v u_bank3 + jtframe_sdram64 + mt48lc16m16a2.
//
// A faithful mini-engine mirrors jtnslasher_obj.v's rom_cs / rom_good / 2nd-ok
// consume cadence and fetches tile-halves back-to-back at REAL engine addresses
// (objfold_real_addr.hex). For each tile-half we TIME rom_cs-rise -> consume edge
// (rom_cs && rom_good && rom_ok) = the engine-observable latency for the WHOLE
// 2-read FSM (read#1 planes burst + read#2 plane4 word).
//
// Two probes inside the FSM:
//   (A) plane4 cache HIT vs MISS: time from the O0_GAP->O0_P4 re-request to the
//       obj0_ok that completes read#2. If read#2 is a cache HIT in the just-burst
//       DOUBLE line it returns in ~1-2 clk; a fresh burst (different DOUBLE line)
//       takes ~ the full burst latency (~11-13 clk).
//   (B) split: read#1 latency (cs-rise -> O0_GAP) vs read#2 latency (O0_GAP -> DONE).
//
// Contention: optional injected BA1(CPU) + BA2(PF) traffic via simple slot drivers
// so we see how BA3 obj0 latency degrades when the controller round-robins banks.
// -DCONTEND enables it.
// =============================================================================
module tb_obj0_lat_realfold;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    // engine <-> adapter (obj0)
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    // adapter <-> BA3 slots
    wire        obj0_cs, obj1_cs;
    wire [21:0] obj0_addr;     // adapter drives obj0_addr (22-bit word, nf5 8-byte-slot / SDRAM_LARGE)
    wire [17:0] obj1_addr;
    wire [31:0] obj0_data, obj1_data;
    wire        obj0_ok, obj1_ok;

    // controller plumbing
    wire        rom_rd3;
    wire [SDRAMW-1:0] rom_saddr3;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [SDRAMW-1:0] ba0_addr, ba1_addr, ba2_addr;
    wire [3:0]  ba_rd;
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    // ===== DUT: the REAL implemented fold adapter (single obj0 port + 2-read FSM) =====
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
        .obj1_cs(obj1_cs), .obj1_addr(obj1_addr), .obj1_data(obj1_data), .obj1_ok(obj1_ok)
    );

    // ===== REAL BA3: jtframe_rom_2slots (obj0 DW32 DOUBLE + obj1 DW32 DOUBLE) =====
    // Mirrors committed mister/jtnslasher_game_sdram.v u_bank3 exactly.
    localparam [SDRAMW-2:0] GFX4_OFFSET = 22'h19_0000; // BA3-rel obj1 base (>>1, word space); value irrelevant for obj0 timing
    jtframe_rom_2slots #(
        .SDRAMW(SDRAMW-1),
        .SLOT0_AW(22), .SLOT0_DW(32),
        .SLOT1_OFFSET(GFX4_OFFSET), .SLOT1_AW(19), .SLOT1_DW(32),
        .SLOT0_DOUBLE(1), .SLOT1_DOUBLE(1)
    ) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data), .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .slot1_addr({obj1_addr, 1'b0}), .slot1_dout(obj1_data), .slot1_cs(obj1_cs), .slot1_ok(obj1_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rom_rd3), .sdram_addr(rom_saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    // ===== optional contention: BA1 (CPU/main) + BA2 (PF) traffic ============
    // CPU model: a single DW32 main slot reading scattered addresses, always pending.
    reg         cpu_cs=0;  reg [18:0] cpu_addr=0;  wire cpu_ok; wire [31:0] cpu_data;
    wire        rom_rd1;   wire [SDRAMW-1:0] rom_saddr1;
    jtframe_rom_1slot #(.SDRAMW(SDRAMW-1), .SLOT0_AW(19), .SLOT0_DW(32), .SLOT0_DOUBLE(1)
    ) u_bank1 (
        .rst(rst), .clk(clk),
        .slot0_addr({cpu_addr,1'b0}), .slot0_dout(cpu_data), .slot0_cs(cpu_cs), .slot0_ok(cpu_ok),
        .sdram_ack(ba_ack[1]), .sdram_rd(rom_rd1), .sdram_addr(rom_saddr1),
        .data_dst(ba_dst[1]), .data_rdy(ba_rdy[1]), .data_read(dout)
    );
    // PF model: a single DW16 gfx slot, always pending (BA2).
    reg         pf_cs=0;   reg [19:0] pf_addr=0;   wire pf_ok; wire [15:0] pf_data;
    wire        rom_rd2;   wire [SDRAMW-1:0] rom_saddr2;
    jtframe_rom_1slot #(.SDRAMW(SDRAMW-1), .SLOT0_AW(20), .SLOT0_DW(16), .SLOT0_DOUBLE(1)
    ) u_bank2 (
        .rst(rst), .clk(clk),
        .slot0_addr(pf_addr), .slot0_dout(pf_data), .slot0_cs(pf_cs), .slot0_ok(pf_ok),
        .sdram_ack(ba_ack[2]), .sdram_rd(rom_rd2), .sdram_addr(rom_saddr2),
        .data_dst(ba_dst[2]), .data_rdy(ba_rdy[2]), .data_read(dout)
    );

    assign ba_rd = { rom_rd3, rom_rd2, rom_rd1, 1'b0 };

    jtframe_sdram64 #(
        .AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)
    ) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr(rom_saddr1), .ba2_addr(rom_saddr2), .ba3_addr(rom_saddr3),
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

    // ---- test vectors (real engine-cadence addresses) ----
    reg [23:0] tv_addr [0:8191];
    initial $readmemh("objfold_real_addr.hex", tv_addr);

    // =========================================================================
    // faithful obj0 mini-engine: rom_cs / rom_good / 2nd-ok consume, back-to-back
    // =========================================================================
    integer eng_i;
    reg     rom_good;
    reg     running, done;
    integer stall;
    reg     started;

    integer cs_cyc;                 // cycles since this tile-half's rom_cs rose
    integer lat_min, lat_max, lat_sum, lat_n;
    integer lat_hist [0:127];
    integer warm, hi;
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
                warm <= warm + 1;
                if( warm >= 8 ) begin
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
    // PROBE A/B: split read#1 (planes burst) vs read#2 (plane4) latency, and
    // classify read#2 as cache HIT or fresh burst, by watching the FSM state.
    // o0st: O0_IDLE=0 O0_PL=1 O0_GAP=2 O0_P4=3 O0_DONE=4
    // =========================================================================
    integer r1_min, r1_max, r1_sum, r1_n;     // read#1: cs-rise -> enter GAP
    integer r2_min, r2_max, r2_sum, r2_n;     // read#2: leave GAP(cs re-raised) -> DONE
    integer r2_hit, r2_miss;                  // <=3 clk = hit ; else fresh burst
    integer t_csrise, t_gap, t_p4cs;
    reg     seen_gap, seen_p4cs;
    reg [2:0] o0st_prev;
    initial begin
        r1_min=999999;r1_max=0;r1_sum=0;r1_n=0;
        r2_min=999999;r2_max=0;r2_sum=0;r2_n=0; r2_hit=0; r2_miss=0;
        seen_gap=0; seen_p4cs=0; o0st_prev=0;
    end
    always @(posedge clk) if(running && !done) begin
        o0st_prev <= u_dut.o0st;
        // mark cs-rise of a fresh tile-half
        if( obj0_rom_cs && cs_cyc==0 ) begin t_csrise<=0; seen_gap<=0; seen_p4cs<=0; end
        // read#1 done = FSM enters O0_GAP (planes latched)
        if( u_dut.o0st==2 && o0st_prev==1 && !seen_gap && warm>=8 ) begin
            seen_gap<=1; t_gap<=cs_cyc;
            if(cs_cyc<r1_min) r1_min<=cs_cyc; if(cs_cyc>r1_max) r1_max<=cs_cyc;
            r1_sum<=r1_sum+cs_cyc; r1_n<=r1_n+1;
        end
        // read#2 cs re-raised in O0_GAP -> measure to O0_DONE
        if( u_dut.o0st==3 && o0st_prev==2 && !seen_p4cs ) begin seen_p4cs<=1; t_p4cs<=cs_cyc; end
        if( u_dut.o0st==4 && o0st_prev==3 && seen_p4cs && warm>=8 ) begin
            // read#2 latency = (cs_cyc at DONE) - (cs_cyc when P4 cs re-raised)
            r2_sum <= r2_sum + (cs_cyc - t_p4cs);
            r2_n   <= r2_n + 1;
            if( (cs_cyc-t_p4cs) < r2_min ) r2_min <= (cs_cyc-t_p4cs);
            if( (cs_cyc-t_p4cs) > r2_max ) r2_max <= (cs_cyc-t_p4cs);
            if( (cs_cyc-t_p4cs) <= 4 ) r2_hit <= r2_hit+1; else r2_miss <= r2_miss+1;
        end
    end

    // =========================================================================
    // CONTENTION drivers: keep BA1 (CPU) + BA2 (PF) always requesting so the
    // controller has to interleave them with BA3 obj0 bursts. Also measure the
    // CPU(BA1) access latency (cpu_cs-rise -> cpu_ok) to see starvation.
    // =========================================================================
    integer cpu_cyc, cpu_lat_sum, cpu_lat_n, cpu_lat_min, cpu_lat_max;
    reg     cpu_good;
    integer cpu_seed;
    initial begin cpu_lat_sum=0; cpu_lat_n=0; cpu_lat_min=999999; cpu_lat_max=0; cpu_seed=1; end
`ifdef CONTEND
    always @(posedge clk) begin
        if(rst) begin cpu_cs<=0; cpu_addr<=0; cpu_cyc<=0; cpu_good<=0; pf_cs<=0; pf_addr<=0; end
        else if(running && !done) begin
            // --- CPU(BA1) ---
            if( cpu_cs ) cpu_cyc <= cpu_cyc+1;
            if( cpu_cs && cpu_ok ) begin
                if(warm>=8) begin
                    cpu_lat_sum<=cpu_lat_sum+cpu_cyc; cpu_lat_n<=cpu_lat_n+1;
                    if(cpu_cyc<cpu_lat_min) cpu_lat_min<=cpu_cyc;
                    if(cpu_cyc>cpu_lat_max) cpu_lat_max<=cpu_cyc;
                end
                cpu_cs<=0;
            end else if( !cpu_cs ) begin
                cpu_seed <= cpu_seed*1103515245 + 12345;
                cpu_addr <= cpu_seed[18:0];     // scattered -> row miss each time
                cpu_cs   <= 1;
                cpu_cyc  <= 0;
            end
            // --- PF(BA2) ---
            if( pf_cs && pf_ok ) begin
                pf_addr <= pf_addr + 20'h137;   // strided
                // keep requesting (drop+raise handled by leaving cs high; re-issue)
                pf_cs   <= 1;
            end else if( !pf_cs ) pf_cs <= 1;
        end
    end
`endif

    integer k;
    initial begin
        pf_cs=0; pf_addr=0; cpu_cs=0; cpu_addr=0;
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
`ifdef CONTEND
        $display("--- tb_obj0_lat_realfold: REAL 2-read FOLD + BA1(CPU)+BA2(PF) CONTENTION ---");
`else
        $display("--- tb_obj0_lat_realfold: REAL 2-read FOLD, BA3 IDLE (no contention) ---");
`endif
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("REAL FOLD obj0 per-tile-half rom_cs->rom_ok latency over %0d halves:", lat_n);
        $display("  min=%0d  max=%0d  mean=%0d clk", lat_min, lat_max, (lat_n>0)?(lat_sum/lat_n):0);
        $display("  read#1 (planes burst): min=%0d max=%0d mean=%0d clk  (n=%0d)",
                 r1_min, r1_max, (r1_n>0)?(r1_sum/r1_n):0, r1_n);
        $display("  read#2 (plane4):       min=%0d max=%0d mean=%0d clk  (n=%0d)",
                 r2_min, r2_max, (r2_n>0)?(r2_sum/r2_n):0, r2_n);
        $display("  read#2 classification: HIT(<=4clk)=%0d  MISS(fresh burst)=%0d", r2_hit, r2_miss);
        $display("  histogram (lat clk : count):");
        for(k=0;k<128;k=k+1) if(lat_hist[k]>0) $display("    %3d : %0d", k, lat_hist[k]);
`ifdef CONTEND
        $display("  --- CPU(BA1) access latency under obj0 fold load ---");
        $display("    min=%0d max=%0d mean=%0d clk  (n=%0d)",
                 cpu_lat_min, cpu_lat_max, (cpu_lat_n>0)?(cpu_lat_sum/cpu_lat_n):0, cpu_lat_n);
`endif
        $display("==================================================");
        $finish;
    end
    initial begin #1500_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
