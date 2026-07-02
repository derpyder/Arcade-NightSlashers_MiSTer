`timescale 1ns/1ps
// LINCHPIN TEST for the no-framework-change sprite fold:
//   A DW32 DOUBLE slot bursts 64 bits (4 beats) and the bcache caches BOTH 32-bit halves
//   (word@A and word@A+1). So reading word A triggers ONE SDRAM burst; reading the ADJACENT
//   word A+1 right after should be a CACHE HIT (no new SDRAM access). If true, obj0 can fold:
//   planes@(nwi*2) + plane4@(nwi*2+1) in one 8-byte slot -> ONE burst/tile via a 2-read adapter,
//   with NO DW64 and NO framework change.
// Preload sdram_bank1.hex: words(16b) 0,1,2,3 = AAAA,1111,BBBB,2222
//   => 32b word0 = 0x1111AAAA (planes marker), word1 = 0x2222BBBB (plane4 marker).
module tb_objread;
    localparam SDRAMW=22;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    reg  [18:0] main_addr=0;
    reg         main_cs=0;
    wire [31:0] main_data;
    wire        main_ok;

    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {2'b0, rom_rd, 1'b0};   // bank1
    wire [3:0]  ba_wr = 4'd0;

    wire [15:0] sdram_dq;  wire [12:0] sdram_a;
    wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0] sdram_ba;  wire init;

    jtframe_rom_4slots #(
        .SDRAMW(SDRAMW), .SLOT0_AW(19), .SLOT0_DW(32), .SLOT0_DOUBLE(1)
    ) u_bank1 (
        .rst(rst), .clk(clk),
        .slot0_addr(main_addr), .slot0_dout(main_data), .slot0_cs(main_cs), .slot0_ok(main_ok),
        .slot1_addr(16'd0), .slot1_cs(1'b0),
        .slot2_addr(16'd0), .slot2_cs(1'b0),
        .slot3_addr(16'd0), .slot3_cs(1'b0),
        .sdram_ack(ba_ack[1]), .sdram_rd(rom_rd), .sdram_addr(rom_saddr),
        .data_dst(ba_dst[1]), .data_rdy(ba_rdy[1]), .data_read(dout)
    );

    jtframe_sdram64 #(
        .AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64), .BA1_WEN(1)
    ) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr(22'd0), .ba1_addr(rom_saddr), .ba2_addr(22'd0), .ba3_addr(22'd0),
        .rd(ba_rd), .wr(ba_wr),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(1'b0), .prog_addr(22'd0), .prog_rd(1'b0), .prog_wr(1'b0),
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

    // ---- count SDRAM read bursts (rom_rd rising edges) ----
    integer rd_bursts=0; reg rd_l=0;
    always @(posedge clk) begin rd_l<=rom_rd; if(rom_rd && !rd_l) rd_bursts<=rd_bursts+1; end

    integer errors=0;
    integer b_before, b_after;
    task do_read(input [17:0] aw, input [31:0] golden, input expect_hit);
        integer b0;
        begin
            b0 = rd_bursts;
            @(posedge clk); #1; main_addr = {aw,1'b0}; main_cs = 1;
            wait(main_ok); @(posedge clk); #1;
            $display("  read word %0d: got %08X golden %08X  bursts+%0d  %s%s",
                aw, main_data, golden, rd_bursts-b0,
                main_data===golden?"DATA-OK":"DATA-MISMATCH",
                expect_hit ? ((rd_bursts-b0)==0?" HIT-OK":" *** EXPECTED HIT, GOT A BURST ***")
                           : ((rd_bursts-b0)>0?" (burst, expected)":" (no burst?!)"));
            if(main_data!==golden) errors=errors+1;
            if(expect_hit && (rd_bursts-b0)!=0) errors=errors+1;
            if(!expect_hit && (rd_bursts-b0)==0) errors=errors+1;
            main_cs = 0; @(posedge clk); @(posedge clk);
        end
    endtask

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- init done. Testing DW32-DOUBLE 2-read cache-hit (the fold linchpin) ---");
        // word0 = planes marker, word1 = plane4 marker (adjacent -> same 64b burst)
        do_read(18'd0, 32'h1111AAAA, 1'b0);   // read A   -> expect ONE burst
        do_read(18'd1, 32'h2222BBBB, 1'b1);   // read A+1 -> expect CACHE HIT (no new burst)
        $display("--- VERDICT: %s (errors=%0d, total bursts=%0d) ---",
                 errors==0 ? "FOLD MECHANISM CONFIRMED: 1 burst serves both planes(@A) + plane4(@A+1)" : "FAILED",
                 errors, rd_bursts);
        $finish;
    end
    initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
