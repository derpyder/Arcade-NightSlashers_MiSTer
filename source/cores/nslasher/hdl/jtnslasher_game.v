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

// Top-level Night Slashers game module (task #7d — full integration).
//   jtframe_vtimer  : 320x240 timing (LHBL/LVBL/HS/VS out; vrender/hdump/vbl/vbl_irq)
//   jtnslasher_main : ARM (deco156 at-fetch) + 104 I/O + 93C46 EEPROM + VBL IRQ
//   jtnslasher_vmem : deco32 video RAMs + render core (jtnslasher_video)
//   jtnslasher_sdram: gfx fetch adapter (tilemap decrypt wrappers + obj at-fetch reshuffle)
//   jtnslasher_snd  : Z80 + YM2151 + 2x OKI M6295
//   jtnslasher_dwnld: ROM download post_addr (BA2 gfx reorder; rest identity)
// Work RAM = BRAM (128 KB, 32-bit byte-writable) — the SDRAM 32-bit RW slot only writes 16 bits, and
// the CPU hits work RAM constantly, so it lives in BRAM. The mem.yaml BA0 `ram` SDRAM bank is tied off
// (TODO cleanup: drop it / move to a bram: entry once the bank renumber is reconciled).

module jtnslasher_game(
    `include "jtframe_game_ports.inc"
);

// ================= video timing =================
wire [8:0] vdump, vrender, vrender1, hdump;
wire       Hinit, Vinit;
jtframe_vtimer #(
    // CANVAS REALIGN: MAME nslasher visible area = y[8..247] (MDRV_SCREEN_VISIBLE_AREA(0,319, 8,247)); ours was
    // [0..239] = 8 lines too high -> top border shown, bottom credits clipped. Active -> [8,247] (VB low at 248,
    // high at 7 => active 8..247 = 240 lines = JTFRAME_HEIGHT). VS moved into the [248..263] blank. Total stays
    // 264 lines (V_START 0, VCNT_END 263) so the 59.19Hz / "speed 100%" is unchanged.
    .V_START(9'd0), .VB_START(9'd248), .VB_END(9'd7), .VS_START(9'd251), .VS_END(9'd254), .VCNT_END(9'd263),
    .HB_END(9'd383), .HB_START(9'd320), .HS_START(9'd340), .HS_END(9'd367),
    .H_VB(9'd320), .H_VS(9'd340), .H_VNEXT(9'd340), .HINIT(9'd340),
    .HJUMP(1'd0), .HCNT_END(9'd383), .HCNT_START(9'd0)
) u_vtimer(
    .clk(clk), .pxl_cen(pxl_cen),
    .vdump(vdump), .vrender(vrender), .vrender1(vrender1),
    .H(hdump), .Hinit(Hinit), .Vinit(Vinit),
    .LHBL(LHBL), .LVBL(LVBL), .HS(HS), .VS(VS) );

// vbl level (active-high) + 1-clk IRQ pulse at the start of vblank (LVBL falling edge)
reg LVBLl; wire vbl = ~LVBL; reg vbl_irq;
always @(posedge clk) begin LVBLl <= LVBL; vbl_irq <= LVBLl & ~LVBL; end

// ================= inputs: JTFRAME -> deco32 in0/in1 (active-LOW, idle ffff) =================
// EXACT deco32.c nslasher map (INPUT_PORTS, lines 1416-1452). JTFRAME joysticks are active-HIGH with
// default order bit0=Right,1=Left,2=Down,3=Up,4=B1,5=B2,6=B3 (jtframe_joysticks.v:258) -> invert + reorder.
//   IN0: [0]Up [1]Down [2]Left [3]Right [4]B1 [5]B2 [6]B3 [7]Start1 | [8..15] same for P2
//   IN1: [0]Coin1 [1]Coin2 [2]Service1 [3]Service(dip) [4]VBLANK(overridden in main) [5..7]unused | [8..15]P3
// per-player pack: {Start, B3,B2,B1, Right,Left,Down,Up} = {cab,j[6:4],j[0],j[1],j[2],j[3]}
// POLARITY FIX (2026-06-07): JTFRAME game_joy/cab_1p/coin are ALREADY ACTIVE-LOW (idle all-1s; jtframe_
// joysticks.v reset=3ff/4'hf, `game_joy<=~(board_joy|...)`), and deco32 IN0/IN1 are ALSO active-low (idle
// 0xFFFF; the game does `eor #0xFFFF` internally). The old outer `~` DOUBLE-inverted -> idle read as
// ALL-PRESSED -> the 0x2150 boot start-gate saw both Starts "held" -> wait-loop 0x21C8 -> FROZEN on the
// version screen (PROBE #5/#6: 0x100284 never armed, 0x100100 bit3 stuck = inside the gate routine). The
// active-LOW signals map DIRECTLY (no invert); forced service/unused bits = 1 (inactive in active-low).
// nf26 service-menu QoL: the I/O CHECK screen exits on P1 BUTTON1 + P2 BUTTON1 pressed TOGETHER (user-
// confirmed on the cab) — impossible with one pad and no keyboard. While the TEST switch is active (OSD
// Service mode ON, dip_test LOW), P1's BUTTON1 and START also assert P2's BUTTON1 and START (active-low
// AND = pressed when either is pressed). Gameplay path unchanged (dip_test HIGH -> plain P2 inputs).
// Side effect only inside the service menu: the input-test display mirrors P1 presses onto P2.
wire p2_start_svc = dip_test ? cab_1p[1]    : (cab_1p[1]    & cab_1p[0]);
wire p2_b1_svc    = dip_test ? joystick2[4] : (joystick2[4] & joystick1[4]);
wire [15:0] in0 = { p2_start_svc, joystick2[6:5], p2_b1_svc, joystick2[0],joystick2[1],joystick2[2],joystick2[3],
                    cab_1p[0], joystick1[6:4], joystick1[0],joystick1[1],joystick1[2],joystick1[3] };
wire [15:0] in1 = { cab_1p[2], joystick3[6:4], joystick3[0],joystick3[1],joystick3[2],joystick3[3], // [15:8] P3
                    3'b111,                     // [7:5] unused = INACTIVE (active-low)
                    1'b1,                       // [4] VBLANK — overridden in jtnslasher_main (active-high)
                    dip_test,                   // [3] TEST switch (PORT_SERVICE_NO_TOGGLE) <- OSD "Service mode"
                    service,                    // [2] Service1 coin <- jtframe service input
                    coin[1],                    // [1] Coin2 (active-low, direct)
                    coin[0] };                  // [0] Coin1 (active-low, direct)
// nf25: bits [3:2] LIVE. nslasher has NO dipswitches (MAME nslasher input = EEPROM-configured); all game
// settings (coinage/difficulty/lives/demo sound) are set in the operator SERVICE MENU entered via the TEST
// switch. dip_test = ~status[10] & game_test (JTFRAME_OSD_TEST, jtframe_dip.v:87, active-low = matches
// PORT_SERVICE_NO_TOGGLE IP_ACTIVE_LOW); default OSD-off => 1 = inactive => still boots to GAME. Settings
// save to the 93C46 (BRAM) => persist per session; cross-power NVRAM dump is still deferred.

// ================= main CPU =================
wire [21:0] main_rom_a;
wire [16:2] wram_addr;
wire [ 3:0] wram_we;
wire [31:0] wram_dout, wram_data;
wire        wram_cs, wram_ok;
wire [23:0] cpu_addr;
wire [31:0] cpu_dout;
wire [ 3:0] cpu_we;
wire [ 2:0] pri;
wire [ 7:0] snd_latch;
wire        snd_req, vbl_ack;
wire [31:0] dbg_pc;
wire [31:0] dbg_romdec;
wire [19:0] dbg_pcmax, dbg_pcnow;
wire [23:0] dbg_poll_a;
wire [31:0] dbg_poll_d;
wire [31:0] dbg_snd;
wire [15:0] dbg_virq_cnt, dbg_irq_cnt;
wire [19:0] dbg_chits_f, dbg_cmiss_f;   // DIAG: ARM ROM-cache hits/misses per frame (on-cab probe)
wire [23:0] dbg_vid_a;
wire [15:0] dbg_vidrd_cnt;
wire [31:0] dbg_ctl;
wire [15:0] dbg_vidwr_cnt, dbg_vidwr_d, dbg_sndwr_cnt;
wire [23:0] dbg_vidwr_a;
wire [15:0] dbg_pfnz_cnt, dbg_pfnz_d;   // DIAG probe #1: non-zero PF-write capture
wire [23:0] dbg_pfnz_a, dbg_anynz_a;
wire [15:0] dbg_pal_cnt, dbg_pfbg_cnt, dbg_ctl_cnt, dbg_ctl12_5, dbg_ctl34_5;  // DIAG probe #2: per-region init
wire [18:0] dbg_cap_addr;   wire [31:0] dbg_cap_dec;   // DIAG probe #3: gfx-fetch capture
wire [19:0] dbg_cap_sdaddr; wire [15:0] dbg_cap_sddata; wire dbg_captured;

jtnslasher_main u_main(
    .rst(rst), .clk(clk), .cen_arm(cen_arm),
    .in0(in0), .in1(in1),
    .vbl(vbl), .vbl_irq(vbl_irq), .vbl_ack(vbl_ack),
    .rom_addr(main_rom_a), .rom_cs(main_cs), .rom_data(main_data), .rom_ok(main_ok),
    .ram_addr(wram_addr), .ram_cs(wram_cs), .ram_we(wram_we), .ram_dout(wram_dout), .ram_data(wram_data), .ram_ok(wram_ok),
    .snd_latch(snd_latch), .snd_req(snd_req),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_we(cpu_we), .pri(pri),
    .dbg_pc_addr(dbg_pc), .dbg_romdec(dbg_romdec),
    .dbg_pcmax(dbg_pcmax), .dbg_pcnow(dbg_pcnow), .dbg_poll_a(dbg_poll_a), .dbg_poll_d(dbg_poll_d),
    .dbg_virq_cnt(dbg_virq_cnt), .dbg_irq_cnt(dbg_irq_cnt),
    .dbg_chits_f(dbg_chits_f), .dbg_cmiss_f(dbg_cmiss_f),
    .dbg_vid_a(dbg_vid_a), .dbg_vidrd_cnt(dbg_vidrd_cnt), .dbg_ctl(dbg_ctl),
    .dbg_vidwr_cnt(dbg_vidwr_cnt), .dbg_vidwr_a(dbg_vidwr_a), .dbg_vidwr_d(dbg_vidwr_d), .dbg_sndwr_cnt(dbg_sndwr_cnt),
    .dbg_pfnz_cnt(dbg_pfnz_cnt), .dbg_pfnz_a(dbg_pfnz_a), .dbg_pfnz_d(dbg_pfnz_d), .dbg_anynz_a(dbg_anynz_a),
    .dbg_pal_cnt(dbg_pal_cnt), .dbg_pfbg_cnt(dbg_pfbg_cnt), .dbg_ctl_cnt(dbg_ctl_cnt),
    .dbg_ctl12_5(dbg_ctl12_5), .dbg_ctl34_5(dbg_ctl34_5) );
assign main_addr = main_rom_a[17:0];    // 1 MB ARM ROM region (18-bit 32-bit-word addr)

// ---- work RAM (BRAM, 128 KB, 32-bit, per-byte writes) ----
reg wram_okr;
always @(posedge clk) wram_okr <= wram_cs;
assign wram_ok = wram_okr;
genvar wi;
generate for( wi=0; wi<4; wi=wi+1 ) begin: g_wram
    jtframe_dual_ram #(.DW(8),.AW(15)) u_wram(
        .clk0(clk), .addr0(wram_addr), .data0(wram_dout[wi*8+:8]), .we0(wram_we[wi]), .q0(wram_data[wi*8+:8]),
        .clk1(clk), .addr1(15'd0), .data1(8'd0), .we1(1'b0), .q1() );
end endgenerate

// ===== STATE PROBE (DIAG) =====
// PROBE #5 result (HW, 2026-06-07): 0x100284 (attract-engine ramp, word 0xA1) reads FLAT 0 with change-count
// 0 -> the engine NEVER arms; cab is frozen at the pre-f4 equivalent (title committed to PF1, sound issuing,
// CPU decoding OK). 0x100014 branch var = 0 (matches MAME golden).
// PROBE #7 (2026-06-07): PC STICKY-FLAG TRACER. Full dec.bin RE + MAME count_exec proved the BOOT
// SIGNATURE: the attract engine arms ONCE at boot via routine 0x2150 (a start-gate). It reads P1/P2 Start
// (0x100010/11 bit7); if both held -> WAIT-LOOP 0x21C8 forever (no arm); else clears 0x100100 bit3
// (0x21E4) + the arm (0x48E4) runs. MAME golden exec: 2150=1, gate(0x21A8)=1, WAIT(0x21C8)=0, armRtn
// (0x21E4)=1, arm(0x48E4)=1. Latch a sticky flag when the ARM ever FETCHES each PC (main_rom_a = 32-bit
// WORD addr; PC_byte = main_rom_a<<2). Cab signature vs golden localises the divergence in ONE read.
reg pcf_2150=1'b0, pcf_gate=1'b0, pcf_wait=1'b0, pcf_armrtn=1'b0, pcf_arm=1'b0;
reg [7:0] sp_gate100=8'd0, sp_ph103=8'd0, sp_ramp=8'd0;
// PROBE #8 (2026-06-07): IN1 RISING-EDGE WORD @0x100014 — THE FLOOD GATE.
// FLOOD_ROOT_CAUSE.md: the ARM re-runs reset (`b 0x50`@0xA48) ~once/frame because work-RAM 0x100014 bit3
// reads SET on the cab where MAME keeps it 0. 0x100014 is the IN1 just-pressed edge word (active_now &
// ~active_prev, written by the input routine around 0x1D00/0x1DC4); the coin/sound dispatcher fn@0x1E74
// tests its edge bits 0/1/2 (Coin1/Coin2/Service1) and re-issues the sound cmd on an edge. So a SPURIOUS
// per-frame edge on coin[0]/coin[1] sets the byte != 0 -> bit3 path / endless sound.
// 0x100014 = byte 0x14 in WRAM = word 0x14>>2 = 0x05, byte-lane 0x14&3 = 0 -> wram_addr==15'h005, lane0.
// Capture the LOW NIBBLE [3:0]: bit3 = the `b 0x50` restart gate (`tst #8`); bits[2:0] = Coin1/Coin2/
// Service1 edges the dispatcher tests. MAME GOLDEN = 0 for the whole nibble (w100014.txt: 0x100014 written
// twice, value 0x00000000, bit3 never set). So row3 sp_in1edge MUST READ 0 on a healthy cab.
reg [3:0] sp_in1edge=4'd0;        // sticky-OR of every low-nibble value the ARM ever STORES to 0x100014
always @(posedge clk) begin
    if( main_cs ) begin                                     // ARM ROM fetch (instruction or literal)
        // detection words chosen in NON-ALIASING 16-byte cache lines (4 words/line, demand-fill):
        if( main_rom_a[17:0]==18'h00854 ) pcf_2150   <= 1'b1; // 0x2150 (line 2150) gate-routine entry
        if( main_rom_a[17:0]==18'h0086A ) pcf_gate   <= 1'b1; // 0x21A8 (line 21A0) gate input-check
        if( main_rom_a[17:0]==18'h00872 ) pcf_wait   <= 1'b1; // 0x21C8 (line 21C0) WAIT-LOOP — reached only if both Starts held
        if( main_rom_a[17:0]==18'h0087C ) pcf_armrtn <= 1'b1; // 0x21F0 (line 21F0) gate-PASS (clear bit3) — away from 0x21E0/0x21E4 line
        if( main_rom_a[17:0]==18'h01239 ) pcf_arm    <= 1'b1; // 0x48E4 (line 48E0) arm routine
    end
    if( wram_addr==15'h040 ) begin                          // 0x100100 (lane0) / 0x100103 (lane3)
        if( wram_we[0] ) sp_gate100 <= wram_dout[ 7: 0];
        if( wram_we[3] ) sp_ph103   <= wram_dout[31:24];
    end
    if( wram_we[0] && wram_addr==15'h0A1 ) sp_ramp <= wram_dout[7:0];  // 0x100284 (confirm 0/unarmed)
    // PROBE #8: sticky-OR the IN1 edge word's low nibble. STICKY (never self-clears) so a single spurious
    // 1-frame edge LATCHES and is readable even though the ARM rewrites 0x100014=0 most frames. golden=0.
    if( wram_we[0] && wram_addr==15'h005 ) sp_in1edge <= sp_in1edge | wram_dout[3:0]; // 0x100014 lane0
end

// ================= video memory + render core =================
wire        pf1_cs,pf2_cs,pf3_cs,pf4_cs,obj0e_cs,obj1e_cs;   // obj0e_* = engine side (vs framework obj0_* port)
wire [18:0] pf1_a,pf2_a,pf3_a,pf4_a;
wire [20:0] obj0e_a,obj1e_a;
wire [31:0] pf1_d,pf2_d,pf3_d,pf4_d,obj1e_d;
wire [39:0] obj0e_d;
wire        pf1_ok,pf2_ok,pf3_ok,pf4_ok,obj0e_ok,obj1e_ok;
wire [ 7:0] vmem_r, vmem_g, vmem_b;   // u_vmem RGB -> diagnostic overlay mux (DIAG)

wire [7:0] dbg_fade_wr;   // DIAGNOSTIC probe: deco_ace fade-reg writes / frame
wire [95:0] dbg_ace;      // DIAGNOSTIC probe: live ACE-RAM register values
wire [111:0] dbg_pixcap;  // DIAGNOSTIC (diag6): captured shadow/mist blend src+dst+alpha
wire [11:0] dbg_colbank;  // DIAGNOSTIC (diag8): {obj0_bank, obj1_bank, tm_bank1, tm_bank0} live register values
wire [ 7:0] dbg_mist;     // DIAGNOSTIC (diag9): mist-enable-chain forensics
jtnslasher_vmem u_vmem(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL), .LVBL(LVBL),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_we(cpu_we), .pri(pri),
    .pf1_rom_cs(pf1_cs),.pf1_rom_addr(pf1_a),.pf1_rom_data(pf1_d),.pf1_rom_ok(pf1_ok),
    .pf2_rom_cs(pf2_cs),.pf2_rom_addr(pf2_a),.pf2_rom_data(pf2_d),.pf2_rom_ok(pf2_ok),
    .pf3_rom_cs(pf3_cs),.pf3_rom_addr(pf3_a),.pf3_rom_data(pf3_d),.pf3_rom_ok(pf3_ok),
    .pf4_rom_cs(pf4_cs),.pf4_rom_addr(pf4_a),.pf4_rom_data(pf4_d),.pf4_rom_ok(pf4_ok),
    .obj0_rom_cs(obj0e_cs),.obj0_rom_addr(obj0e_a),.obj0_rom_data(obj0e_d),.obj0_rom_ok(obj0e_ok),
    .obj1_rom_cs(obj1e_cs),.obj1_rom_addr(obj1e_a),.obj1_rom_data(obj1e_d),.obj1_rom_ok(obj1e_ok),
    .red(vmem_r), .green(vmem_g), .blue(vmem_b),
    .dbg_fade_wr(dbg_fade_wr), .dbg_ace(dbg_ace), .dbg_pixcap(dbg_pixcap), .dbg_colbank(dbg_colbank), .dbg_mist(dbg_mist) );

// ===== ON-CAB DEBUGGER overlay (DIAG, remove for real build). See hdl/jtnslasher_dbgmon.v.
// Now in FIND-THE-HANG mode: decode-verdict grid (green = ARM decoding correct code) + 4 value rows:
//   pcmax (highest ROM addr = boot progress), pcnow (loop location), poll_a (last non-ROM read addr =
//   what a stuck wait-loop polls), poll_d (the value it read). See HANDOFF-oncab-debugger.md.
// NOTE: PROBE #3 (gfx-fetch capture — measure the PF1 gfx pixel path on HW). Probes #1/#2 CONFIRMED:
// drawing PF1 (tile 0x19D), palette written, all layers enabled+written -> the bug is the gfx pixel path.
// This captures the PF1 gfx fetch at the LOWEST render-word address (deterministic). Read off, then compare
// OFFLINE against the down_pass golden (gfx1_chars8[cap_addr] + r1_gfx1[cap_sdaddr]):
//   row0 pcmax  ({0,cap_addr})       = pf1 RENDER-WORD address captured (needed to compute the golden)
//   row1 pcnow  ({0,cap_dec[15:0]})  = DECRYPTED gfx word, LOW 16  (what the tilemap draws)
//   row2 poll_a ({0,cap_dec[31:16]}) = DECRYPTED gfx word, HIGH 16
//   row3 poll_d ({0,cap_sddata})     = RAW SDRAM word read (deco56-encrypted, pre-decrypt)
//   row4 snd    ({0,cap_sdaddr,0}->[31:8]) = RAW SDRAM word ADDRESS the gfxdec read
// Localise: cap_dec wrong vs golden => gfx output bad; if cap_sddata also wrong vs r1_gfx1 => SDRAM data/
// download; if cap_sddata right but cap_dec wrong => decrypt/FSM-timing on HW. See hdl/jtnslasher_gfxprobe.v.
// PROBE #4 (boot-progression gate — what is the ARM polling at the stuck version screen?). DIAG build:
// overlay ENABLED (remove the `define below to revert to full-screen play). Read off:
//   row0 pcmax  = boot progress (~0xED300)
//   row1 pcnow  = loop location (last ROM PC the ARM is spinning at)
//   row2 poll_a = last NON-ROM read addr = THE POLL TARGET: 2006B4=EEPROM, 200500=IN0, 200988=IN1, 10xxxx=workRAM
//   row3 poll_d = the value it read (what it's waiting for)
//   row4 snd    = soundlatch-write count (climbing = re-issuing the looping sound each pass)
// PROBE #7 (PC sticky-flag tracer — see the STATE PROBE block above). CURRENT build maps:
//   row0 pcmax = 5 PC FLAGS as 5 nibbles {2150,gate,wait,armRtn,arm}, each F=reached / 0=not reached.
//        **MAME GOLDEN = "F F 0 F F"** (reached gate, wait-loop NOT taken, armed). Read the cab's row0 vs this:
//          digit3 (wait)  = F -> START-GATE wait-loop -> both P1+P2 Start read HELD on the cab (input bug).
//          digit1 (2150)  = 0 -> boot NEVER reached the gate routine -> diverged earlier in boot.
//          2150=F, gate=0     -> entered routine, stalled in its early sub-calls (0xFB4/0x1060/0xC40/...).
//          arm(digit5)=0, wait=0, armRtn=F -> gate passed but arm not reached (stalled 0x21E4..0x48E4).
//   row1 pcnow = sp_gate100 = 0x100100 (bit3 set = still inside gate routine, before its 0x21E4/0x624 clear)
//   row2 poll_a= sp_ph103   = 0x100103 task bitmask
//   row3 poll_d= **PROBE #8: sp_in1edge = sticky-OR of byte[0x100014][3:0] (THE FLOOD GATE).**
//        The rightmost hex digit of row3 = the IN1 rising-edge nibble. **MAME GOLDEN = 0.** Read the cab:
//          row3 == 000000        -> 0x100014 edge byte stays 0 (HEALTHY; flood is elsewhere — recheck).
//          row3 rightmost digit:  bit0(=1)=Coin1 edge, bit1(=2)=Coin2 edge, bit2(=4)=Service1 edge,
//                                 bit3(=8)=`b 0x50` RESTART GATE set. Any non-zero = the spurious per-frame
//          edge that re-kicks the sound. e.g. 000001 = a Coin1 phantom edge; 000008 = bit3 restart latched.
//        (sticky-OR: a single 1-frame spurious edge LATCHES, so it is readable even though the ARM rewrites
//         0x100014=0 most frames. byte[0x100014][2:0] = the low 3 bits of this nibble; bit3 is the gate.)
//   row4 snd   = sndwr count (verdict YELLOW = sndwr!=0). (Verdict colour: ignore.)
//`define JTNSLASHER_DBG_OVERLAY   // row overlay OFF (occludes + unreadable). diag5 uses the clean bottom-hex byte instead.
`ifdef JTNSLASHER_DBG_OVERLAY
jtnslasher_dbgmon u_dbgmon(
    .clk(clk), .dbg_pc(dbg_pc[23:0]), .main_cs(main_cs), .main_ok(main_ok),
    .main_data(main_data), .rom_dec(dbg_romdec),
    // ===== diag4 SHADOW PROBE — all SIX obj-alpha bytes (shadow aidx is colour-derived 1-4) + fade + pri =====
    //   row0 = obj alpha : 00 11 00  hi=ace[0x01] lo=ace[0x00]
    //   row1 = obj alpha : 00 33 22  hi=ace[0x03] lo=ace[0x02]
    //   row2 = obj/tile  : 55 44 TT  hi=ace[0x05] mid=ace[0x04] lo=ace[0x17] (mist alpha armed?)
    //   row3 = fade TGT  : BB GG RR  ace[0x22]/[0x21]/[0x20]  (a non-zero fade here when nothing should fade => faded half corrupt)
    //   row4 = MODE pri  : MM SS 0P  MM=ace[0x26][15:8] (11=mult/10=add) SS=ace[0x23] strR  P=pri[2:0] (bit2 must be 0)
    // SHADOW READ: get_alpha(v)=255-(v<<3); v=0 => 0xFF opaque (shadow shows own colour=glow); small v => high alpha=too light.
    .dbg_pcmax({4'd0, dbg_ace[15:0]}),                                   // row0 = obj alpha {ace01, ace00}
    .dbg_pcnow({4'd0, dbg_ace[31:16]}),                                  // row1 = obj alpha {ace03, ace02}
    .dbg_poll_a({dbg_ace[47:32], dbg_ace[55:48]}), .dbg_poll_d({8'd0, dbg_ace[79:56]}), // row2={ace05,ace04,ace17} ; row3=fade target {ace22,ace21,ace20}
    .dbg_snd({dbg_ace[95:80], 5'd0, pri[2:0], 8'd0}), .dbg_virq_cnt(dbg_virq_cnt), .dbg_irq_cnt(dbg_irq_cnt), // row4={ace26hi, ace23, pri}
    .hdump(hdump), .vdump(vdump), .LHBL(LHBL), .LVBL(LVBL),
    .vmem_r(vmem_r), .vmem_g(vmem_g), .vmem_b(vmem_b),
    .red(red), .green(green), .blue(blue) );
`else
// overlay OFF -> full-screen game render (define JTNSLASHER_DBG_OVERLAY to bring the dbgmon back)
assign red = vmem_r; assign green = vmem_g; assign blue = vmem_b;
`endif

// ================= gfx SDRAM fetch adapter =================
jtnslasher_sdram u_sdram(
    .rst(rst), .clk(clk),
    .pf1_rom_cs(pf1_cs),.pf1_rom_addr(pf1_a),.pf1_rom_data(pf1_d),.pf1_rom_ok(pf1_ok),
    .pf2_rom_cs(pf2_cs),.pf2_rom_addr(pf2_a),.pf2_rom_data(pf2_d),.pf2_rom_ok(pf2_ok),
    .pf3_rom_cs(pf3_cs),.pf3_rom_addr(pf3_a),.pf3_rom_data(pf3_d),.pf3_rom_ok(pf3_ok),
    .pf4_rom_cs(pf4_cs),.pf4_rom_addr(pf4_a),.pf4_rom_data(pf4_d),.pf4_rom_ok(pf4_ok),
    .obj0_rom_cs(obj0e_cs),.obj0_rom_addr(obj0e_a),.obj0_rom_data(obj0e_d),.obj0_rom_ok(obj0e_ok),
    .obj1_rom_cs(obj1e_cs),.obj1_rom_addr(obj1e_a),.obj1_rom_data(obj1e_d),.obj1_rom_ok(obj1e_ok),
    .gfx1a_cs(gfx1a_cs),.gfx1a_addr(gfx1a_addr),.gfx1a_data(gfx1a_data),.gfx1a_ok(gfx1a_ok),
    .gfx1b_cs(gfx1b_cs),.gfx1b_addr(gfx1b_addr),.gfx1b_data(gfx1b_data),.gfx1b_ok(gfx1b_ok),
    .gfx2a_cs(gfx2a_cs),.gfx2a_addr(gfx2a_addr),.gfx2a_data(gfx2a_data),.gfx2a_ok(gfx2a_ok),
    .gfx2b_cs(gfx2b_cs),.gfx2b_addr(gfx2b_addr),.gfx2b_data(gfx2b_data),.gfx2b_ok(gfx2b_ok),
    .obj0_cs(obj0_cs),.obj0_addr(obj0_addr),.obj0_data(obj0_data),.obj0_ok(obj0_ok),   // obj0: DW32-DOUBLE port (nf24 8-byte-slot single-burst fold)
    .obj1_cs(obj1_cs),.obj1_addr(obj1_addr),.obj1_data(obj1_data),.obj1_ok(obj1_ok) );

// DIAG probe #3: capture the PF1 gfx fetch (decrypted word + raw SDRAM word) at the lowest render-word
// address — measures the gfx pixel path on HW. See hdl/jtnslasher_gfxprobe.v.
jtnslasher_gfxprobe u_gfxprobe(
    .rst(rst), .clk(clk),
    .pf1_cs(pf1_cs), .pf1_ok(pf1_ok), .pf1_addr(pf1_a), .pf1_data(pf1_d),
    .gfx1a_addr(gfx1a_addr), .gfx1a_data(gfx1a_data),
    .cap_addr(dbg_cap_addr), .cap_dec(dbg_cap_dec),
    .cap_sdaddr(dbg_cap_sdaddr), .cap_sddata(dbg_cap_sddata), .captured(dbg_captured) );

// DIAG: capture the Z80 sound ROM's first 4 bytes (read at Z80 reset, independent of the hung ARM)
// to MEASURE whether the no-reverse sound bank is byteswapped. golden = C3 3B 00 FF (JP 0x003B).
reg [7:0] sb0=0, sb1=0, sb2=0, sb3=0;
always @(posedge clk) if( snd_cs & snd_ok ) begin
    if( snd_addr==16'd0 ) sb0 <= snd_data;
    if( snd_addr==16'd1 ) sb1 <= snd_data;
    if( snd_addr==16'd2 ) sb2 <= snd_data;
    if( snd_addr==16'd3 ) sb3 <= snd_data;
end
assign dbg_snd = { sb0, sb1, sb2, sb3 };

// ================= sound =================
jtnslasher_snd u_snd(
    .rst(rst), .clk(clk),
    .cen_fm(cen_fm), .cen_fm2(cen_fm2), .cen_oki1(cen_oki1), .cen_oki2(cen_oki2),
    .snd_req(snd_req), .snd_latch(snd_latch),
    .rom_addr(snd_addr), .rom_cs(snd_cs), .rom_data(snd_data), .rom_ok(snd_ok),
    .oki1_addr(oki1_addr), .oki1_cs(oki1_cs), .oki1_data(oki1_data), .oki1_ok(oki1_ok),
    .oki2_addr(oki2_addr), .oki2_cs(oki2_cs), .oki2_data(oki2_data), .oki2_ok(oki2_ok),
    .fm_l(fm_l), .fm_r(fm_r), .pcm1(oki1), .pcm2(oki2) );

// ================= ROM download post-pass =================
always @(*) begin
    post_addr = u_dwnld_post_addr;
    post_data = u_dwnld_post_data;
end
wire [22:0] u_dwnld_post_addr;   // nf24: full 23-bit post_addr (SDRAM_LARGE 16MB banks; dwnld drives all 23 bits)
wire [ 7:0] u_dwnld_post_data;
jtnslasher_dwnld u_dwnld(
    .prog_addr(prog_addr), .prog_ba(prog_ba), .prog_data(prog_data),
    .post_addr(u_dwnld_post_addr), .post_data(u_dwnld_post_data) );

// ================= tie-offs =================
assign dsn       = 2'b11;     // BA0 SDRAM ram bank unused (work RAM is BRAM)
assign ram_addr  = 15'd0;
assign ram_cs    = 1'b0;
assign ram_we    = 1'b0;
assign main_dout = 32'd0;
`ifndef JTFRAME_OSD_FLIP
assign dip_flip   = 1'b0;
`endif
// debug_view MUST be 0 for a clean release: jtframe_debug_viewmux passes debug_view -> view_hex, and
// jtframe_debug_ctrl draws the bottom hex overlay whenever view_hex!=0 (or debug_bus!=0). Feeding it
// dbg_pc[7:0] (the live ARM PC, always non-zero) is what painted the persistent bottom-row hex on the cab
// — independent of JTFRAME_STATUS. Tie to 0 = no overlay. (Restore dbg_pc[7:0] only for PC debugging.)
// diag6: three theory-driven colmix fixes in a row (mist-base/nf14, buffered-DMA/nf16, dual-mirror
// tearing/nf17) all sim-verified but did NOT move the persistent HW symptom (green dialog, light
// shadow) -- read the ACTUAL shadow/mist blend inputs (src colour, dst colour, alpha) the LAST time
// each fired, via the clean bottom-hex byte (no screen-occluding overlay). Cycles ~2.1s/slot, 0xAA sync.
//   SEQUENCE after AA:  shadowSrcR,G,B -> shadowDstR,G,B -> shadowAlpha -> mistSrcR,G,B -> mistDstR,G,B -> mistAlpha
//   Read this on a scene with a visible player/enemy SHADOW: shadowSrc should be near-BLACK (RGB all low).
//   If shadowSrc is instead LIGHT/bright, that's the bug -- the shadow's source pen itself is wrong, not the
//   blend math (confirmed bit-exact to MAME) or the alpha (also confirmed bit-exact). If shadowSrc IS dark but
//   the ON-SCREEN shadow still looks light, shadowAlpha is too LOW (barely blending toward the dark source).
//   Read this on the GREEN DIALOG scene: mistSrc should be near-BLACK. If mistSrc is bright/greenish, the
//   dialog's actual resolved pen is wrong (decode/index bug) -- not a timing/tearing issue at all.
// diag8: PROVE the runtime colour-bank hypothesis on HW. Show the LIVE values of the three colour-bank
// registers (0x164000/4/8) that MAME uses for the tilemap + sprite palette bases and our RTL hardcoded.
// dbg_colbank = {obj0_bank[11:9], obj1_bank[8:6], tm_bank1[5:3], tm_bank0[2:0]}. Read in ATTRACT vs
// IN-GAME (esp. a scene with a shadow / a dialog box):
//   - obj0_bank should read 4 (0x400). obj1_bank should read 6 (0x600) in attract; if it reads a
//     DIFFERENT value IN-GAME, that CONFIRMS the shadow bug (this build already wires obj1_base live ->
//     the shadow should also visually go DARK). tm_bank0/1 drive the tilemap (dialog) base -> if they
//     change in-game, that's the green-dialog fix target (tilemap path, next build).
//   - If obj0_bank!=4 or obj1_bank!=6 in ATTRACT, the byte LANE is wrong (registers latch cpu_dout[2:0]);
//     re-derive the lane. So attract doubles as a self-check that the decode is correct.
// Each nibble 0-7. Emitted as a full byte {0, value} so a 0 reads as a blank slot (draws nothing).
// ===== COMB SIZING PROBE (no SignalTap): real obj0 fetch latency on silicon =====
// The nf20 pipelined obj engine is sim-proven to absorb fetch latencies up to ~19 clk (0/240 lines
// over budget at LAT=16), yet HW still combs -> the REAL latency (with obj1+CPU+refresh SDRAM
// contention, which the fixed-LAT sim didn't model) must exceed that. Measure it: count clk from
// obj0 rom_cs rise to rom_ok rise (the exact quantity the sim's LAT parameter models), keep the
// per-frame MAX + a per-frame count of fetches >= 20 clk. Displayed on the bottom-hex (slots 6/7).
// lat_max <= ~16 would mean latency ISN'T the residual comb cause (look at the engine again);
// lat_max 20-30 -> SDRAM arbiter priority for obj0 may suffice; lat_max >> 30 -> only a burst-count
// reduction (single-fetch repack) can close it.
reg [7:0] o0lat_cnt=0, o0lat_max=0, o0lat_max_l=0, o0over_cnt=0, o0over_l=0;
reg       o0ok_l=0;
always @(posedge clk) begin
    o0ok_l <= obj0e_ok;
    if( !obj0e_cs )                              o0lat_cnt <= 8'd0;
    else if( !obj0e_ok && o0lat_cnt!=8'hff )     o0lat_cnt <= o0lat_cnt + 8'd1;
    if( obj0e_cs && obj0e_ok && !o0ok_l ) begin  // fetch just completed; o0lat_cnt = its latency
        if( o0lat_cnt > o0lat_max )                        o0lat_max  <= o0lat_cnt;
        if( o0lat_cnt >= 8'd20 && o0over_cnt != 8'hff )    o0over_cnt <= o0over_cnt + 8'd1;
    end
    if( vbl_irq ) begin
        o0lat_max_l <= o0lat_max;  o0lat_max  <= 8'd0;     // latch per frame for a stable readout
        o0over_l    <= o0over_cnt; o0over_cnt <= 8'd0;
    end
end

// RELEASE (v1.0, 2026-07-02): the bottom-hex probe is OFF (debug_view=0 -> no overlay). The whole
// colour/alpha cluster (S1-S7) is HW-CONFIRMED closed on nf28: mist, carriage alpha, bios/story-art,
// shadows, dialogs. Re-enable NSLASHER_PROBE for future diag builds (slot map preserved below).
`ifdef NSLASHER_PROBE
reg [15:0] dvcnt = 16'd0;
always @(posedge clk) if(vbl_irq) dvcnt <= dvcnt + 1'b1;
wire [2:0] dvsel = dvcnt[9:7];                     // ~128 frames (~2.1s) per slot
assign debug_view =
    dvsel==3'd0  ? 8'hAB                    :      // SYNC (nf28 = 0xAB = FIX C bundle: mist cen no-op + pen formula + flip/colour-mask
                                                    //  + obj1 suppression + PF1-raw + sel-phase; nf27=99 FIX B, nf26=88, nf25=77, nf24=66)
    dvsel==3'd1  ? dbg_mist                  :     // MIST forensic byte (expect 1F on stage-2 = mist fires)
    dvsel==3'd2  ? dbg_pixcap[39:32]         :     // mist SRC R -- the actual colour the mist blends TOWARD
    dvsel==3'd3  ? dbg_pixcap[47:40]         :     // mist SRC G
    dvsel==3'd4  ? dbg_pixcap[55:48]         :     // mist SRC B
    dvsel==3'd5  ? dbg_pixcap[ 7: 0]         :     // mist ALPHA (correctly phased since FIX C-CEN)
    dvsel==3'd6  ? o0lat_max_l               :     // COMB: obj0 fetch latency MAX this frame
                   o0over_l                  ;     //   fetches >= 20 clk this frame
`else
assign debug_view = 8'h00;
`endif
`ifdef JTFRAME_STATUS
assign st_dout    = 8'h0;
`endif

endmodule
