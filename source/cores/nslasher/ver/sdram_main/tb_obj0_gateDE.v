`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_obj0_gateDE — GATES D + E for the nf24 SINGLE-FETCH obj0 repack.
//
//  GATE D (integrity): the full obj0 chain (nf24 FSM + rom_1slot DW32-DOUBLE +
//    sdram64 BA3_LEN=64 + mt48lc, GATE-B-chain image) stays BYTE-EXACT and
//    keeps the read#2 cache-HIT property while the OTHER THREE BANKS carry
//    realistic traffic and refresh pulses re-phase every burst:
//      BA1: CPU-ish 32-bit client (~1 req / 400 clk: nf6 ARM cache ~99.9% hit +
//           BRAM work RAM leave BA1 nearly idle; snd/oki are slower still)
//      BA2: 4x 16-bit tilemap clients (~1 burst / 150 clk each, staggered =
//           the real ~20 bursts/line/PF with LFSR all-miss addresses) + the
//           RELOCATED obj1 32-bit client (~1 req / 30 clk = heavy combat)
//      rfsh pulse every 375 clk (the real 8192-rows/64ms average; on MiSTer
//           refresh is HBlank-bursty so active-line rate is LOWER -> conservative)
//      bank LENs = the REAL nf24 config: BA0/1/2=32, BA3=64 (JTFRAME_BA3_LEN)
//    A DOUBLE-line tear (beat0/1 from one burst, beat2/3 from another) or a
//    stale-line hit under re-phased latency would corrupt plane4 or planes ->
//    golden mismatch -> FAIL.
//
//  GATE E (latency): per-fetch rom_cs->rom_ok latency stats under the same
//    contention. Budget: sustained <=~22 clk/fetch keeps a 70-sprite line in
//    budget; the nf20 pipelined engine absorbs spikes to ~19 clk of steady
//    LAT. Report mean/max + counts >22 / >27. (nf23 dense 2-read measured
//    46-66 clk on HW in heavy combat = the comb.)
//    Also measures obj1's latency in its NEW home (BA2 slot4, competing with
//    the 4 PF clients) — informational, obj1 data path itself is unchanged.
// =============================================================================
module tb_obj0_gateDE;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    // ---- obj0 engine <-> adapter ----
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    wire        obj0_cs;
    wire [21:0] obj0_addr;
    wire [31:0] obj0_data;
    wire        obj0_ok;

    // ---- controller plumbing ----
    wire        rd1, rd2, rd3;
    wire [SDRAMW-1:0] saddr1, saddr2, saddr3;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = { rd3, rd2, rd1, 1'b0 };
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    // ===== DUT: the REAL on-disk nf24 adapter =====
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
        .obj1_cs(), .obj1_addr(), .obj1_data(32'd0), .obj1_ok(1'b0)
    );

    // ===== BA3: obj0 rom_1slot exactly as generated =====
    jtframe_rom_1slot #(.SDRAMW(SDRAMW), .SLOT0_AW(23), .SLOT0_DW(32), .SLOT0_DOUBLE(1)) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data),
        .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rd3), .sdram_addr(saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    // ===== BA1: CPU-ish traffic (32-bit client, LFSR addresses, ~1 req / 60 clk) =====
    reg         cpu_cs=0;
    reg  [19:0] cpu_addr=0;
    wire [31:0] cpu_dout;
    wire        cpu_ok;
    jtframe_rom_1slot #(.SDRAMW(SDRAMW), .SLOT0_AW(20), .SLOT0_DW(32)) u_bank1 (
        .rst(rst), .clk(clk),
        .slot0_addr(cpu_addr), .slot0_dout(cpu_dout),
        .slot0_cs(cpu_cs), .slot0_ok(cpu_ok),
        .sdram_ack(ba_ack[1]), .sdram_rd(rd1), .sdram_addr(saddr1),
        .data_dst(ba_dst[1]), .data_rdy(ba_rdy[1]), .data_read(dout)
    );
    reg [15:0] lfsr_c=16'hACE1;
    reg [ 8:0] cpu_cnt=0;
    wire en = ~init & ~rst;
    always @(posedge clk) begin
        if(!en) begin cpu_cs<=0; cpu_cnt<=0; end
        else begin
            lfsr_c <= {lfsr_c[14:0], lfsr_c[15]^lfsr_c[13]^lfsr_c[12]^lfsr_c[10]};
            if( cpu_cs && cpu_ok ) begin cpu_cs<=0; cpu_cnt<=0; end
            else if( !cpu_cs ) begin
                cpu_cnt <= cpu_cnt+9'd1;
                if( cpu_cnt>=9'd400 ) begin
                    cpu_addr <= {lfsr_c[15:0], lfsr_c[5:2]};  // 20-bit walk
                    cpu_cs   <= 1;
                end
            end
        end
    end

    // ===== BA2: 4x PF 16-bit clients (staggered) + obj1 32-bit client =====
    reg        pf_cs [0:3];
    reg [19:0] pf_addr [0:3];
    wire       pf_ok [0:3];
    wire [15:0] pf0_d, pf1_d, pf2_d, pf3_d;
    reg        o1_cs=0;
    reg [17:0] o1_addr=0;
    wire [31:0] o1_dout;
    wire        o1_ok;
    jtframe_rom_5slots #(
        .SDRAMW(SDRAMW),
        .SLOT0_AW(20), .SLOT0_DW(16),
        .SLOT1_AW(20), .SLOT1_DW(16),
        .SLOT2_AW(20), .SLOT2_DW(16),
        .SLOT3_AW(20), .SLOT3_DW(16),
        .SLOT4_AW(19), .SLOT4_DW(32)
    ) u_bank2 (
        .rst(rst), .clk(clk),
        .slot0_addr(pf_addr[0]), .slot0_dout(pf0_d), .slot0_cs(pf_cs[0]), .slot0_ok(pf_ok[0]),
        .slot1_addr(pf_addr[1]), .slot1_dout(pf1_d), .slot1_cs(pf_cs[1]), .slot1_ok(pf_ok[1]),
        .slot2_addr(pf_addr[2]), .slot2_dout(pf2_d), .slot2_cs(pf_cs[2]), .slot2_ok(pf_ok[2]),
        .slot3_addr(pf_addr[3]), .slot3_dout(pf3_d), .slot3_cs(pf_cs[3]), .slot3_ok(pf_ok[3]),
        .slot4_addr({o1_addr, 1'b0}), .slot4_dout(o1_dout), .slot4_cs(o1_cs), .slot4_ok(o1_ok),
        .sdram_ack(ba_ack[2]), .sdram_rd(rd2), .sdram_addr(saddr2),
        .data_dst(ba_dst[2]), .data_rdy(ba_rdy[2]), .data_read(dout)
    );
    reg [15:0] lfsr_p=16'hBEEF;
    reg [ 8:0] pf_cnt [0:3];
    integer pi;
    initial for(pi=0;pi<4;pi=pi+1) begin pf_cs[pi]=0; pf_addr[pi]=0; pf_cnt[pi]=9'd0; end
    always @(posedge clk) begin
        if(!en) for(pi=0;pi<4;pi=pi+1) begin pf_cs[pi]<=0; pf_cnt[pi]<=37*pi[8:0]; end
        else begin
            lfsr_p <= {lfsr_p[14:0], lfsr_p[15]^lfsr_p[13]^lfsr_p[12]^lfsr_p[10]};
            for(pi=0;pi<4;pi=pi+1) begin
                if( pf_cs[pi] && pf_ok[pi] ) begin pf_cs[pi]<=0; pf_cnt[pi]<=0; end
                else if( !pf_cs[pi] ) begin
                    pf_cnt[pi] <= pf_cnt[pi]+9'd1;
                    if( pf_cnt[pi]>=9'd150 ) begin
                        pf_addr[pi] <= {lfsr_p[13:0], pi[1:0], lfsr_p[5:2]};
                        pf_cs[pi]   <= 1;
                    end
                end
            end
        end
    end
    // obj1 client (~1 req / 30 clk) + latency stats in its new BA2 home
    reg [15:0] lfsr_o=16'hC0DE;
    reg [ 7:0] o1_cnt=0;
    integer o1lat, o1lat_min, o1lat_max, o1lat_sum, o1lat_n;
    initial begin o1lat_min=999999; o1lat_max=0; o1lat_sum=0; o1lat_n=0; end
    always @(posedge clk) begin
        if(!en) begin o1_cs<=0; o1_cnt<=0; o1lat<=0; end
        else begin
            lfsr_o <= {lfsr_o[14:0], lfsr_o[15]^lfsr_o[13]^lfsr_o[12]^lfsr_o[10]};
            if( o1_cs ) o1lat <= o1lat+1;
            if( o1_cs && o1_ok ) begin
                o1_cs<=0; o1_cnt<=0;
                if( o1lat < o1lat_min ) o1lat_min <= o1lat;
                if( o1lat > o1lat_max ) o1lat_max <= o1lat;
                o1lat_sum <= o1lat_sum + o1lat;
                o1lat_n   <= o1lat_n + 1;
            end else if( !o1_cs ) begin
                o1_cnt <= o1_cnt+8'd1;
                if( o1_cnt>=8'd30 ) begin
                    o1_addr <= {lfsr_o[13:0], lfsr_o[9:6]};
                    o1_cs   <= 1;
                    o1lat   <= 0;
                end
            end
        end
    end

    // ---- refresh pulses (the real 8192-rows/64ms average = 1 per ~375 clk @48MHz) ----
    reg [8:0] rfsh_cnt=0;
    reg       rfsh_pulse=0;
    always @(posedge clk) begin
        if(!en) begin rfsh_cnt<=0; rfsh_pulse<=0; end
        else begin
            rfsh_cnt   <= (rfsh_cnt==9'd374) ? 9'd0 : rfsh_cnt + 9'd1;
            rfsh_pulse <= (rfsh_cnt==9'd373);
        end
    end

    // bank LENs = the REAL nf24 config (BA0/1/2 default 32, BA3_LEN=64)
    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(32), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(64)) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr(saddr1), .ba2_addr(saddr2), .ba3_addr(saddr3),
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

    // ---- vectors + golden ----
    reg [23:0] tv_addr [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin
        $readmemh("objfold_real_addr.hex", tv_addr);
        $readmemh("objfold_real_gold.hex", tv_gold);
    end

    // ---- faithful obj0 mini-engine, LOOPING the vector set 4x for statistics ----
    localparam NMEAS = `OBJFOLD_N;
    localparam LOOPS = 4;
    integer eng_i, loop_i;
    reg     rom_good;
    reg     running, done;
    integer stall;
    reg     started;

    integer cs_cyc;
    integer lat_min, lat_max, lat_sum, lat_n, lat_gt22, lat_gt27;
    integer warm;
    integer chk_n, mism_n;
    integer first_bad_i;
    initial begin
        lat_min=999999; lat_max=0; lat_sum=0; lat_n=0; warm=0; lat_gt22=0; lat_gt27=0;
        chk_n=0; mism_n=0; first_bad_i=-1;
    end

    always @(posedge clk) begin
        if( rst ) begin
            eng_i<=0; loop_i<=0; obj0_rom_cs<=0; obj0_rom_addr<=0; rom_good<=0;
            running<=0; done<=0; started<=0; stall<=0; cs_cyc<=0;
        end else if( running && !done ) begin
            rom_good <= obj0_rom_cs & obj0_rom_ok;
            if( obj0_rom_cs ) cs_cyc <= cs_cyc + 1;
            if( obj0_rom_cs && !(obj0_rom_cs && rom_good && obj0_rom_ok) ) stall <= stall+1;

            if( obj0_rom_cs && rom_good && obj0_rom_ok ) begin
                chk_n <= chk_n + 1;
                if( obj0_rom_data !== tv_gold[eng_i] ) begin
                    mism_n <= mism_n + 1;
                    if( first_bad_i < 0 ) first_bad_i <= eng_i;
                    if( mism_n < 8 )
                        $display("  MISMATCH loop=%0d i=%0d engaddr=%06x  got=%010x  exp=%010x",
                                 loop_i, eng_i, tv_addr[eng_i][20:0], obj0_rom_data, tv_gold[eng_i]);
                end
                warm <= warm + 1;
                if( warm >= 8 ) begin
                    if( cs_cyc < lat_min ) lat_min <= cs_cyc;
                    if( cs_cyc > lat_max ) lat_max <= cs_cyc;
                    if( cs_cyc > 22 ) lat_gt22 <= lat_gt22 + 1;
                    if( cs_cyc > 27 ) lat_gt27 <= lat_gt27 + 1;
                    lat_sum <= lat_sum + cs_cyc;
                    lat_n   <= lat_n + 1;
                end
                obj0_rom_cs <= 0;
                rom_good    <= 0;
                stall       <= 0;
                if( eng_i == NMEAS-1 ) begin
                    eng_i <= 0;
                    if( loop_i == LOOPS-1 ) done <= 1;
                    else loop_i <= loop_i + 1;
                end else eng_i <= eng_i+1;
            end else if( !obj0_rom_cs ) begin
                if( !done ) begin
                    obj0_rom_addr <= tv_addr[eng_i][20:0];
                    obj0_rom_cs   <= 1;
                    rom_good      <= 0;
                    cs_cyc        <= 0;
                end
            end

            if( stall > 4000 ) begin
                $display("  STALL/HANG loop=%0d i=%0d engaddr=%06x", loop_i, eng_i, tv_addr[eng_i][20:0]);
                done <= 1;
            end
        end else if( started && !running ) begin
            running <= 1;
        end
    end

    // ---- read#2 HIT/MISS (o0st: IDLE=0 PL=1 GAP=2 P4=3 DONE=4) ----
    integer r2_hit, r2_miss;
    integer t_p4cs;
    reg     seen_p4cs;
    reg [2:0] o0st_prev;
    initial begin r2_hit=0; r2_miss=0; seen_p4cs=0; o0st_prev=0; end
    always @(posedge clk) if(running && !done) begin
        o0st_prev <= u_dut.o0st;
        if( obj0_rom_cs && cs_cyc==0 ) seen_p4cs<=0;
        if( u_dut.o0st==3 && o0st_prev==2 && !seen_p4cs ) begin seen_p4cs<=1; t_p4cs<=cs_cyc; end
        if( u_dut.o0st==4 && o0st_prev==3 && seen_p4cs && warm>=8 ) begin
            if( (cs_cyc-t_p4cs) <= 4 ) r2_hit <= r2_hit+1; else r2_miss <= r2_miss+1;
        end
    end

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_obj0_gateDE: nf24 chain under BA1+BA2 traffic + refresh (loops=%0d x %0d halves) ---",
                 LOOPS, NMEAS);
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("GATE D (integrity under contention):");
        $display("  checked=%0d  MISMATCHES=%0d  read#2 HIT=%0d MISS=%0d", chk_n, mism_n, r2_hit, r2_miss);
        $display("GATE E (obj0 latency under contention, %0d warm fetches):", lat_n);
        $display("  min=%0d  mean=%0d  max=%0d clk   >22clk: %0d (%0d%%)   >27clk: %0d (%0d%%)",
                 lat_min, (lat_n>0)?(lat_sum/lat_n):0, lat_max,
                 lat_gt22, (lat_n>0)?(100*lat_gt22/lat_n):0,
                 lat_gt27, (lat_n>0)?(100*lat_gt27/lat_n):0);
        $display("  obj1 in BA2 (informational): min=%0d mean=%0d max=%0d clk (n=%0d)",
                 o1lat_min, (o1lat_n>0)?(o1lat_sum/o1lat_n):0, o1lat_max, o1lat_n);
        if( mism_n==0 && r2_miss==0 && (lat_sum/lat_n)<=27 )
            $display("VERDICT: PASS  (byte-exact + all-HIT under contention; mean latency %0d <= 27)",
                     lat_sum/lat_n);
        else
            $display("VERDICT: FAIL  (mism=%0d r2_miss=%0d mean_lat=%0d)", mism_n, r2_miss,
                     (lat_n>0)?(lat_sum/lat_n):0);
        $display("==================================================");
        $finish;
    end
    initial begin #3000_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
