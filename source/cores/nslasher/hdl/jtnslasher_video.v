/*  Night Slashers — video top.  Assembles the full deco32 video pixel path:
      4x jtnslasher_tilemap  (PF1 8x8 + PF2/PF3/PF4 16x16, banks)   [M3f, bit-exact]
      2x jtnslasher_obj      (obj0 gfx3 5bpp, obj1 gfx4 4bpp)        [M3h, bit-exact]
      1x jtnslasher_colmix   (Ace priority + 50% alpha mixer)        [M3i, bit-exact]
    all sharing the timing from a single jtframe_vtimer (vrender/hdump/HS/LHBL/LVBL),
    instanced by the caller.  Validated end-to-end vs ver/gfx/ref_render.py (ver/gfx/tb_video2.v).

    The control inputs (scrx/scry/bank/en per PF, pri) come from the deco16 control regs at
    integration (jtnslasher_game maps the CPU's 1A0000/1E0000/150000 writes here); the memory
    buses (PF data RAM, sprite tables, the 5 reshuffled gfx ROM sets, palette write) are wired to
    JTFRAME SDRAM / the download-pass reshuffle / the CPU bus there.  PF3 and PF4 share the gfx2
    region but each has its own ROM port (the SDRAM arbiter serves them).

    NOTE (deferred, off in attract): per-tile flip + rowscroll (tilemap), Ace palette-fade +
    alpha-tilemap blend (colmix).  See HANDOFF-m3-video.md / STATUS.md.
*/
module jtnslasher_video(
    input             rst,
    input             clk,
    input             pxl_cen,

    // timing (shared jtframe_vtimer)
    input      [ 8:0] vrender,
    input      [ 8:0] hdump,
    input             HS,
    input             LHBL,
    input             LVBL,

    // per-PF scroll (16x16 map 1024x512; PF1 8x8 uses the low bits)
    input      [ 9:0] pf1_scrx, input [8:0] pf1_scry,
    input      [ 9:0] pf2_scrx, input [8:0] pf2_scry,
    input      [ 9:0] pf3_scrx, input [8:0] pf3_scry,
    input      [ 9:0] pf4_scrx, input [8:0] pf4_scry,
    // per-PF tile bank (deco32 ((ctl[7]>>k)&3))
    input      [ 1:0] pf2_bank, pf3_bank, pf4_bank,
    // per-PF tile-flip enables (FIX C2): {FLIPY-en, FLIPX-en} from ctl12/ctl34 word 6
    input      [ 1:0] pf1_flip, pf2_flip, pf3_flip, pf4_flip,
    // layer enables + deco32 priority
    input             en1, en2, en3, en4,
    input      [ 2:0] pri,
    input      [47:0] ace_alpha,      // deco_ace obj-alpha bytes (ace[0x00-0x05]) -> colmix
    input      [47:0] ace_fade,       // deco_ace fade target/strength (ace[0x20-0x25]) -> colmix
    input             fade_mult,       // fade mode (1=mult / 0=add)
    input             fade_trig,       // recompute-faded trigger (palette-DMA or fade-reg write)
    input             paldma,          // palette-DMA ONLY (0x16c008) — snapshots live->buffered
    input      [63:0] ace_tile,        // deco_ace tilemap-alpha (ace[0x17-0x1e]) -> alpha-mist blend

    // CPU palette write (24-bit 0x00BBGGRR)
    input             pal_we,
    input      [10:0] pal_waddr,
    input      [23:0] pal_din,

    // PF data RAM (one bus per layer): 2048 x 16-bit
    output            pf1_ram_cs, output [10:0] pf1_ram_addr, input [15:0] pf1_ram_data, input pf1_ram_ok,
    output            pf2_ram_cs, output [10:0] pf2_ram_addr, input [15:0] pf2_ram_data, input pf2_ram_ok,
    output            pf3_ram_cs, output [10:0] pf3_ram_addr, input [15:0] pf3_ram_data, input pf3_ram_ok,
    output            pf4_ram_cs, output [10:0] pf4_ram_addr, input [15:0] pf4_ram_data, input pf4_ram_ok,

    // PF gfx ROM (reshuffled planar, 32-bit word = 8 px): PF1=gfx1_chars8, PF2=gfx1_tiles16,
    // PF3/PF4=gfx2_tiles16
    output            pf1_rom_cs, output [18:0] pf1_rom_addr, input [31:0] pf1_rom_data, input pf1_rom_ok,
    output            pf2_rom_cs, output [18:0] pf2_rom_addr, input [31:0] pf2_rom_data, input pf2_rom_ok,
    output            pf3_rom_cs, output [18:0] pf3_rom_addr, input [31:0] pf3_rom_data, input pf3_rom_ok,
    output            pf4_rom_cs, output [18:0] pf4_rom_addr, input [31:0] pf4_rom_data, input pf4_rom_ok,

    // sprite tables (buffered spriteram, 256 x 4 words)
    output     [ 9:0] obj0_tbl_addr, input [15:0] obj0_tbl_dout,
    output     [ 9:0] obj1_tbl_addr, input [15:0] obj1_tbl_dout,

    // sprite gfx ROM (reshuffled planar, BPP bytes / 8-px half-row)
    output            obj0_rom_cs, output [20:0] obj0_rom_addr, input [39:0] obj0_rom_data, input obj0_rom_ok,
    output            obj1_rom_cs, output [20:0] obj1_rom_addr, input [31:0] obj1_rom_data, input obj1_rom_ok,

    input      [ 2:0] obj1_base,          // runtime obj1 palette base (0x164008)
    input      [ 2:0] tm_bank0,           // runtime tilemap colour bank PF3 (0x164000)
    input      [ 2:0] tm_bank1,           // runtime tilemap colour bank PF4 (0x164000)
    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue,
    output     [111:0] dbg_pixcap,       // DIAGNOSTIC (diag6): captured shadow/mist blend src+dst+alpha
    output     [ 7:0] dbg_mist            // DIAGNOSTIC (diag9): mist-enable-chain forensics
);

wire [ 7:0] pf1_pxl, pf2_pxl, pf3_pxl, pf4_pxl;
wire [15:0] obj0_pxl, obj1_pxl;

// ---------------- 4 playfields ----------------
jtnslasher_tilemap u_pf1(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .tile8(1'b1), .bank(2'b0), .flip_en(pf1_flip),
    .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
    .scrx(pf1_scrx), .scry(pf1_scry),
    .ram_cs(pf1_ram_cs), .ram_addr(pf1_ram_addr), .ram_data(pf1_ram_data), .ram_ok(pf1_ram_ok),
    .rom_cs(pf1_rom_cs), .rom_addr(pf1_rom_addr), .rom_data(pf1_rom_data), .rom_ok(pf1_rom_ok),
    .pxl(pf1_pxl)
);

jtnslasher_tilemap u_pf2(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .tile8(1'b0), .bank(pf2_bank), .flip_en(pf2_flip),
    .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
    .scrx(pf2_scrx), .scry(pf2_scry),
    .ram_cs(pf2_ram_cs), .ram_addr(pf2_ram_addr), .ram_data(pf2_ram_data), .ram_ok(pf2_ram_ok),
    .rom_cs(pf2_rom_cs), .rom_addr(pf2_rom_addr), .rom_data(pf2_rom_data), .rom_ok(pf2_rom_ok),
    .pxl(pf2_pxl)
);

jtnslasher_tilemap u_pf3(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .tile8(1'b0), .bank(pf3_bank), .flip_en(pf3_flip),
    .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
    .scrx(pf3_scrx), .scry(pf3_scry),
    .ram_cs(pf3_ram_cs), .ram_addr(pf3_ram_addr), .ram_data(pf3_ram_data), .ram_ok(pf3_ram_ok),
    .rom_cs(pf3_rom_cs), .rom_addr(pf3_rom_addr), .rom_data(pf3_rom_data), .rom_ok(pf3_rom_ok),
    .pxl(pf3_pxl)
);

jtnslasher_tilemap u_pf4(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .tile8(1'b0), .bank(pf4_bank), .flip_en(pf4_flip),
    .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
    .scrx(pf4_scrx), .scry(pf4_scry),
    .ram_cs(pf4_ram_cs), .ram_addr(pf4_ram_addr), .ram_data(pf4_ram_data), .ram_ok(pf4_ram_ok),
    .rom_cs(pf4_rom_cs), .rom_addr(pf4_rom_addr), .rom_data(pf4_rom_data), .rom_ok(pf4_rom_ok),
    .pxl(pf4_pxl)
);

// ---------------- 2 sprite layers ----------------
jtnslasher_obj #(.BPP(5)) u_obj0(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
    .vrender(vrender), .hdump(hdump),
    .tbl_addr(obj0_tbl_addr), .tbl_dout(obj0_tbl_dout),
    .rom_cs(obj0_rom_cs), .rom_addr(obj0_rom_addr), .rom_data(obj0_rom_data), .rom_ok(obj0_rom_ok),
    .pxl(obj0_pxl)
);

jtnslasher_obj #(.BPP(4)) u_obj1(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
    .vrender(vrender), .hdump(hdump),
    .tbl_addr(obj1_tbl_addr), .tbl_dout(obj1_tbl_dout),
    .rom_cs(obj1_rom_cs), .rom_addr(obj1_rom_addr), .rom_data(obj1_rom_data), .rom_ok(obj1_rom_ok),
    .pxl(obj1_pxl)
);

// ---------------- colour mixer (Ace) ----------------
jtnslasher_colmix u_colmix(
    .clk(clk), .pxl_cen(pxl_cen),
    .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
    .pf1_pxl(pf1_pxl), .pf2_pxl(pf2_pxl), .pf3_pxl(pf3_pxl), .pf4_pxl(pf4_pxl),
    .obj0_pxl(obj0_pxl), .obj1_pxl(obj1_pxl),
    .en1(en1), .en2(en2), .en3(en3), .en4(en4), .pri(pri), .ace_alpha(ace_alpha),
    .LVBL(LVBL), .ace_fade(ace_fade), .fade_mult(fade_mult), .fade_trig(fade_trig),
    .paldma(paldma), .ace_tile(ace_tile), .obj1_base(obj1_base), .tm_bank0(tm_bank0), .tm_bank1(tm_bank1),
    .red(red), .green(green), .blue(blue),
    .dbg_pixcap(dbg_pixcap), .dbg_mist(dbg_mist)
);

endmodule
