`timescale 1ns/1ps
`include "objfold_combined_n.vh"
// =============================================================================
// tb_objfold_combined — THE DECISIVE SEAM SIM for the obj0 sprite-bandwidth FOLD.
//
// The two pre-existing sims each tested ONE side of the seam and PASSED:
//   * tb_objread.v  : real cache+SDRAM+OKLATCH, but NO obj0 FSM (a hand-driven 2-read).
//   * tb_objfold.v  : real obj0 FSM (jtnslasher_sdram), but a SIMPLE behavioral SDRAM
//                     with ok=cs and no OKLATCH timing.
// Neither tested the COMBINATION. This tb wires the REAL obj0 2-read FSM (jtnslasher_sdram)
// to the REAL slot the framework instantiates on HW:
//   jtframe_rom_1slot  SLOT0_DW=32, SLOT0_DOUBLE=1, SLOT0_OKLATCH=1 (default), SLOT0_LATCH=0
//   + jtframe_sdram64 + mt48lc16m16a2   (DW32 DOUBLE OKLATCH=1 == the hardware obj0 bus).
// With OKLATCH=1 the slot's obj0_ok (data_ok) stays HIGH for one clock AFTER the address
// changes (it is latched). The FSM latches obj0_data on the LEVEL `obj0_cs & obj0_ok`, so on
// entry to O0_P4 it can sample the STALE-high ok from the planes read while obj0_data still
// reflects the planes word -> the plane4 byte (and hence the whole 40-bit word) garbles.
//
// Engine side: drives obj0_rom_addr / obj0_rom_cs and checks obj0_rom_data == golden gfx3_spr.
// SDRAM bank3 is preloaded from sdram_bank3.hex (gen_objfold_combined.py), which COMPACT-REMAPS
// every golden tile to a dense slot so all 1440 tiles fit one mt48lc16m16a2 bank; the engine
// addresses (objfold_tv_addr.hex) are the FSM-permutation inverse of those compact nwi values,
// so the real cache/SDRAM/OKLATCH path is exercised verbatim — only the absolute slot address is
// compacted (the OKLATCH seam is per-tile-local and address-independent).
// =============================================================================
module tb_objfold_combined;
    // SDRAMW=23 so the obj0 slot's SLOT0_AW=23 fits (SDRAMW>=AW); this mirrors the real game where
    // JTFRAME_SDRAM_LARGE -> SDRAMW=24 and jtframe_rom_1slot gets SDRAMW-1=23 with .SLOT0_AW(23).
    // All preloaded addresses are tiny (<0x1680, compact-remapped) so the extra top bit is always 0
    // and the single mt48lc16m16a2 bank (0x3FFFFF) holds the whole compacted image.
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz, matches tb_objread

    // ---- engine side of the obj0 FSM (jtnslasher_sdram) ----
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    // ---- framework side: FSM <-> real slot ----
    wire        obj0_cs;
    wire [21:0] obj0_addr;      // jtnslasher_sdram drives reg [21:0] obj0_addr
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

    // ===== DUT: the REAL obj0 2-read FSM (only obj0 ports used; everything else tied off) =====
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
    // slot0_addr = {obj0_addr,1'b0} (exactly the generated jtnslasher_game_sdram: u_bank3).
    jtframe_rom_1slot #(
        .SDRAMW(SDRAMW), .SLOT0_AW(23), .SLOT0_DW(32), .SLOT0_DOUBLE(1)
        // SLOT0_OKLATCH defaults to 1 (HW), SLOT0_LATCH defaults to 0 (HW)
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

    // mt48lc16m16a2 $readmemh's Bank3 from sdram_bank3.hex (16-bit words, low-half-first).
    mt48lc16m16a2 u_sdram(
        .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba), .Clk(clk), .Cke(sdram_cke),
        .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
        .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
    );

    // ---- test vectors: engine addr per tile + golden 40-bit render word ----
    reg [23:0] tv_addr [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin
        $readmemh("objfold_tv_addr.hex", tv_addr);
        $readmemh("objfold_tv_gold.hex", tv_gold);
    end

    integer i, errors=0, first_bad=-1, timeout, checked=0;
    reg [39:0] first_got, first_exp;
    integer    first_idx;

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_objfold_combined: real FSM + real DW32-DOUBLE OKLATCH=1 cache/SDRAM ---");
        for( i=0; i<`OBJFOLD_N; i=i+1 ) begin
            @(posedge clk); #1;
            obj0_rom_addr = tv_addr[i][20:0];
            obj0_rom_cs   = 1;
            timeout=0;
            while( !obj0_rom_ok && timeout<400 ) begin @(posedge clk); timeout=timeout+1; end
            #1;
            checked = checked+1;
            if( obj0_rom_data !== tv_gold[i] ) begin
                errors = errors+1;
                if( first_bad<0 ) begin
                    first_bad = i; first_idx=i; first_got=obj0_rom_data; first_exp=tv_gold[i];
                end
                if( errors<=12 )
                    $display("  MISMATCH i=%0d engaddr=%06x got=%010x gold=%010x%s",
                             i, tv_addr[i][20:0], obj0_rom_data, tv_gold[i],
                             timeout>=400?" (TIMEOUT)":"");
            end
            obj0_rom_cs = 0; @(posedge clk); @(posedge clk);
        end
        $display("==================================================");
        if( errors==0 )
            $display("tb_objfold_combined: %0d tiles checked, 0 mismatches -> PASS (FOLD survives real OKLATCH timing)",
                     checked);
        else begin
            $display("tb_objfold_combined: %0d tiles checked, %0d mismatches -> FAIL (garble REPRODUCED)",
                     checked, errors);
            $display("  first bad: index=%0d  expected=%010x  got=%010x  (delta planes/p4 below)",
                     first_idx, first_exp, first_got);
            $display("    expected: p4=%02x planes=%08x", first_exp[39:32], first_exp[31:0]);
            $display("    got     : p4=%02x planes=%08x", first_got[39:32], first_got[31:0]);
        end
        $display("==================================================");
        $finish;
    end
    initial begin #200_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
