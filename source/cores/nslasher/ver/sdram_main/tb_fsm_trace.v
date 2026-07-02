`timescale 1ns/1ps
// Trace the obj0 2-read FSM states + obj0_cs/obj0_ok edges for a few tile-halves,
// to attribute the 37-clk idle latency to FSM phases. Same DUT/SDRAM as the measurement tb.
module tb_fsm_trace;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;
    wire        obj0_cs, obj1_cs;
    wire [20:0] obj0_addr;  wire [17:0] obj1_addr;
    wire [31:0] obj0_data, obj1_data;  wire obj0_ok, obj1_ok;
    wire        rom_rd3;  wire [SDRAMW-1:0] rom_saddr3;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = { rom_rd3, 3'b0 };  wire [3:0] ba_wr = 4'd0;
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
        .obj1_cs(obj1_cs), .obj1_addr(obj1_addr), .obj1_data(obj1_data), .obj1_ok(obj1_ok)
    );
    localparam [SDRAMW-2:0] GFX4_OFFSET = 22'h19_0000;
    jtframe_rom_2slots #(.SDRAMW(SDRAMW-1), .SLOT0_AW(22), .SLOT0_DW(32),
        .SLOT1_OFFSET(GFX4_OFFSET), .SLOT1_AW(19), .SLOT1_DW(32),
        .SLOT0_DOUBLE(1), .SLOT1_DOUBLE(1)) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr,1'b0}), .slot0_dout(obj0_data), .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .slot1_addr({obj1_addr,1'b0}), .slot1_dout(obj1_data), .slot1_cs(obj1_cs), .slot1_ok(obj1_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rom_rd3), .sdram_addr(rom_saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout) );
    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1), .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr({SDRAMW{1'b0}}), .ba2_addr({SDRAMW{1'b0}}), .ba3_addr(rom_saddr3),
        .rd(ba_rd), .wr(ba_wr),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(1'b0), .prog_addr({SDRAMW{1'b0}}), .prog_rd(1'b0), .prog_wr(1'b0),
        .prog_din(16'd0), .prog_dsn(2'b11), .prog_ba(2'b00),
        .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(), .rfsh(1'b0),
        .ack(ba_ack), .dst(ba_dst), .dok(ba_dok), .rdy(ba_rdy), .dout(dout),
        .sdram_dq(sdram_dq), .sdram_a(sdram_a),
        .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
        .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
        .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke) );
    mt48lc16m16a2 u_sdram(.Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba), .Clk(clk), .Cke(sdram_cke),
        .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
        .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0) );

    reg [23:0] tv_addr [0:8191];
    initial $readmemh("objfold_real_addr.hex", tv_addr);

    integer eng_i, cyc; reg rom_good, running, done; integer ntrace;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        // warm a few tiles, then trace tiles 10..12
        eng_i=0; running=1; ntrace=0;
        // run 10 tiles silently
        repeat(10) begin
            obj0_rom_addr = tv_addr[eng_i][20:0]; obj0_rom_cs=1; rom_good=0;
            @(posedge clk); rom_good <= obj0_rom_cs & obj0_rom_ok;
            while( !(obj0_rom_cs && rom_good && obj0_rom_ok) ) begin @(posedge clk); rom_good <= obj0_rom_cs & obj0_rom_ok; end
            obj0_rom_cs=0; @(posedge clk); eng_i=eng_i+1;
        end
        // trace next 3 tiles cycle-by-cycle
        repeat(3) begin
            $display("---- tile-half %0d addr=%06x ----", eng_i, tv_addr[eng_i][20:0]);
            obj0_rom_addr = tv_addr[eng_i][20:0]; obj0_rom_cs=1; rom_good=0; cyc=0;
            @(posedge clk); rom_good <= obj0_rom_cs & obj0_rom_ok;
            while( !(obj0_rom_cs && rom_good && obj0_rom_ok) ) begin
                $display("  cyc=%0d o0st=%0d obj0_cs=%b obj0_addr=%06x obj0_ok=%b rom_ok=%b",
                         cyc, u_dut.o0st, obj0_cs, obj0_addr, obj0_ok, obj0_rom_ok);
                cyc=cyc+1; @(posedge clk); rom_good <= obj0_rom_cs & obj0_rom_ok;
            end
            $display("  CONSUME cyc=%0d o0st=%0d rom_ok=%b", cyc, u_dut.o0st, obj0_rom_ok);
            obj0_rom_cs=0; @(posedge clk); eng_i=eng_i+1;
        end
        $finish;
    end
    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
