`timescale 1ns/1ps
// Faithful WRITE+READ harness: the REAL download path that only ever runs on HW.
//   ioctl byte stream -> jtframe_dwnld(SWAB=1) -> jtnslasher_dwnld(post-pass, BA1 identity)
//   -> jtframe_sdram64 prog port -> mt48lc16m16a2 ; then read back via jtframe_rom_4slots.
// No preload: the SDRAM contents are whatever the real download writes.
// PASS = read returns golden 0x170EB025 ; FAIL(byteswap 0x25B00E17) = download is the bug.
module tb_mainrom_wr;
    localparam SDRAMW=22;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    // ---- ioctl download stimulus ----
    reg         ioctl_rom=0, ioctl_wr=0;
    reg  [25:0] ioctl_addr=0;
    reg  [ 7:0] ioctl_dout=0;

    // ---- jtframe_dwnld outputs (SDRAMW=23 like the real core -> prog_addr=[22:1] = word addr in [21:0]) ----
    wire [21:0]       raw_addr;     // = eff_addr>>1 (16-bit word address)
    wire [15:0]       raw_data;
    wire [1:0]        prog_mask;
    wire              prog_we, prog_rd, header;
    wire [1:0]        prog_ba;

    // ---- per-core post-pass (BA1 identity) ----
    wire [21:0] post_addr;
    wire [ 7:0] post_data;

    jtframe_dwnld #(
        .SDRAMW(23), .BA1_START(26'd0),
        .BA2_START(~26'd0), .BA3_START(~26'd0), .PROM_START(~26'd0),
        .SWAB(1)
    ) u_dwnld (
        .clk(clk), .ioctl_rom(ioctl_rom), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wr(ioctl_wr),
        .gfx4_en(1'b0), .gfx8_en(1'b0), .gfx16_en(1'b0), .gfx16b_en(1'b0), .gfx16c_en(1'b0),
        .prog_addr(raw_addr), .prog_data(raw_data), .prog_mask(prog_mask),
        .prog_we(prog_we), .prog_rd(prog_rd), .prog_ba(prog_ba),
        .prom_we(), .header(header), .sdram_ack(prog_ack)
    );

    jtnslasher_dwnld u_post(
        .prog_addr(raw_addr), .prog_ba(prog_ba), .prog_data(raw_data[7:0]),
        .post_addr(post_addr), .post_data(post_data)
    );

    // ---- consumer (main slot) ----
    reg  [18:0] main_addr=0; reg main_cs=0;
    wire [31:0] main_data; wire main_ok;

    // ---- rom_4slots <-> sdram64 ----
    wire        rom_rd;
    wire [SDRAMW-1:0] rom_saddr;
    wire [15:0] dout;
    wire [3:0]  ba_ack, ba_dst, ba_dok, ba_rdy;
    wire [3:0]  ba_rd = {2'b0, rom_rd, 1'b0};
    wire        prog_ack, prog_dst, prog_dok, prog_rdy;

    wire [15:0] sdram_dq; wire [12:0] sdram_a;
    wire        sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;
    wire [1:0]  sdram_ba; wire init;

    jtframe_rom_4slots #(.SDRAMW(SDRAMW), .SLOT0_AW(19), .SLOT0_DW(32), .SLOT0_DOUBLE(1)) u_bank1 (
        .rst(rst), .clk(clk),
        .slot0_addr(main_addr), .slot0_dout(main_data), .slot0_cs(main_cs), .slot0_ok(main_ok),
        .slot1_addr(16'd0), .slot1_cs(1'b0), .slot2_addr(16'd0), .slot2_cs(1'b0), .slot3_addr(16'd0), .slot3_cs(1'b0),
        .sdram_ack(ba_ack[1]), .sdram_rd(rom_rd), .sdram_addr(rom_saddr),
        .data_dst(ba_dst[1]), .data_rdy(ba_rdy[1]), .data_read(dout)
    );

    jtframe_sdram64 #(.AW(SDRAMW), .HF(1), .MISTER(1),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64), .BA1_WEN(1)
    ) u_ctrl (
        .rst(rst), .clk(clk), .init(init),
        .ba0_addr(22'd0), .ba1_addr(rom_saddr), .ba2_addr(22'd0), .ba3_addr(22'd0),
        .rd(ba_rd), .wr(4'd0),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(ioctl_rom), .prog_addr(post_addr), .prog_rd(1'b0), .prog_wr(prog_we),
        .prog_din({2{post_data}}), .prog_dsn(prog_mask), .prog_ba(prog_ba),
        .prog_dst(prog_dst), .prog_dok(prog_dok), .prog_rdy(prog_rdy), .prog_ack(prog_ack),
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

    // ---- download window ----
    localparam BASE_W=18'h023600, NW=8'h40, BASE_BYTE=26'h08D800;
    reg [7:0] blob [0:255];
    integer k;

    task dwn_byte(input [25:0] addr, input [7:0] data);
        begin
            @(posedge clk); #1; ioctl_addr=addr; ioctl_dout=data; ioctl_wr=1;
            @(posedge clk); #1; ioctl_wr=0;
            wait(prog_ack==1); @(posedge clk); repeat(3) @(posedge clk);
        end
    endtask

    task do_read(input [17:0] arm_word, input [31:0] golden);
        begin
            @(posedge clk); #1; main_addr={arm_word,1'b0}; main_cs=1;
            wait(main_ok); @(posedge clk); #1;
            $display("arm_word %06X : got %08X  golden %08X  -> %s", arm_word, main_data, golden,
                main_data===golden ? "OK" :
                (main_data==={golden[7:0],golden[15:8],golden[23:16],golden[31:24]} ? "BYTESWAP32 (HW bug reproduced)":"OTHER"));
            main_cs=0; @(posedge clk); @(posedge clk);
        end
    endtask

    initial begin
        $readmemh("blob.hex", blob);
        rst=1; repeat(20) @(posedge clk); rst=0;
        wait(init==0); repeat(50) @(posedge clk);
        $display("--- init done, downloading %0d bytes from BASE_BYTE=%06X ---", NW*4, BASE_BYTE);
        ioctl_rom=1; @(posedge clk);
        for(k=0;k<NW*4;k=k+1) dwn_byte(BASE_BYTE + k, blob[k]);
        @(posedge clk); ioctl_rom=0; repeat(20) @(posedge clk);
        $display("--- download done, reading back ---");
        do_read(18'h023608, 32'h170EB025);
        do_read(18'h023609, 32'h5A468686);
        $display("--- done ---");
        $finish;
    end
    initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
