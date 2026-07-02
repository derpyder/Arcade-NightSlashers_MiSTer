/*  This file is part of JTNSLASHER (Night Slashers core).
    JTNSLASHER program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTNSLASHER program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTNSLASHER.  If not, see <http://www.gnu.org/licenses/>.

    Date: 2026-06-05
*/

// Night Slashers sound subsystem.
// Z80B @ 3.58 MHz + YM2151 + 2x OKI M6295 (per MAME deco32.c).
//
// Z80 sound map (nslasher_sound):
//   0000-7FFF  ROM        (audiocpu region, 64 KB)
//   8000-87FF  RAM        (2 KB, bundled in jtframe_sysz80, RAM_AW=11)
//   A000-A001  YM2151
//   B000       OKI #1
//   C000       OKI #2
//   D000       sound latch read (also clears cmd-IRQ)
//
// Z80 INT sources OR'd (active-low int_n):
//   bit 0 : YM2151 irq_n  (level-follows)
//   bit 1 : snd_req from main CPU's $200700 write
//           (rising-edge sets a FF; cleared by Z80 read of $D000)
//
// OKI sample banking: YM2151 ct1/ct2 outputs gate the high address bit
// (oki1_addr[18] = ct1, oki2_addr[18] = ct2). Matches the MAME
// sound_bankswitch_w handler that the original YM2151 interface installs.

module jtnslasher_snd(
    input               rst,
    input               clk,

    input               cen_fm,     // 3.58 MHz   — Z80 + YM2151 main cen
    input               cen_fm2,    // 1.79 MHz   — YM2151 cen_p1
    input               cen_oki1,   // 1.007 MHz  — OKI #1
    input               cen_oki2,   // 2.014 MHz  — OKI #2

    // From main CPU (sound latch + IRQ request)
    input               snd_req,    // rising edge = $200700 write
    input       [ 7:0]  snd_latch,

    // Z80 program ROM (SDRAM, bank 1 slot 1)
    output      [15:0]  rom_addr,
    output reg          rom_cs,
    input       [ 7:0]  rom_data,
    input               rom_ok,

    // OKI #1 sample ROM (SDRAM, bank 1 slot 2) — banked via ct1
    output      [18:0]  oki1_addr,
    output              oki1_cs,
    input       [ 7:0]  oki1_data,
    input               oki1_ok,

    // OKI #2 sample ROM (SDRAM, bank 1 slot 3) — banked via ct2
    output      [18:0]  oki2_addr,
    output              oki2_cs,
    input       [ 7:0]  oki2_data,
    input               oki2_ok,

    // Audio outputs to JTFRAME audio mixer (see mem.yaml audio:)
    output signed [15:0] fm_l, fm_r,
    output signed [13:0] pcm1,         // -> game.v wires to top-level oki1
    output signed [13:0] pcm2          // -> game.v wires to top-level oki2
);

`ifndef NOSOUND

wire [15:0] A;
wire        mreq_n, iorq_n, rfsh_n, m1_n, rd_n, wr_n;
wire [ 7:0] cpu_dout, ram_dout, fm_dout, oki1_dout, oki2_dout;
reg  [ 7:0] cpu_din;
reg         ram_cs, fm_cs, oki1_io_cs, oki2_io_cs, latch_cs;
wire        ct1, ct2;            // YM2151 port outputs (OKI bank bits)
wire        fm_irq_n;
wire        rom_good = rom_ok | ~rom_cs;
wire [17:0] oki1_chip_addr, oki2_chip_addr;

// --- Address decode (combinational; rom_cs is registered separately) ---
always @(*) begin
    ram_cs     = 0;
    fm_cs      = 0;
    oki1_io_cs = 0;
    oki2_io_cs = 0;
    latch_cs   = 0;
    if (!mreq_n && rfsh_n) begin
        casez (A[15:12])
            4'b0???: ;                              // 0000-7FFF ROM (see rom_cs reg)
            4'b1000: ram_cs     = ~A[11];           // 8000-87FF RAM (jtframe_sysz80 internal)
            4'b1010: fm_cs      = 1'b1;             // A000-A001 YM2151
            4'b1011: oki1_io_cs = 1'b1;             // B000 OKI #1
            4'b1100: oki2_io_cs = 1'b1;             // C000 OKI #2
            4'b1101: latch_cs   = 1'b1;             // D000 latch read (clears cmd-IRQ)
            default: ;
        endcase
    end
end

// IO-SPACE ROM WINDOW (audio-loop fix, 2026-06-09): MAME nslasher_io_sound maps the FULL 64 KB
// audiocpu ROM into the Z80 IO space (deco32.c:1016 `AM_RANGE(0x0000,0xffff) AM_ROM`). The sound
// ROM's UPPER 32 KB (music/sequence data, 30914/32768 bytes nonzero) is NOT reachable through the
// memory map (only 0000-7FFF is ROM there) — the driver fetches it with IN r,(C) (full 16-bit port
// = BC; opcodes at z80 0x0508/0x0574/0x0EA5). Returning 8'hff for IO reads (the old behavior) fed
// the sequencer garbage -> "music loops unintelligibly, never stops". An IO READ (iorq, rd, NOT the
// m1 interrupt-ack cycle) now fetches ROM at the port address through the same SDRAM slot + wait.
wire io_rom_rd = !iorq_n && m1_n && !rd_n;
always @(posedge clk) begin
    rom_cs <= (!mreq_n && rfsh_n && !A[15]) || io_rom_rd;
end

assign rom_addr = A;

always @(*) begin
    cpu_din = rom_cs     ? rom_data   :
              ram_cs     ? ram_dout   :
              fm_cs      ? fm_dout    :
              oki1_io_cs ? oki1_dout  :
              oki2_io_cs ? oki2_dout  :
              latch_cs   ? snd_latch  :
                           8'hff;
end

// --- IRQ logic ---
//   fm_irq_n  : level-follows YM2151 (active-low)
//   irq_cmd_n : SR-FF set on snd_req rising edge, cleared by D000 read
// Z80 int_n is the AND of the two.

reg snd_req_q, irq_cmd_n;
wire int_n;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        snd_req_q <= 1'b0;
        irq_cmd_n <= 1'b1;
    end else begin
        snd_req_q <= snd_req;
        if      (snd_req & ~snd_req_q) irq_cmd_n <= 1'b0;  // set
        else if (latch_cs)             irq_cmd_n <= 1'b1;  // clear
    end
end

assign int_n = fm_irq_n & irq_cmd_n;

// --- Z80 CPU + 2KB RAM (jtframe wrapper, RAM_AW=11 -> 2048 bytes) ---
jtframe_sysz80 #(.RAM_AW(11)) u_cpu(
    .rst_n      ( ~rst        ),
    .clk        ( clk         ),
    .cen        ( cen_fm      ),   // 3.58 MHz
    .cpu_cen    (             ),
    .int_n      ( int_n       ),
    .nmi_n      ( 1'b1        ),
    .busrq_n    ( 1'b1        ),
    .m1_n       ( m1_n        ),
    .mreq_n     ( mreq_n      ),
    .iorq_n     ( iorq_n      ),
    .rd_n       ( rd_n        ),
    .wr_n       ( wr_n        ),
    .rfsh_n     ( rfsh_n      ),
    .halt_n     (             ),
    .busak_n    (             ),
    .A          ( A           ),
    .cpu_din    ( cpu_din     ),
    .cpu_dout   ( cpu_dout    ),
    .ram_dout   ( ram_dout    ),
    .ram_cs     ( ram_cs      ),
    .rom_cs     ( rom_cs      ),
    .rom_ok     ( rom_good    )
);

// --- YM2151 ---
jt51 u_jt51(
    .rst        ( rst         ),
    .clk        ( clk         ),
    .cen        ( cen_fm      ),
    .cen_p1     ( cen_fm2     ),
    .cs_n       ( ~fm_cs      ),
    .wr_n       ( wr_n        ),
    .a0         ( A[0]        ),
    .din        ( cpu_dout    ),
    .dout       ( fm_dout     ),
    .ct1        ( ct1         ),   // -> oki1 bank
    .ct2        ( ct2         ),   // -> oki2 bank
    .irq_n      ( fm_irq_n    ),
    .sample     (             ),
    .left       (             ),
    .right      (             ),
    .xleft      ( fm_l        ),
    .xright     ( fm_r        )
);

// --- OKI #1  (1.007 MHz, pin7=high via ss=1, banked) ---
jt6295 u_oki1(
    .rst        ( rst             ),
    .clk        ( clk             ),
    .cen        ( cen_oki1        ),
    .ss         ( 1'b1            ),
    .wrn        ( ~(oki1_io_cs & ~wr_n) ),
    .din        ( cpu_dout        ),
    .dout       ( oki1_dout       ),
    .rom_addr   ( oki1_chip_addr  ),
    .rom_data   ( oki1_data       ),
    .rom_ok     ( oki1_ok         ),
    .sound      ( pcm1            ),
    .sample     (                 )
);
assign oki1_addr = { ct1, oki1_chip_addr };
assign oki1_cs   = 1'b1;          // keep sample stream fed

// --- OKI #2  (2.014 MHz, banked) ---
jt6295 u_oki2(
    .rst        ( rst             ),
    .clk        ( clk             ),
    .cen        ( cen_oki2        ),
    .ss         ( 1'b1            ),
    .wrn        ( ~(oki2_io_cs & ~wr_n) ),
    .din        ( cpu_dout        ),
    .dout       ( oki2_dout       ),
    .rom_addr   ( oki2_chip_addr  ),
    .rom_data   ( oki2_data       ),
    .rom_ok     ( oki2_ok         ),
    .sound      ( pcm2            ),
    .sample     (                 )
);
assign oki2_addr = { ct2, oki2_chip_addr };
assign oki2_cs   = 1'b1;

`else // NOSOUND
assign  rom_addr  = 16'h0;
assign  oki1_addr = 19'h0;
assign  oki2_addr = 19'h0;
assign  oki1_cs   = 1'b0;
assign  oki2_cs   = 1'b0;
assign  fm_l      = 16'sd0;
assign  fm_r      = 16'sd0;
assign  pcm1      = 14'sd0;
assign  pcm2      = 14'sd0;
initial rom_cs    = 1'b0;
`endif

endmodule
