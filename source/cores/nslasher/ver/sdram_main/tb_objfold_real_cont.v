`timescale 1ns/1ps
`include "objfold_real_n.vh"
// =============================================================================
// tb_objfold_real_cont — tb_objfold_real PLUS SDRAM CONTENTION.
//
// tb_objfold_real drives ONLY the obj0 bus, so the shared jtframe_sdram64 controller serves obj0 at
// minimal, regular latency (best case). On HW the SAME controller also serves PF1/PF2 (gfx1a/b),
// PF3/PF4 (gfx2a/b) and obj1 — five other DW16/DW32 buses hammering BA0/BA1/BA2 — so obj0 bursts are
// delayed and re-phased by bank/refresh contention. If the obj0 2-read FSM's fresh-ok edge detect or
// the DOUBLE cache had a latency-phase-sensitive fault, contention is what would expose it.
//
// Here three self-driving read slots on BA0/BA1/BA2 keep cs permanently high and walk their addresses,
// so the controller is continuously busy on the other banks while the faithful obj0 engine runs the
// exact same back-to-back / 2nd-ok cadence at REAL addresses.  Same golden check.
// =============================================================================
module tb_objfold_real_cont;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    // ---- obj0 path (DUT) ----
    reg  [20:0] obj0_rom_addr=0;
    reg         obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;
    wire        obj0_cs;
    wire [21:0] obj0_addr;
    wire [31:0] obj0_data;
    wire        obj0_ok;

    // ---- controller plumbing ----
    wire        rd3;  wire [SDRAMW-1:0] saddr3;   // obj0 on BA3 (rd0/1/2 + saddr0/1/2 declared below)
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = { rd3, rd2, rd1, rd0 };
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

    // obj0 slot on BA3 (the real one)
    jtframe_rom_1slot #(.SDRAMW(SDRAMW), .SLOT0_AW(23), .SLOT0_DW(32), .SLOT0_DOUBLE(1)) u_bank3 (
        .rst(rst), .clk(clk),
        .slot0_addr({obj0_addr, 1'b0}), .slot0_dout(obj0_data),
        .slot0_cs(obj0_cs), .slot0_ok(obj0_ok),
        .sdram_ack(ba_ack[3]), .sdram_rd(rd3), .sdram_addr(saddr3),
        .data_dst(ba_dst[3]), .data_rdy(ba_rdy[3]), .data_read(dout)
    );

    // ---- latency variation = PERIODIC REFRESH pulses (the real HB-rfsh behaviour) ----
    // The multi-bank competing-slot approach deadlocked the toy 4-bank controller (BA3 never acked),
    // so we vary obj0's burst latency the way HW does: pulse `rfsh` periodically. Each pulse stalls
    // obj0's next burst behind a refresh cycle, shifting the ok phasing the FSM must tolerate. The
    // contention slots are tied off; BA0/1/2 unused here.
    wire rd0=1'b0, rd1=1'b0, rd2=1'b0;
    wire [SDRAMW-1:0] saddr0={SDRAMW{1'b0}}, saddr1={SDRAMW{1'b0}}, saddr2={SDRAMW{1'b0}};
    reg  [7:0] rfsh_cnt=0;
    reg        rfsh_pulse=0;
    wire       en = ~init & ~rst;
    always @(posedge clk) begin
        if(!en) begin rfsh_cnt<=0; rfsh_pulse<=0; end
        else begin
            rfsh_cnt   <= rfsh_cnt + 8'd1;
            rfsh_pulse <= (rfsh_cnt==8'd97);   // a refresh burst roughly every 98 clks (prime-ish)
        end
    end

    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1), .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr(saddr0), .ba1_addr(saddr1), .ba2_addr(saddr2), .ba3_addr(saddr3),
        .rd(ba_rd), .wr(ba_wr),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(1'b0), .prog_addr({SDRAMW{1'b0}}), .prog_rd(1'b0), .prog_wr(1'b0),
        .prog_din(16'd0), .prog_dsn(2'b11), .prog_ba(2'b00),
        .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
        .rfsh(rfsh_pulse),                 // periodic refresh pulses vary obj0's burst latency (HB-rfsh)
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

    integer eng_i, errors, first_bad, checked;
    reg [39:0] first_got, first_exp;
    integer    first_addr, first_idx;
    reg        rom_good, running, done, started;
    integer    stall, maxlat, curlat;

    always @(posedge clk) begin
        if( rst ) begin
            eng_i<=0; errors<=0; first_bad<=-1; checked<=0;
            obj0_rom_cs<=0; obj0_rom_addr<=0; rom_good<=0;
            running<=0; done<=0; started<=0; stall<=0; maxlat<=0; curlat<=0;
        end else if( running && !done ) begin
            rom_good <= obj0_rom_cs & obj0_rom_ok;
            if( obj0_rom_cs ) curlat <= curlat+1;
            if( obj0_rom_cs && !(obj0_rom_cs && rom_good && obj0_rom_ok) ) stall <= stall+1;
            if( obj0_rom_cs && rom_good && obj0_rom_ok ) begin
                checked <= checked+1;
                if( curlat>maxlat ) maxlat<=curlat;
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
                obj0_rom_cs <= 0; rom_good <= 0; stall <= 0; curlat<=0;
                if( eng_i == `OBJFOLD_N-1 ) done <= 1; else eng_i <= eng_i+1;
            end else if( !obj0_rom_cs ) begin
                if( !done ) begin
                    obj0_rom_addr <= tv_addr[eng_i][20:0];
                    obj0_rom_cs   <= 1;
                    rom_good      <= 0;
                    curlat        <= 0;
                end
            end
            if( stall > 2000 ) begin
                $display("  STALL/HANG at i=%0d engaddr=%06x", eng_i, tv_addr[eng_i][20:0]);
                done <= 1;
            end
        end else if( started && !running ) running <= 1;
    end

`ifdef CONT_DIAG
    integer dbgn=0;
    always @(posedge clk) if(started && dbgn<60) begin
        dbgn<=dbgn+1;
        $display("  DBG c=%0d e_cs=%b e_ok=%b o0st=%0d rg=%b | f_cs=%b f_ok=%b f_addr=%06x | rd3=%b rdy3=%b ack3=%b | rfsh=%b",
            dbgn, obj0_rom_cs, obj0_rom_ok, u_dut.o0st, rom_good,
            obj0_cs, obj0_ok, obj0_addr, rd3, ba_rdy[3], ba_ack[3], rfsh_pulse);
    end
`endif
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- tb_objfold_real_cont: faithful engine + REAL addr + back-to-back + PERIODIC-REFRESH latency variation ---");
        @(posedge clk); started<=1;
        wait(done==1);
        repeat(4) @(posedge clk);
        $display("==================================================");
        $display("  obj0 max observed fetch latency under contention: %0d clks", maxlat);
        if( errors==0 )
            $display("tb_objfold_real_cont: %0d tiles checked, 0 mismatches -> PASS", checked);
        else begin
            $display("tb_objfold_real_cont: %0d tiles checked, %0d mismatches -> FAIL (garble REPRODUCED)", checked, errors);
            $display("  first bad: index=%0d engaddr=%06x", first_idx, first_addr);
            $display("    expected: p4=%02x planes=%08x", first_exp[39:32], first_exp[31:0]);
            $display("    got     : p4=%02x planes=%08x", first_got[39:32], first_got[31:0]);
        end
        $display("==================================================");
        $finish;
    end
    initial begin #800_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
