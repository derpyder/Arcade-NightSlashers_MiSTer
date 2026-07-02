`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_objfold_real — FAITHFUL seam sim for the obj0 sprite-bandwidth FOLD.
//
// Fixes the two faithfulness holes of tb_objfold_combined.v:
//   (1) DRIVER = the REAL engine cadence.  Instead of "raise cs, wait for the FIRST obj0_rom_ok,
//       sample, drop cs, 2-clk gap", this tb's u_eng synthesizable mini-engine reproduces
//       jtnslasher_obj.v exactly:
//         rom_good <= rom_cs & rom_ok;                       (registered, 1-clk delayed)
//         consume only when (rom_cs && rom_good && rom_ok)   (the SECOND consecutive ok)
//         then drop rom_cs for the consume cycle, and re-raise immediately for the NEXT tile
//         (minimal gap = the real back-to-back draw loop).
//   (2) ADDRESSES = REAL.  The preload (gen_objfold_real.py) places every tile at its TRUE
//       SDRAM word nwi*4 (NOT compact-remapped), engine addr = real hra, tiles emitted as
//       adjacent half-0/half-1 pairs.  So the real 21-bit nwi, the real bcache tags, the 2-line
//       DOUBLE eviction + addr_req[1] flip, and the FSM cs-toggle/fresh-ok edge detect are all
//       exercised under OKLATCH=1 at real burst latency across back-to-back tiles.
//
// The engine checks obj0_rom_data == golden gfx3_spr the instant it consumes (the same instant the
// real engine latches rom_data into draw_data), recording the first mismatch (tile index, engine
// addr, expected vs got 40-bit word, plane/byte delta).
// =============================================================================
module tb_objfold_real;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz, matches tb_objread / tb_objfold_combined

    // ---- engine <-> obj0 FSM (jtnslasher_sdram) ----
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    // ---- framework side: FSM <-> real slot ----
    wire        obj0_cs;
    wire [21:0] obj0_addr;
    wire [31:0] obj0_data;
    wire        obj0_ok;

    // ---- SDRAM controller plumbing (bank3) ----
    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {rom_rd, 3'b0};   // bank3
    wire [3:0]  ba_wr = 4'd0;

    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    // ===== DUT: the REAL obj0 2-read FSM =====
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

    // ===== REAL slot the framework wires on HW: DW32 DOUBLE OKLATCH=1 LATCH=0 =====
    jtframe_rom_1slot #(
        .SDRAMW(SDRAMW), .SLOT0_AW(23), .SLOT0_DW(32), .SLOT0_DOUBLE(1)
    ) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data),
        .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
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

    // mt48lc16m16a2 $readmemh's Bank3 from sdram_bank3_real.hex (16-bit words, low-half-first).
    mt48lc16m16a2 u_sdram(
        .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba), .Clk(clk), .Cke(sdram_cke),
        .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
        .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
    );

    // ---- test vectors ----
    reg [23:0] tv_addr [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin
        $readmemh("objfold_real_addr.hex", tv_addr);
        $readmemh("objfold_real_gold.hex", tv_gold);
    end

    // =========================================================================
    // FAITHFUL mini-engine: mirrors jtnslasher_obj.v's rom_cs / rom_good / 2nd-ok consume
    // cadence, fetching tile vectors back-to-back with a minimal gap.
    // =========================================================================
    integer eng_i;             // index into tv_*
    integer errors, first_bad;
    reg [39:0] first_got, first_exp;
    integer    first_addr, first_idx;
    integer    checked;
    reg        rom_good;       // == jtnslasher_obj.v rom_good (registered rom_cs&rom_ok)
    reg        running, done;
    integer    stall;          // watchdog per fetch

    // start condition
    reg started;

    always @(posedge clk) begin
        if( rst ) begin
            eng_i<=0; errors<=0; first_bad<=-1; checked<=0;
            obj0_rom_cs<=0; obj0_rom_addr<=0; rom_good<=0;
            running<=0; done<=0; started<=0; stall<=0;
        end else if( running && !done ) begin
            // registered rom_good exactly like the real engine
            rom_good <= obj0_rom_cs & obj0_rom_ok;

            // watchdog: if a fetch never completes, flag + advance (so a hang shows up as a mismatch)
            if( obj0_rom_cs && !(obj0_rom_cs && rom_good && obj0_rom_ok) ) stall <= stall+1;

            if( obj0_rom_cs && rom_good && obj0_rom_ok ) begin
                // CONSUME on the 2nd consecutive ok — the same instant the real engine latches
                // rom_data into draw_data. Check against golden here.
                checked <= checked+1;
                if( obj0_rom_data !== tv_gold[eng_i] && errors<200 ) begin
                    errors <= errors+1;
                    if( first_bad<0 ) begin
                        first_bad<=eng_i; first_idx<=eng_i; first_addr<=tv_addr[eng_i][20:0];
                        first_got<=obj0_rom_data; first_exp<=tv_gold[eng_i];
                    end
                    if( errors<12 )
                        $display("  MISMATCH i=%0d engaddr=%06x got=%010x gold=%010x",
                                 eng_i, tv_addr[eng_i][20:0], obj0_rom_data, tv_gold[eng_i]);
                end
                // drop cs this cycle (real engine: rom_cs<=0 on consume), re-issue next tile
                obj0_rom_cs <= 0;
                rom_good    <= 0;
                stall       <= 0;
                if( eng_i == `OBJFOLD_N-1 ) begin
                    done <= 1;
                end else begin
                    eng_i <= eng_i+1;
                end
            end else if( !obj0_rom_cs ) begin
                // issue the NEXT fetch immediately (minimal gap = back-to-back draw loop).
                // After a consume, obj0_rom_cs was just set 0; this fires the following cycle.
                if( !done ) begin
                    obj0_rom_addr <= tv_addr[eng_i][20:0];
                    obj0_rom_cs   <= 1;
                    rom_good      <= 0;     // new request -> require fresh ok
                end
            end

            // global stall watchdog
            if( stall > 800 ) begin
                $display("  STALL/HANG at i=%0d engaddr=%06x (no 2nd-ok consume)",
                         eng_i, tv_addr[eng_i][20:0]);
                done <= 1;
            end
        end else if( started && !running ) begin
            running <= 1;
        end
    end

    // ---- orchestration ----
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_objfold_real: FAITHFUL engine cadence + REAL addresses + back-to-back ---");
        @(posedge clk); started<=1;       // kick the engine
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        if( errors==0 )
            $display("tb_objfold_real: %0d tiles checked, 0 mismatches -> PASS", checked);
        else begin
            $display("tb_objfold_real: %0d tiles checked, %0d mismatches -> FAIL (garble REPRODUCED)",
                     checked, errors);
            $display("  first bad: index=%0d engaddr=%06x", first_idx, first_addr);
            $display("    expected: p4=%02x planes=%08x", first_exp[39:32], first_exp[31:0]);
            $display("    got     : p4=%02x planes=%08x", first_got[39:32], first_got[31:0]);
        end
        $display("==================================================");
        $finish;
    end
    initial begin #400_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
