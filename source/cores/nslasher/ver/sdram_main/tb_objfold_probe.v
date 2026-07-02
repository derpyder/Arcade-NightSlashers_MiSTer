`timescale 1ns/1ps
// Single-tile cycle-by-cycle PROBE of the obj0 FSM <-> real DW32-DOUBLE OKLATCH=1 slot.
// Verifies the OKLATCH latched-ok behavior IS in effect and shows the exact cs/ok/data/state
// phasing at the O0_PL->O0_GAP->O0_P4 seam. Drives ONE nonzero golden tile twice (cold + warm).
module tb_objfold_probe;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    wire        obj0_cs;
    wire [21:0] obj0_addr;
    wire [31:0] obj0_data;
    wire        obj0_ok;

    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {rom_rd, 3'b0};
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

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

    mt48lc16m16a2 u_sdram(
        .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba), .Clk(clk), .Cke(sdram_cke),
        .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
        .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
    );

    reg [23:0] tv_addr [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin
        $readmemh("objfold_tv_addr.hex", tv_addr);
        $readmemh("objfold_tv_gold.hex", tv_gold);
    end

    // probe enable + golden for the tile under inspection
    reg probe=0; reg [39:0] gold_dbg;
    integer cyc=0;
    always @(posedge clk) begin
        cyc <= cyc+1;
        if( probe )
            $display("  cyc=%0d st=%0d eng_cs=%b f_cs=%b f_ok=%b f_addr=%05x f_data=%08x | rom_ok=%b rom_data=%010x",
                cyc, u_dut.o0st, obj0_rom_cs, obj0_cs, obj0_ok, obj0_addr, obj0_data,
                obj0_rom_ok, obj0_rom_data);
    end

    integer idx;
    task one_tile(input integer i, input msg_cold);
        integer t;
        begin
            $display("--- tile idx=%0d  engaddr=%06x  golden=%010x  (%s) ---",
                     i, tv_addr[i][20:0], tv_gold[i], msg_cold?"COLD cache":"WARM cache");
            @(posedge clk); #1; obj0_rom_addr=tv_addr[i][20:0]; obj0_rom_cs=1; probe=1;
            t=0; while(!obj0_rom_ok && t<400) begin @(posedge clk); t=t+1; end
            #1;
            $display("  RESULT idx=%0d got=%010x gold=%010x -> %s",
                     i, obj0_rom_data, tv_gold[i], obj0_rom_data===tv_gold[i]?"MATCH":"*** MISMATCH ***");
            obj0_rom_cs=0; @(posedge clk); probe=0; @(posedge clk); @(posedge clk);
        end
    endtask

    // find first nonzero golden tile index in the loaded vectors
    integer fi;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        fi=-1;
        for( idx=0; idx<1440; idx=idx+1 ) if(fi<0 && tv_gold[idx]!==40'd0) fi=idx;
        $display("=== OKLATCH seam probe: first nonzero tile index=%0d ===", fi);
        // COLD: cache empty -> planes is a real SDRAM burst, plane4 is the cache hit (the seam)
        one_tile(fi, 1);
        // WARM: re-read same tile immediately -> both halves are cache hits (max stale-ok pressure)
        one_tile(fi, 0);
        // also exercise the very first tile and an adjacent pair (cross-tile cache state)
        one_tile(0, 1);
        one_tile(fi+1, 1);
        $finish;
    end
    initial begin #50_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
