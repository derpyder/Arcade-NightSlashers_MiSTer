`timescale 1ns/1ps
`include "objfold_real_n.vh"
// Measure BA1(CPU) access latency (cpu_cs-rise -> cpu_ok) in two conditions:
//   (A) obj0 fold IDLE  (BA3 quiet)            -> baseline CPU latency
//   (B) obj0 fold HAMMERING (real 2-read FSM)  -> CPU latency under sprite-fetch load
// Same controller/SDRAM as the game. -DOBJLOAD enables the obj0 hammer.
module tb_cpu_starve;
    localparam SDRAMW=23;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    // obj0 (BA3) - real 2-read fold FSM
    reg  [20:0] obj0_rom_addr=0; reg obj0_rom_cs=0;
    wire [39:0] obj0_rom_data;   wire obj0_rom_ok;
    wire        obj0_cs, obj1_cs;
    wire [20:0] obj0_addr; wire [17:0] obj1_addr;
    wire [31:0] obj0_data, obj1_data; wire obj0_ok, obj1_ok;
    wire        rom_rd3; wire [SDRAMW-1:0] rom_saddr3;

    // CPU (BA1)
    reg         cpu_cs=0; reg [18:0] cpu_addr=0; wire cpu_ok; wire [31:0] cpu_data;
    wire        rom_rd1; wire [SDRAMW-1:0] rom_saddr1;

    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = { rom_rd3, 1'b0, rom_rd1, 1'b0 };
    wire [3:0]  ba_wr = 4'd0;
    wire [15:0] sdram_dq; wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba; wire init;

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
    jtframe_rom_1slot #(.SDRAMW(SDRAMW-1), .SLOT0_AW(19), .SLOT0_DW(32), .SLOT0_DOUBLE(1)) u_bank1 (
        .rst(rst), .clk(clk),
        .slot0_addr({cpu_addr,1'b0}), .slot0_dout(cpu_data), .slot0_cs(cpu_cs), .slot0_ok(cpu_ok),
        .sdram_ack(ba_ack[1]), .sdram_rd(rom_rd1), .sdram_addr(rom_saddr1),
        .data_dst(ba_dst[1]), .data_rdy(ba_rdy[1]), .data_read(dout) );
    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1), .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64)) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr({SDRAMW{1'b0}}), .ba1_addr(rom_saddr1), .ba2_addr({SDRAMW{1'b0}}), .ba3_addr(rom_saddr3),
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

    // obj0 hammer engine (faithful), enabled only with OBJLOAD
    integer eng_i; reg rom_good, running, done;
    reg started;
    // CPU latency stats
    integer cpu_cyc, cpu_sum, cpu_n, cpu_min, cpu_max, cpu_seed, warm;
    initial begin cpu_sum=0; cpu_n=0; cpu_min=999999; cpu_max=0; cpu_seed=1; warm=0; end

    always @(posedge clk) begin
        if(rst) begin
            eng_i<=0; obj0_rom_cs<=0; obj0_rom_addr<=0; rom_good<=0; running<=0; done<=0; started<=0;
            cpu_cs<=0; cpu_addr<=0; cpu_cyc<=0;
        end else if(running && !done) begin
            // ---- CPU(BA1): always pending, scattered addr ----
            if(cpu_cs) cpu_cyc <= cpu_cyc+1;
            if(cpu_cs && cpu_ok) begin
                warm<=warm+1;
                if(warm>=8) begin
                    cpu_sum<=cpu_sum+cpu_cyc; cpu_n<=cpu_n+1;
                    if(cpu_cyc<cpu_min) cpu_min<=cpu_cyc;
                    if(cpu_cyc>cpu_max) cpu_max<=cpu_cyc;
                end
                cpu_cs<=0;
                if(cpu_n>=2000) done<=1;
            end else if(!cpu_cs) begin
                cpu_seed <= cpu_seed*1103515245 + 12345;
                cpu_addr <= cpu_seed[18:0];
                cpu_cs<=1; cpu_cyc<=0;
            end
`ifdef OBJLOAD
            // ---- obj0 hammer: faithful 2nd-ok consume, back-to-back ----
            rom_good <= obj0_rom_cs & obj0_rom_ok;
            if(obj0_rom_cs && rom_good && obj0_rom_ok) begin
                obj0_rom_cs<=0; rom_good<=0;
                eng_i <= (eng_i==`OBJFOLD_N-1)?0:eng_i+1;
            end else if(!obj0_rom_cs) begin
                obj0_rom_addr<=tv_addr[eng_i][20:0]; obj0_rom_cs<=1; rom_good<=0;
            end
`endif
        end else if(started && !running) running<=1;
    end

    initial begin
        cpu_cs=0; cpu_addr=0; obj0_rom_cs=0;
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
`ifdef OBJLOAD
        $display("--- tb_cpu_starve: BA1(CPU) latency WITH obj0 fold HAMMERING ---");
`else
        $display("--- tb_cpu_starve: BA1(CPU) latency, obj0 IDLE (baseline) ---");
`endif
        @(posedge clk); started<=1;
        wait(done==1); repeat(4) @(posedge clk);
        $display("  CPU(BA1) latency: min=%0d max=%0d mean=%0d clk  (n=%0d)",
                 cpu_min, cpu_max, (cpu_n>0)?(cpu_sum/cpu_n):0, cpu_n);
        $finish;
    end
    initial begin #2000_000_000; $display("TIMEOUT"); $finish; end
endmodule
