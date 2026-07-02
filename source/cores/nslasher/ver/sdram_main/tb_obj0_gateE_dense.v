`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_obj0_gateE_dense — CALIBRATION BASELINE: the nf23 DENSE 2-read design in
// the SAME contention harness as tb_obj0_gateDE (same traffic generators, same
// vectors, same refresh). HW truth: the nf23 probe measured 46-66 clk (typ
// ~52-58) per obj0 fetch in heavy combat. If this sim lands in that range, the
// harness is calibrated and gateDE's nf24 numbers predict the cab.
//   DUT   = jtnslasher_sdram_dense_ref.v (the nf23 backup: 2-read FSM, dense pack)
//   BA3   = rom_2slots (obj0 AW22 DW32 + obj1 AW19 DW32 @GFX4_OFFSET, NO DOUBLE)
//   obj1  = traffic client in BA3 (the nf23 reality; nf24 moved it to BA2)
//   BA2   = rom_4slots with the 4 PF clients ; BA1 = CPU client ; LEN=32 all banks
// =============================================================================
module tb_obj0_gateE_dense;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;

    wire        obj0_cs;
    wire [20:0] obj0_addr;      // nf23 dense adapter: [20:0]
    wire [31:0] obj0_data;
    wire        obj0_ok;

    wire        rd1, rd2, rd3;
    wire [SDRAMW-1:0] saddr1, saddr2, saddr3;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = { rd3, rd2, rd1, 1'b0 };
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    // ===== DUT: the nf23 DENSE adapter (compiled from jtnslasher_sdram_dense_ref.v) =====
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

    // ===== BA3: the nf23 rom_2slots (obj0 + obj1 traffic, NO DOUBLE) =====
    localparam [SDRAMW-2:0] GFX4_OFFSET = 22'h32_0000;   // (0xC50000-0x610000)>>1
    reg         o1_cs=0;
    reg  [17:0] o1_addr=0;
    wire [31:0] o1_dout;
    wire        o1_ok;
    jtframe_rom_2slots #(
        .SDRAMW(SDRAMW-1),
        .SLOT0_AW(22), .SLOT0_DW(32),
        .SLOT1_OFFSET(GFX4_OFFSET), .SLOT1_AW(19), .SLOT1_DW(32)
    ) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data), .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .slot1_addr({o1_addr, 1'b0}), .slot1_dout(o1_dout), .slot1_cs(o1_cs), .slot1_ok(o1_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rd3), .sdram_addr(saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    // ===== BA1: CPU client (identical to gateDE) =====
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
                    cpu_addr <= {lfsr_c[15:0], lfsr_c[5:2]};
                    cpu_cs   <= 1;
                end
            end
        end
    end

    // ===== BA2: 4x PF clients (identical cadence to gateDE) =====
    reg        pf_cs [0:3];
    reg [19:0] pf_addr [0:3];
    wire       pf_ok [0:3];
    wire [15:0] pf0_d, pf1_d, pf2_d, pf3_d;
    jtframe_rom_4slots #(
        .SDRAMW(SDRAMW),
        .SLOT0_AW(20), .SLOT0_DW(16),
        .SLOT1_AW(20), .SLOT1_DW(16),
        .SLOT2_AW(20), .SLOT2_DW(16),
        .SLOT3_AW(20), .SLOT3_DW(16)
    ) u_bank2 (
        .rst(rst), .clk(clk),
        .slot0_addr(pf_addr[0]), .slot0_dout(pf0_d), .slot0_cs(pf_cs[0]), .slot0_ok(pf_ok[0]),
        .slot1_addr(pf_addr[1]), .slot1_dout(pf1_d), .slot1_cs(pf_cs[1]), .slot1_ok(pf_ok[1]),
        .slot2_addr(pf_addr[2]), .slot2_dout(pf2_d), .slot2_cs(pf_cs[2]), .slot2_ok(pf_ok[2]),
        .slot3_addr(pf_addr[3]), .slot3_dout(pf3_d), .slot3_cs(pf_cs[3]), .slot3_ok(pf_ok[3]),
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

    // obj1 traffic client in BA3 (the nf23 reality), same 30-clk heavy cadence
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

    // refresh: identical to gateDE (real average)
    reg [8:0] rfsh_cnt=0;
    reg       rfsh_pulse=0;
    always @(posedge clk) begin
        if(!en) begin rfsh_cnt<=0; rfsh_pulse<=0; end
        else begin
            rfsh_cnt   <= (rfsh_cnt==9'd374) ? 9'd0 : rfsh_cnt + 9'd1;
            rfsh_pulse <= (rfsh_cnt==9'd373);
        end
    end

    // nf23 config: NO BA3_LEN -> all banks LEN=32
    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(32), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(32)) u_ctrl (
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

    reg [23:0] tv_addr [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin
        $readmemh("objfold_real_addr.hex", tv_addr);
        $readmemh("objfold_real_gold.hex", tv_gold);
    end

    localparam NMEAS = `OBJFOLD_N;
    localparam LOOPS = 4;
    integer eng_i, loop_i;
    reg     rom_good;
    reg     running, done;
    integer stall;
    reg     started;

    integer cs_cyc;
    integer lat_min, lat_max, lat_sum, lat_n, lat_gt22, lat_gt27, lat_gt45;
    integer warm;
    integer chk_n, mism_n;
    initial begin
        lat_min=999999; lat_max=0; lat_sum=0; lat_n=0; warm=0; lat_gt22=0; lat_gt27=0; lat_gt45=0;
        chk_n=0; mism_n=0;
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
                    if( cs_cyc > 45 ) lat_gt45 <= lat_gt45 + 1;
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
                $display("  STALL/HANG loop=%0d i=%0d", loop_i, eng_i);
                done <= 1;
            end
        end else if( started && !running ) begin
            running <= 1;
        end
    end

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_obj0_gateE_dense: nf23 DENSE 2-read BASELINE under the gateDE contention harness ---");
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("BASELINE (nf23 dense 2-read; HW-measured 46-66 clk typ 52-58):");
        $display("  checked=%0d  MISMATCHES=%0d", chk_n, mism_n);
        $display("  obj0 latency: min=%0d mean=%0d max=%0d clk  >22: %0d%%  >27: %0d%%  >45: %0d%%",
                 lat_min, (lat_n>0)?(lat_sum/lat_n):0, lat_max,
                 (lat_n>0)?(100*lat_gt22/lat_n):0, (lat_n>0)?(100*lat_gt27/lat_n):0,
                 (lat_n>0)?(100*lat_gt45/lat_n):0);
        $display("  obj1 in BA3: min=%0d mean=%0d max=%0d clk (n=%0d)",
                 o1lat_min, (o1lat_n>0)?(o1lat_sum/o1lat_n):0, o1lat_max, o1lat_n);
        $display("==================================================");
        $finish;
    end
    initial begin #3000_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
