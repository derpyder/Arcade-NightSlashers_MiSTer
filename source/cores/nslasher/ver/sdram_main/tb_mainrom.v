`timescale 1ns/1ps
// Faithful READ-path harness for the Night Slashers main ARM ROM (BA1):
//   real jtframe_rom_4slots (SLOT0 DW=32, DOUBLE=1, AW=19)  <->  real jtframe_sdram64
//   (AW=22, MISTER=1, HF=1, BA1_LEN=64)  <->  mt48lc16m16a2 behavioral SDRAM.
// Bank1 preloaded (sdram_bank1.hex) with the CORRECT little-endian image. The boot
// iverilog sim BYPASSES all of this (it serves rom_data=rawrom[addr] from a flat array),
// so this is the FIRST time the real read assembly is exercised in sim.
// PASS  = reads return golden (0x170EB025 @ 0x023608)  -> read path correct, bug is elsewhere/electrical
// FAIL  = reads return byteswap32 (0x25B00E17)         -> reproduced the HW bug in the read path
module tb_mainrom;
    localparam SDRAMW=22;

    reg clk=0, rst=1;
    always #10.4 clk=~clk;   // ~48 MHz

    // ---- consumer (main slot) ----
    reg  [18:0] main_addr=0;   // {arm_word,1'b0}
    reg         main_cs=0;
    wire [31:0] main_data;
    wire        main_ok;

    // ---- rom_4slots <-> sdram64 ----
    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {2'b0, rom_rd, 1'b0};   // bank1
    wire [3:0]  ba_wr = 4'd0;

    // ---- SDRAM pins ----
    wire [15:0] sdram_dq;
    wire [12:0] sdram_a;
    wire        sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0]  sdram_ba;
    wire        init;

    jtframe_rom_4slots #(
        .SDRAMW(SDRAMW),
        .SLOT0_AW(19), .SLOT0_DW(32), .SLOT0_DOUBLE(1)
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
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64),
        .BA1_WEN(1)
    ) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr(22'd0), .ba1_addr(rom_saddr), .ba2_addr(22'd0), .ba3_addr(22'd0),
        .rd(ba_rd), .wr(ba_wr),
        .ba0_din(16'd0), .ba0_dsn(2'b11),
        .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11),
        .ba3_din(16'd0), .ba3_dsn(2'b11),
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

    integer errors=0;
    task do_read(input [17:0] arm_word, input [31:0] golden);
        begin
            @(posedge clk); #1; main_addr = {arm_word,1'b0}; main_cs = 1;
            wait(main_ok);
            @(posedge clk); #1;
            $display("arm_word %06X : got %08X  golden %08X  byteswap %08X  -> %s",
                arm_word, main_data, golden,
                {golden[7:0],golden[15:8],golden[23:16],golden[31:24]},
                main_data===golden ? "OK" :
                (main_data==={golden[7:0],golden[15:8],golden[23:16],golden[31:24]} ? "BYTESWAP32 (HW bug reproduced)":"OTHER-MISMATCH"));
            if(main_data!==golden) errors=errors+1;
            main_cs = 0; @(posedge clk); @(posedge clk);
        end
    endtask

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0;
        // wait for SDRAM init to complete
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- init done, beginning reads ---");
        do_read(18'h00000, 32'hxxxxxxxx); // reset vector word (golden unknown here, just print)
        do_read(18'h023608, 32'h170EB025); // THE failing LUT-overrun word
        do_read(18'h023609, 32'hxxxxxxxx); // odd-aligned neighbour (interleave/wrap probe)
        do_read(18'h0235FF, 32'hxxxxxxxx);
        $display("--- done, mismatches(excl x-golden)=%0d ---", errors);
        $finish;
    end

    initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
