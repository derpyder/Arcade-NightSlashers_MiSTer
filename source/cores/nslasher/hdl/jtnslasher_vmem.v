/*  Night Slashers — deco32 video memory subsystem.
    Wraps the validated render core (jtnslasher_video, M3j bit-exact) with the on-chip video RAMs
    the deco32 board has between the CPU and the renderer, plus the control-register decode. The
    CPU writes (surfaced by jtnslasher_main as the cpu_we one-pulse bus, task #7a) land here:

      0x163000-16309F  Ace RAM        (deferred — colmix Ace path is off in attract; sink for now)
      0x168000-169FFF  palette        -> jtnslasher_colmix palette RAM (via the video pal_we port)
      0x170000-171FFF  spriteram      -> obj0 line-parse table (gfx3, 5bpp)
      0x178000-179FFF  spriteram2     -> obj1 line-parse table (gfx4, 4bpp)
      0x182000/184000  PF1/PF2 data   -> tilemap data RAM
      0x1C2000/1C4000  PF3/PF4 data   -> tilemap data RAM
      0x1A0000/1E0000  PF12/PF34 ctl  -> per-PF scroll/bank/enable (deco16ic control regs)
    pri (deco32 0x150000 &3) is latched in jtnslasher_main and passed straight to the colmix.

    7b-1 = DIRECT-WRITE (no double-buffer DMA): the CPU writes the displayed RAMs and the renderer
    reads them. This is bit-exact for a settled frame (the cap-replay sim). The palette/spriteram
    DMA double-buffer (0x16c008 / 0x174010 / 0x17c010 triggers, prevents tearing during live play)
    is the 7b-2 fidelity add. Rowscroll (0x192000.., task #9) is also deferred.

    The 16-bit deco32 RAMs sit on the 32-bit ARM bus with data in the LOW 16 (the caps dump them as
    ffff_DDDD); palette is 24-bit color in the low 24. Each region is 0x2000 bytes so the local
    word index is cpu_addr[12:2]; the ctl banks are 8 words (cpu_addr[4:2]).
*/
module jtnslasher_vmem(
    input             rst,
    input             clk,
    input             pxl_cen,

    // timing (shared jtframe_vtimer)
    input      [ 8:0] vrender,
    input      [ 8:0] hdump,
    input             HS,
    input             LHBL,
    input             LVBL,

    // CPU video bus (from jtnslasher_main, task #7a)
    input      [23:0] cpu_addr,
    input      [31:0] cpu_dout,
    input      [ 3:0] cpu_we,
    input      [ 2:0] pri,

    // gfx ROM buses (to JTFRAME SDRAM at the game level) — pass through from jtnslasher_video
    output            pf1_rom_cs, output [18:0] pf1_rom_addr, input [31:0] pf1_rom_data, input pf1_rom_ok,
    output            pf2_rom_cs, output [18:0] pf2_rom_addr, input [31:0] pf2_rom_data, input pf2_rom_ok,
    output            pf3_rom_cs, output [18:0] pf3_rom_addr, input [31:0] pf3_rom_data, input pf3_rom_ok,
    output            pf4_rom_cs, output [18:0] pf4_rom_addr, input [31:0] pf4_rom_data, input pf4_rom_ok,
    output            obj0_rom_cs, output [20:0] obj0_rom_addr, input [39:0] obj0_rom_data, input obj0_rom_ok,
    output            obj1_rom_cs, output [20:0] obj1_rom_addr, input [31:0] obj1_rom_data, input obj1_rom_ok,

    output     [ 2:0] obj1_base,       // runtime obj1 (gfx4 shadow) palette base bank (0x164008), MAME sprite2_color_bank_w
    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue,
    output     [ 7:0] dbg_fade_wr,     // DIAGNOSTIC: deco_ace fade-reg writes / frame (per-scanline-fade probe)
    output     [95:0] dbg_ace,         // DIAGNOSTIC: live ACE-RAM register values -> dbgmon overlay
    output     [111:0] dbg_pixcap,     // DIAGNOSTIC (diag6): captured shadow/mist blend src+dst+alpha
    output     [11:0] dbg_colbank,     // DIAGNOSTIC (diag8): {obj0_bank, obj1_bank, tm_bank1, tm_bank0} live values
    output     [ 7:0] dbg_mist         // DIAGNOSTIC (diag9): mist-enable-chain forensics
);

// ---------------- CPU write decode ----------------
wire [10:0] vidx = cpu_addr[12:2];      // word index within a 0x2000 region
wire [ 2:0] cidx = cpu_addr[ 4:2];      // ctl-bank word index (8 words)
wire        wr   = |cpu_we;
wire pal_w  = wr & (cpu_addr>=24'h168000 && cpu_addr<24'h16a000);
wire pf1_w  = wr & (cpu_addr>=24'h182000 && cpu_addr<24'h184000);
wire pf2_w  = wr & (cpu_addr>=24'h184000 && cpu_addr<24'h186000);
wire pf3_w  = wr & (cpu_addr>=24'h1c2000 && cpu_addr<24'h1c4000);
wire pf4_w  = wr & (cpu_addr>=24'h1c4000 && cpu_addr<24'h1c6000);
wire spr0_w = wr & (cpu_addr>=24'h170000 && cpu_addr<24'h172000);
wire spr1_w = wr & (cpu_addr>=24'h178000 && cpu_addr<24'h17a000);
wire ctl12_w= wr & (cpu_addr>=24'h1a0000 && cpu_addr<24'h1a0020);
wire ctl34_w= wr & (cpu_addr>=24'h1e0000 && cpu_addr<24'h1e0020);
wire ace_w  = wr & (cpu_addr>=24'h163000 && cpu_addr<24'h1630a0);  // deco_ace RAM (alpha+fade), 40 x 16b

// ---------------- deco_ace RAM (alpha control 0x00-0x1f, fade regs 0x20-0x26) ----------------
// MAME deco_ace.cpp: obj alpha = ace[0x00-0x05] via get_alpha(); fade = ace[0x20-0x26] (Build B).
// Resets to 0 -> get_alpha(0)=0xFF (opaque) / fade=identity = exactly today's behavior (regression-safe).
reg [15:0] ace_ram[0:39];
integer ai;
always @(posedge clk, posedge rst) begin
    if( rst ) for(ai=0;ai<40;ai=ai+1) ace_ram[ai] <= 16'd0;
    else if( ace_w ) ace_ram[cpu_addr[7:2]] <= cpu_dout[15:0];
end
wire [47:0] ace_alpha = { ace_ram[5][7:0], ace_ram[4][7:0], ace_ram[3][7:0],
                          ace_ram[2][7:0], ace_ram[1][7:0], ace_ram[0][7:0] };  // obj-alpha bytes -> colmix

// Build B fade: target ace[0x20-0x22], strength ace[0x23-0x25], mode ace[0x26]; recompute trigger
wire [47:0] ace_fade  = { ace_ram[6'h25][7:0], ace_ram[6'h24][7:0], ace_ram[6'h23][7:0],
                          ace_ram[6'h22][7:0], ace_ram[6'h21][7:0], ace_ram[6'h20][7:0] };
wire        fade_mult = ace_ram[6'h26] != 16'h1000;   // 0x1000 = additive ; else multiplicative
// ===== RUNTIME COLOUR-BANK REGISTERS (0x164000/4/8) — deco32_v.cpp:56-70 =====
// MAME implements these as LIVE registers (the 2009-era driver wrongly NOP'd them as "constants",
// which is why an attract capture looked static). They set the palette BASE for the tilemaps and the
// two sprite chips; games reprogram them per scene. Our RTL hardcoded them (obj0=0x400, obj1=0x600,
// tilemap gfx1=0x000/gfx2=0x200) -> correct in attract, WRONG in-game where the base moves ->
// warm-tan shadow (obj1) + green dialog (tilemap). diag7 proved the RAW pen we read is warm, i.e. we
// read the wrong palette region, not a fade error. This build wires obj1's base live (fixes the
// shadow) and PROBES all three so the same flash confirms the mechanism + guides the tilemap/dialog fix.
//   0x164000 : tilemap BG2/3 bank -> set_tilemap_colour_bank(0,(data&7)<<4), (1,((data>>3)&7)<<4)
//   0x164004 : sprite1 (obj0, 5bpp char) base -> (data&7)<<8      [attract const 4 -> 0x400]
//   0x164008 : sprite2 (obj1, 4bpp shadow) base -> (data&7)<<8    [attract const 6 -> 0x600]
wire        ctlcol_w = wr & (cpu_addr>=24'h164000 && cpu_addr<24'h164010);
// defaults = the measured in-game values (obj0=4,obj1=6,tm=2/3) so the WINDOW before the game first
// writes 0x164000/4/8 isn't wrong-banked (the cold-boot "green until reset" clue: tm_bank0=0 routed the
// mist to bank 0 = green until the write landed; defaulting to 2 closes that window).
reg  [ 2:0] obj0_bank=3'd4, obj1_bank=3'd6, tm_bank0=3'd2, tm_bank1=3'd3;
always @(posedge clk) begin
    if( rst ) begin obj0_bank<=3'd4; obj1_bank<=3'd6; tm_bank0<=3'd2; tm_bank1<=3'd3; end
    else if( ctlcol_w ) case( cpu_addr[3:2] )
        2'd0: begin tm_bank0 <= cpu_dout[2:0]; tm_bank1 <= cpu_dout[5:3]; end   // 0x164000
        2'd1: obj0_bank <= cpu_dout[2:0];                                        // 0x164004
        2'd2: obj1_bank <= cpu_dout[2:0];                                        // 0x164008
        default:;
    endcase
end
assign obj1_base    = obj1_bank;
assign dbg_colbank  = { obj0_bank, obj1_bank, tm_bank1, tm_bank0 };

wire        paldma    = wr & (cpu_addr>=24'h16c008 && cpu_addr<24'h16c00c);  // deco_ace palette DMA (palette_dma_w)
wire        fade_trig = paldma | (ace_w & (cpu_addr[7:2]>=6'h20) & (cpu_addr[7:2]<=6'h26)); // recompute faded
// Build C alpha-tilemap (mist): tilemap alpha control ace[0x17-0x1e] -> get_alpha(0x17+colour>>1)
wire [63:0] ace_tile  = { ace_ram[6'h1e][7:0], ace_ram[6'h1d][7:0], ace_ram[6'h1c][7:0], ace_ram[6'h1b][7:0],
                          ace_ram[6'h1a][7:0], ace_ram[6'h19][7:0], ace_ram[6'h18][7:0], ace_ram[6'h17][7:0] };

// ===== DIAGNOSTIC PROBE — per-scanline-fade hypothesis test (overlay shows this byte) =====
// Count deco_ace FADE-register writes (ace[0x20-0x26]) per FRAME. Reset+latch at LVBL rising (frame start).
//   ~01-02  = once-per-frame fade (our VBLANK FSM is sufficient; bio monochrome is something else)
//   ~C8-FF  = the game rewrites the fade regs PER SCANLINE -> our once-per-VBLANK FSM CANNOT reproduce it
//             -> CASE CLOSED: the bio needs a real-time PER-LINE (pipelined) fade, not a frame-buffered palette.
// (Counts the fade regs only, NOT the 0x16c008 DMA; saturates at 0xFF. Harmless logic — remove for ship.)
wire        fade_reg_wr = ace_w & (cpu_addr[7:2]>=6'h20) & (cpu_addr[7:2]<=6'h26);
reg  [ 7:0] fade_wr_cnt = 8'd0, fade_wr_max = 8'd0;
reg         lvbl_diag   = 1'b0;
always @(posedge clk) begin
    lvbl_diag <= LVBL;
    if( LVBL & ~lvbl_diag ) begin                          // LVBL rising = new frame -> latch previous + reset
        fade_wr_max <= fade_wr_cnt;
        fade_wr_cnt <= 8'd0;
    end else if( fade_reg_wr & (fade_wr_cnt != 8'hff) ) begin
        fade_wr_cnt <= fade_wr_cnt + 8'd1;                 // saturate at 0xFF (= "200+")
    end
end
assign dbg_fade_wr = fade_wr_max;

// diag4: all SIX obj-alpha bytes ace[0x00-0x05] (shadow aidx is colour-derived 1-4, was invisible) + mist alpha 0x17 + fade.
//   [95:88]=ace[0x26][15:8] mode-hi  [87:80]=ace[0x23] fadeStR  [79:72]=ace[0x22] ptB  [71:64]=ace[0x21] ptG  [63:56]=ace[0x20] ptR
//   [55:48]=ace[0x17] tileA0  [47:40]=ace[0x05]  [39:32]=ace[0x04]  [31:24]=ace[0x03]  [23:16]=ace[0x02]  [15:8]=ace[0x01]  [7:0]=ace[0x00]
assign dbg_ace = { ace_ram[6'h26][15:8], ace_ram[6'h23][7:0], ace_ram[6'h22][7:0], ace_ram[6'h21][7:0],
                   ace_ram[6'h20][7:0], ace_ram[6'h17][7:0], ace_ram[6'h05][7:0], ace_ram[6'h04][7:0],
                   ace_ram[6'h03][7:0], ace_ram[6'h02][7:0], ace_ram[6'h01][7:0], ace_ram[6'h00][7:0] };

// ---------------- deco16 control registers ----------------
reg [15:0] ctl12[0:7], ctl34[0:7];
integer ci;
always @(posedge clk, posedge rst) begin
    if( rst ) for(ci=0;ci<8;ci=ci+1) begin ctl12[ci]<=16'd0; ctl34[ci]<=16'd0; end
    else begin
        if( ctl12_w ) ctl12[cidx] <= cpu_dout[15:0];
        if( ctl34_w ) ctl34[cidx] <= cpu_dout[15:0];
    end
end
// per-PF control (doc/mame_deco32.c get_pfN_tile_info; identical to gen_video.py)
wire [9:0] pf1_scrx = {1'b0, ctl12[1][8:0]};   // &0x1ff (8x8 map 512x256)
wire [8:0] pf1_scry = {1'b0, ctl12[2][7:0]};   // &0xff
wire [9:0] pf2_scrx = ctl12[3][9:0];           // &0x3ff
wire [8:0] pf2_scry = ctl12[4][8:0];           // &0x1ff
wire [1:0] pf2_bank = ctl12[7][13:12];
wire [9:0] pf3_scrx = ctl34[1][9:0];
wire [8:0] pf3_scry = ctl34[2][8:0];
wire [1:0] pf3_bank = ctl34[7][ 5: 4];
wire [9:0] pf4_scrx = ctl34[3][9:0];
wire [8:0] pf4_scry = ctl34[4][8:0];
wire [1:0] pf4_bank = ctl34[7][13:12];
wire       en1 = ctl12[5][ 7];                 // &0x0080
wire       en2 = ctl12[5][15];                 // &0x8000
wire       en3 = ctl34[5][ 7];
wire       en4 = ctl34[5][15];
// FIX C2: per-PF tile-flip enables, ctl word 6 (doc/mame_deco16ic.c get_pfN_tile_info:248-345):
// chip's pf1 = bits[1:0], chip's pf2 = bits[9:8]; bit0(/8)=FLIPX-en, bit1(/9)=FLIPY-en.
// Enabled + tile bit15 -> flip + colour&=7 inside jtnslasher_tilemap.
wire [1:0] pf1_flip = ctl12[6][1:0];
wire [1:0] pf2_flip = ctl12[6][9:8];
wire [1:0] pf3_flip = ctl34[6][1:0];
wire [1:0] pf4_flip = ctl34[6][9:8];

// ---------------- video<->RAM nets ----------------
wire        pf1_ram_cs, pf2_ram_cs, pf3_ram_cs, pf4_ram_cs;
wire [10:0] pf1_ram_addr, pf2_ram_addr, pf3_ram_addr, pf4_ram_addr;
wire [15:0] pf1_ram_data, pf2_ram_data, pf3_ram_data, pf4_ram_data;
wire [ 9:0] obj0_tbl_addr, obj1_tbl_addr;
wire [15:0] obj0_tbl_dout, obj1_tbl_dout;

// PF data RAMs read 1 clk after addr (jtframe_dual_ram); ram_ok = registered ram_cs (matches the
// validated tb_layer/tb_video2 behavioral model exactly).
reg pf1_ok, pf2_ok, pf3_ok, pf4_ok;
always @(posedge clk) begin
    pf1_ok <= pf1_ram_cs; pf2_ok <= pf2_ram_cs; pf3_ok <= pf3_ram_cs; pf4_ok <= pf4_ram_cs;
end

jtframe_dual_ram #(.DW(16),.AW(11)) u_pf1ram(
    .clk0(clk), .data0(cpu_dout[15:0]), .addr0(vidx), .we0(pf1_w), .q0(),
    .clk1(clk), .data1(16'd0), .addr1(pf1_ram_addr), .we1(1'b0), .q1(pf1_ram_data) );
jtframe_dual_ram #(.DW(16),.AW(11)) u_pf2ram(
    .clk0(clk), .data0(cpu_dout[15:0]), .addr0(vidx), .we0(pf2_w), .q0(),
    .clk1(clk), .data1(16'd0), .addr1(pf2_ram_addr), .we1(1'b0), .q1(pf2_ram_data) );
jtframe_dual_ram #(.DW(16),.AW(11)) u_pf3ram(
    .clk0(clk), .data0(cpu_dout[15:0]), .addr0(vidx), .we0(pf3_w), .q0(),
    .clk1(clk), .data1(16'd0), .addr1(pf3_ram_addr), .we1(1'b0), .q1(pf3_ram_data) );
jtframe_dual_ram #(.DW(16),.AW(11)) u_pf4ram(
    .clk0(clk), .data0(cpu_dout[15:0]), .addr0(vidx), .we0(pf4_w), .q0(),
    .clk1(clk), .data1(16'd0), .addr1(pf4_ram_addr), .we1(1'b0), .q1(pf4_ram_data) );

// spriteram DOUBLE-BUFFER (deco32 buffer_spriteram32_w DMA — the 7b-2 fidelity add).
// MAME nslasher_draw_sprites reads buffered_spriteram (doc/mame_deco32.c:1582), a snapshot the
// hardware DMA-copies from live spriteram ONLY on the CPU write to 0x174010 (spr0) / 0x17c010 (spr1)
// (doc/deco32.c:886,891). The old direct-read of the LIVE CPU-written RAM tore multi-tile characters
// mid-update during live play (CPU rewriting a metasprite across several writes while the engine
// scans it) -> complex sprites garbled, simple ones fine. Here: the obj engine reads a SHADOW RAM,
// copied from the live RAM on the trigger write. (A settled snapshot has live==shadow, which is why
// every cap-replay sim was bit-exact; the bug is live-timing only.)
wire dma0_trig = wr & (cpu_addr>=24'h174010 && cpu_addr<24'h174014);
wire dma1_trig = wr & (cpu_addr>=24'h17c010 && cpu_addr<24'h17c014);
localparam [10:0] SPR_LAST = 11'd1023;   // 256 sprites x 4 words = the obj engine's read range

// --- spr0 (gfx3) DMA engine: live -> shadow on trigger; 1-clk RAM read latency pipelined ---
reg  [10:0] dma0_raddr, dma0_waddr;
reg         dma0_run, dma0_wen;
wire [15:0] dma0_rdata;
always @(posedge clk, posedge rst) begin
    if( rst ) begin dma0_run<=1'b0; dma0_raddr<=11'd0; dma0_waddr<=11'd0; dma0_wen<=1'b0; end
    else begin
        dma0_wen   <= dma0_run;                 // write what was read last clk
        dma0_waddr <= dma0_raddr;
        if( dma0_trig ) begin dma0_run<=1'b1; dma0_raddr<=11'd0; end
        else if( dma0_run ) begin
            if( dma0_raddr==SPR_LAST ) dma0_run<=1'b0;
            dma0_raddr <= dma0_raddr + 11'd1;
        end
    end
end
jtframe_dual_ram #(.DW(16),.AW(11)) u_spr0(           // LIVE: CPU write + DMA read
    .clk0(clk), .data0(cpu_dout[15:0]), .addr0(vidx),       .we0(spr0_w), .q0(),
    .clk1(clk), .data1(16'd0),          .addr1(dma0_raddr), .we1(1'b0),   .q1(dma0_rdata) );
jtframe_dual_ram #(.DW(16),.AW(11)) u_spr0_sh(        // SHADOW: DMA write + obj read
    .clk0(clk), .data0(dma0_rdata), .addr0(dma0_waddr),          .we0(dma0_wen), .q0(),
    .clk1(clk), .data1(16'd0),      .addr1({1'b0,obj0_tbl_addr}), .we1(1'b0),     .q1(obj0_tbl_dout) );

// --- spr1 (gfx4) DMA engine ---
reg  [10:0] dma1_raddr, dma1_waddr;
reg         dma1_run, dma1_wen;
wire [15:0] dma1_rdata;
always @(posedge clk, posedge rst) begin
    if( rst ) begin dma1_run<=1'b0; dma1_raddr<=11'd0; dma1_waddr<=11'd0; dma1_wen<=1'b0; end
    else begin
        dma1_wen   <= dma1_run;
        dma1_waddr <= dma1_raddr;
        if( dma1_trig ) begin dma1_run<=1'b1; dma1_raddr<=11'd0; end
        else if( dma1_run ) begin
            if( dma1_raddr==SPR_LAST ) dma1_run<=1'b0;
            dma1_raddr <= dma1_raddr + 11'd1;
        end
    end
end
jtframe_dual_ram #(.DW(16),.AW(11)) u_spr1(           // LIVE: CPU write + DMA read
    .clk0(clk), .data0(cpu_dout[15:0]), .addr0(vidx),       .we0(spr1_w), .q0(),
    .clk1(clk), .data1(16'd0),          .addr1(dma1_raddr), .we1(1'b0),   .q1(dma1_rdata) );
jtframe_dual_ram #(.DW(16),.AW(11)) u_spr1_sh(        // SHADOW: DMA write + obj read
    .clk0(clk), .data0(dma1_rdata), .addr0(dma1_waddr),          .we0(dma1_wen), .q0(),
    .clk1(clk), .data1(16'd0),      .addr1({1'b0,obj1_tbl_addr}), .we1(1'b0),     .q1(obj1_tbl_dout) );

// ---------------- render core ----------------
jtnslasher_video u_video(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL), .LVBL(LVBL),
    .pf1_scrx(pf1_scrx), .pf1_scry(pf1_scry),
    .pf2_scrx(pf2_scrx), .pf2_scry(pf2_scry),
    .pf3_scrx(pf3_scrx), .pf3_scry(pf3_scry),
    // FIX B: in JOINT-8bpp mode (pri[1]) MAME samples BOTH nibble sources at PF3's scroll
    // (doc/mame_deco16ic.c custom_tilemap_draw:1014-1016 — one src_x/src_y for src0 and src1),
    // so PF4's engine follows PF3's scroll registers while the mode is active.
    .pf4_scrx(pri[1] ? pf3_scrx : pf4_scrx), .pf4_scry(pri[1] ? pf3_scry : pf4_scry),
    .pf2_bank(pf2_bank), .pf3_bank(pf3_bank), .pf4_bank(pf4_bank),
    .pf1_flip(pf1_flip), .pf2_flip(pf2_flip), .pf3_flip(pf3_flip), .pf4_flip(pf4_flip),
    .en1(en1), .en2(en2), .en3(en3), .en4(en4), .pri(pri), .ace_alpha(ace_alpha),
    .ace_fade(ace_fade), .fade_mult(fade_mult), .fade_trig(fade_trig), .paldma(paldma), .ace_tile(ace_tile),
    // palette write straight from the CPU bus (colmix owns the palette RAM)
    .pal_we(pal_w), .pal_waddr(vidx), .pal_din(cpu_dout[23:0]),
    .pf1_ram_cs(pf1_ram_cs),.pf1_ram_addr(pf1_ram_addr),.pf1_ram_data(pf1_ram_data),.pf1_ram_ok(pf1_ok),
    .pf2_ram_cs(pf2_ram_cs),.pf2_ram_addr(pf2_ram_addr),.pf2_ram_data(pf2_ram_data),.pf2_ram_ok(pf2_ok),
    .pf3_ram_cs(pf3_ram_cs),.pf3_ram_addr(pf3_ram_addr),.pf3_ram_data(pf3_ram_data),.pf3_ram_ok(pf3_ok),
    .pf4_ram_cs(pf4_ram_cs),.pf4_ram_addr(pf4_ram_addr),.pf4_ram_data(pf4_ram_data),.pf4_ram_ok(pf4_ok),
    .pf1_rom_cs(pf1_rom_cs),.pf1_rom_addr(pf1_rom_addr),.pf1_rom_data(pf1_rom_data),.pf1_rom_ok(pf1_rom_ok),
    .pf2_rom_cs(pf2_rom_cs),.pf2_rom_addr(pf2_rom_addr),.pf2_rom_data(pf2_rom_data),.pf2_rom_ok(pf2_rom_ok),
    .pf3_rom_cs(pf3_rom_cs),.pf3_rom_addr(pf3_rom_addr),.pf3_rom_data(pf3_rom_data),.pf3_rom_ok(pf3_rom_ok),
    .pf4_rom_cs(pf4_rom_cs),.pf4_rom_addr(pf4_rom_addr),.pf4_rom_data(pf4_rom_data),.pf4_rom_ok(pf4_rom_ok),
    .obj0_tbl_addr(obj0_tbl_addr),.obj0_tbl_dout(obj0_tbl_dout),
    .obj1_tbl_addr(obj1_tbl_addr),.obj1_tbl_dout(obj1_tbl_dout),
    .obj0_rom_cs(obj0_rom_cs),.obj0_rom_addr(obj0_rom_addr),.obj0_rom_data(obj0_rom_data),.obj0_rom_ok(obj0_rom_ok),
    .obj1_rom_cs(obj1_rom_cs),.obj1_rom_addr(obj1_rom_addr),.obj1_rom_data(obj1_rom_data),.obj1_rom_ok(obj1_rom_ok),
    .obj1_base(obj1_base), .tm_bank0(tm_bank0), .tm_bank1(tm_bank1),
    .red(red), .green(green), .blue(blue), .dbg_pixcap(dbg_pixcap), .dbg_mist(dbg_mist) );

endmodule
