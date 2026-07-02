`timescale 1ns/1ps
// jtnslasher_main (Amber a23) bring-up testbench (M2a).
//  - boots test_arm.hex, paces a23 at cen_arm (/7 of 48 MHz)
//  - behavioral 32-bit ROM + byte-addressable work RAM
//  - self-checks: a23 fetches/runs, ALU+STR result in RAM, LDR worked, soundlatch write
module tb_main;
    reg         clk = 0, rst = 1;
    reg         cen_arm = 0;
    reg         vbl_irq = 0;
    wire        vbl_ack;
    wire [21:0] rom_addr;  wire rom_cs;  reg [31:0] rom_data; reg rom_ok = 0;
    wire [16:2] ram_addr;  wire ram_cs;  wire [3:0] ram_we; wire [31:0] ram_dout;
    reg  [31:0] ram_data;  reg ram_ok = 0;
    wire [ 7:0] snd_latch; wire snd_req;
    wire [31:0] dbg_pc_addr;

    always #10.416 clk = ~clk;            // ~48 MHz
    reg [2:0] cc = 0;                     // cen_arm = /7  (~6.86 MHz, fine for functional)
    always @(posedge clk) begin
        cen_arm <= 0;
        if (cc == 6) begin cc <= 0; cen_arm <= 1; end else cc <= cc + 1'b1;
    end

    // ---- behavioral program ROM (32-bit words) ----
    reg [31:0] rom [0:1023];
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) rom[i] = 32'h0;
        $readmemh("test_arm.hex", rom);
    end
    always @(posedge clk) begin
        rom_data <= rom[rom_addr[9:0]];
        rom_ok   <= rom_cs;
    end

    // ---- behavioral work RAM (128 KB, byte-addressable) ----
    reg [31:0] wram [0:32767];
    always @(posedge clk) begin
        ram_ok <= ram_cs;
        if (ram_cs) begin
            if (ram_we[0]) wram[ram_addr][ 7: 0] <= ram_dout[ 7: 0];
            if (ram_we[1]) wram[ram_addr][15: 8] <= ram_dout[15: 8];
            if (ram_we[2]) wram[ram_addr][23:16] <= ram_dout[23:16];
            if (ram_we[3]) wram[ram_addr][31:24] <= ram_dout[31:24];
            ram_data <= wram[ram_addr];
        end
    end

    jtnslasher_main u_dut(
        .rst(rst), .clk(clk), .cen_arm(cen_arm),
        .vbl_irq(vbl_irq), .vbl_ack(vbl_ack),
        .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_data(rom_data), .rom_ok(rom_ok),
        .ram_addr(ram_addr), .ram_cs(ram_cs), .ram_we(ram_we), .ram_dout(ram_dout),
        .ram_data(ram_data), .ram_ok(ram_ok),
        .snd_latch(snd_latch), .snd_req(snd_req),
        .dbg_pc_addr(dbg_pc_addr)
    );

    // ---- monitors ----
    integer fetches = 0; reg [21:0] lastf = 22'h3fffff;
    reg sndlatched = 0; reg [7:0] sndval = 0;
    always @(posedge clk) begin
        if (rom_cs && rom_addr != lastf) begin lastf <= rom_addr; fetches <= fetches + 1; end
        if (snd_req) begin sndlatched <= 1; sndval <= snd_latch;
            $display("[%7t] SND_REQ  latch=%02x", $time, snd_latch); end
        if (ram_cs && |ram_we)
            $display("[%7t] RAM wr @ %06x mask=%b data=%08x", $time, {7'h08,ram_addr,2'b00}, ram_we, ram_dout);
    end

    initial begin
        $dumpfile("tb_main.vcd"); $dumpvars(0, tb_main);
        rst = 1; repeat (80) @(posedge clk); rst = 0;
        $display("--- reset released, booting a23 ---");
        repeat (6000) @(posedge clk);
        $display("==================== RESULTS ====================");
        $display("fetches=%0d", fetches);
        $display("RAM[0x100000]=%08x (expect 00000046)", wram[0]);
        $display("RAM[0x100004]=%08x (expect 00000047)", wram[1]);
        $display("soundlatch: got=%0d val=%02x (expect 1, 42)", sndlatched, sndval);
        if (fetches > 5)            $display("PASS: a23 is fetching/running"); else $display("FAIL: a23 not fetching");
        if (wram[0] == 32'h46)      $display("PASS: ALU + STR  (RAM[0x100000]=0x46)"); else $display("FAIL: RAM[0]=%08x", wram[0]);
        if (wram[1] == 32'h47)      $display("PASS: LDR + ADD + STR  (RAM[0x100004]=0x47)"); else $display("FAIL: RAM[1]=%08x", wram[1]);
        if (sndlatched && sndval==8'h42) $display("PASS: soundlatch write (main->snd path)"); else $display("FAIL: soundlatch");
        $display("=================================================");
        $finish;
    end
    initial begin #4_000_000; $display("TIMEOUT"); $finish; end
endmodule
