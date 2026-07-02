`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_obj0_lat_fold — MEASURE the obj0 fetch latency for a SINGLE-FETCH FOLD on
// REAL SDRAM, using the SAME engine cadence + SAME measurement accounting as
// tb_obj0_lat_nonfold (apples-to-apples).
//
// FOLD = one BA3 slot delivering the whole 40-bit obj0 word in ONE burst.
// Modeled with jtframe_rom_1slot DW32 DOUBLE (the proven single-bus layout from
// tb_objfold_real.v: a DW32-DOUBLE burst returns 64 bits = the packed 40-bit word
// in a single SDRAM transaction). obj0_rom_ok = the single slot's ok.
// =============================================================================
module tb_obj0_lat_fold;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire        obj0_rom_ok;

    // single BA3 slot (the fold)
    wire        obj0_cs;
    wire [21:0] obj0_addr = {1'b0, obj0_rom_addr};   // word address for the slot
    wire [31:0] obj0_data;
    wire        obj0_ok;
    assign      obj0_cs     = obj0_rom_cs;
    assign      obj0_rom_ok = obj0_ok;

    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {rom_rd, 3'b0};
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    // ===== single DW32 DOUBLE slot = the FOLD's one burst =====
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
    initial $readmemh("objfold_real_addr.hex", tv_addr);

    integer eng_i;
    reg     rom_good;
    reg     running, done;
    integer stall;
    reg     started;

    integer cs_cyc;
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

            if( stall > 2000 ) begin
                $display("  STALL/HANG at i=%0d", eng_i); done <= 1;
            end
        end else if( started && !running ) begin
            running <= 1;
        end
    end

    integer k;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_obj0_lat_fold: SINGLE-fetch FOLD (one DW32 DOUBLE BA3 burst) ---");
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("FOLD obj0  rom_cs->rom_ok latency over %0d back-to-back fetches:", lat_n);
        $display("  min=%0d  max=%0d  mean=%0d clk", lat_min, lat_max, (lat_n>0)?(lat_sum/lat_n):0);
        $display("  histogram (lat clk : count):");
        for(k=0;k<128;k=k+1) if(lat_hist[k]>0) $display("    %3d : %0d", k, lat_hist[k]);
        $display("==================================================");
        $finish;
    end
    initial begin #800_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
