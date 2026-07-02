`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// jtnslasher_snd standalone testbench (M1.5)
//   - boots the hand-assembled Z80 test program (test_snd.hex)
//   - generates approximate cen_fm / cen_fm2 / cen_oki1 / cen_oki2 from a 48 MHz clk
//   - behavioral snd ROM (Z80 program) + stubbed OKI sample ROMs
//   - pulses snd_req with a latch byte; verifies the IM1 IRQ -> D000 read path
//   - self-checks: Z80 runs, YM2151 register writes occur, OKI writes occur,
//     latch is read after snd_req. PASS/FAIL printed at the end.
// ---------------------------------------------------------------------------
module tb_snd;
    reg         clk = 0, rst = 1;
    reg         cen_fm = 0, cen_fm2 = 0, cen_oki1 = 0, cen_oki2 = 0;
    reg         snd_req = 0;
    reg  [ 7:0] snd_latch = 0;

    wire [15:0] rom_addr;
    wire        rom_cs;
    reg  [ 7:0] rom_data;
    reg         rom_ok = 1;
    wire [18:0] oki1_addr, oki2_addr;
    wire        oki1_cs,  oki2_cs;
    reg  [ 7:0] oki1_data, oki2_data;
    reg         oki1_ok = 1, oki2_ok = 1;
    wire signed [15:0] fm_l, fm_r;
    wire signed [13:0] pcm1, pcm2;

    // ---- 48 MHz clock ----
    always #10.416 clk = ~clk;   // ~48 MHz

    // ---- clock enables (approximate integer dividers) ----
    reg [4:0] cfm = 0; reg fmhalf = 0;
    always @(posedge clk) begin
        cen_fm <= 0; cen_fm2 <= 0;
        if (cfm == 12) begin
            cfm    <= 0;
            cen_fm <= 1;
            fmhalf <= ~fmhalf;
            if (~fmhalf) cen_fm2 <= 1;   // half rate, aligned to cen_fm
        end else cfm <= cfm + 1'b1;
    end
    reg [5:0] co1 = 0;
    always @(posedge clk) begin
        cen_oki1 <= 0;
        if (co1 == 47) begin co1 <= 0; cen_oki1 <= 1; end else co1 <= co1 + 1'b1;
    end
    reg [4:0] co2 = 0;
    always @(posedge clk) begin
        cen_oki2 <= 0;
        if (co2 == 23) begin co2 <= 0; cen_oki2 <= 1; end else co2 <= co2 + 1'b1;
    end

    // ---- behavioral sound ROM (Z80 program) ----
    reg [7:0] sndrom [0:65535];
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) sndrom[i] = 8'h00;
        $readmemh("test_snd.hex", sndrom);
    end
    always @(posedge clk) begin
        rom_data <= sndrom[rom_addr];
        rom_ok   <= rom_cs;   // ready next cycle after a request
    end

    // ---- stubbed OKI sample ROMs (ramp so reads are observable) ----
    always @(posedge clk) begin
        oki1_data <= oki1_addr[7:0];
        oki2_data <= oki2_addr[7:0];
    end

    // ---- DUT ----
    jtnslasher_snd u_dut(
        .rst       ( rst       ),
        .clk       ( clk       ),
        .cen_fm    ( cen_fm    ),
        .cen_fm2   ( cen_fm2   ),
        .cen_oki1  ( cen_oki1  ),
        .cen_oki2  ( cen_oki2  ),
        .snd_req   ( snd_req   ),
        .snd_latch ( snd_latch ),
        .rom_addr  ( rom_addr  ),
        .rom_cs    ( rom_cs    ),
        .rom_data  ( rom_data  ),
        .rom_ok    ( rom_ok    ),
        .oki1_addr ( oki1_addr ),
        .oki1_cs   ( oki1_cs   ),
        .oki1_data ( oki1_data ),
        .oki1_ok   ( oki1_ok   ),
        .oki2_addr ( oki2_addr ),
        .oki2_cs   ( oki2_cs   ),
        .oki2_data ( oki2_data ),
        .oki2_ok   ( oki2_ok   ),
        .fm_l      ( fm_l      ),
        .fm_r      ( fm_r      ),
        .pcm1      ( pcm1      ),
        .pcm2      ( pcm2      )
    );

    // ---- monitors (hierarchical probes into the DUT) ----
    integer ym_writes  = 0;
    integer oki_writes = 0;
    integer latch_reads = 0;
    integer fetches    = 0;
    reg     ym_w_l = 0, oki_w_l = 0, lat_l = 0;
    reg [15:0] last_fetch = 16'hffff;

    always @(posedge clk) begin
        // count distinct Z80 fetches (rom address changes while fetching)
        if (rom_cs && rom_addr != last_fetch) begin last_fetch <= rom_addr; fetches <= fetches + 1; end

        // YM2151 write: fm_cs & ~wr_n, rising edge
        if (u_dut.fm_cs && !u_dut.wr_n && !ym_w_l) begin
            ym_writes <= ym_writes + 1;
            $display("[%7t] YM2151 write  a0=%b  data=%02x", $time, u_dut.A[0], u_dut.cpu_dout);
        end
        ym_w_l <= u_dut.fm_cs && !u_dut.wr_n;

        // OKI #1 write: oki1_io_cs & ~wr_n, rising edge
        if (u_dut.oki1_io_cs && !u_dut.wr_n && !oki_w_l) begin
            oki_writes <= oki_writes + 1;
            $display("[%7t] OKI1  write  data=%02x", $time, u_dut.cpu_dout);
        end
        oki_w_l <= u_dut.oki1_io_cs && !u_dut.wr_n;

        // latch read: latch_cs & ~rd_n, rising edge
        if (u_dut.latch_cs && !u_dut.rd_n && !lat_l) begin
            latch_reads <= latch_reads + 1;
            $display("[%7t] LATCH read    -> %02x  (cmd-IRQ should clear)", $time, snd_latch);
        end
        lat_l <= u_dut.latch_cs && !u_dut.rd_n;
    end

    // ---- stimulus ----
    integer fetches_at_cmd;
    initial begin
        $dumpfile("tb_snd.vcd");
        $dumpvars(0, tb_snd);
        rst = 1; snd_req = 0; snd_latch = 8'h00;
        repeat (40) @(posedge clk);
        rst = 0;
        $display("--- reset released, booting Z80 ---");

        // let the Z80 boot + run its init (YM + OKI writes)
        repeat (8000) @(posedge clk);
        fetches_at_cmd = fetches;
        $display("--- after boot: fetches=%0d ym_writes=%0d oki_writes=%0d ---",
                 fetches, ym_writes, oki_writes);

        // send a sound command (main-CPU style): set latch, pulse snd_req
        snd_latch = 8'h42;
        @(posedge clk) snd_req = 1;
        repeat (4) @(posedge clk);
        snd_req = 0;
        $display("--- snd_req pulsed with latch=0x42, waiting for IM1 IRQ + D000 read ---");

        repeat (8000) @(posedge clk);

        // ---- verdict ----
        $display("====================================================");
        $display("fetches=%0d  ym_writes=%0d  oki_writes=%0d  latch_reads=%0d",
                 fetches, ym_writes, oki_writes, latch_reads);
        $display("fm_l=%0d fm_r=%0d pcm1=%0d pcm2=%0d", fm_l, fm_r, pcm1, pcm2);
        if (fetches > 100)        $display("PASS: Z80 is fetching/running");        else $display("FAIL: Z80 not running");
        if (ym_writes >= 4)       $display("PASS: YM2151 received %0d register writes", ym_writes); else $display("FAIL: too few YM writes (%0d)", ym_writes);
        if (oki_writes >= 2)      $display("PASS: OKI received %0d writes", oki_writes);            else $display("FAIL: too few OKI writes (%0d)", oki_writes);
        if (latch_reads >= 1)     $display("PASS: latch read after snd_req (IRQ path works)");      else $display("FAIL: no latch read (IRQ path broken)");
        $display("====================================================");
        $finish;
    end

    // safety timeout
    initial begin
        #2_000_000;   // 2 ms
        $display("TIMEOUT");
        $finish;
    end
endmodule
