/*  Night Slashers — colour mixer (chip 99 "Ace"). Composites 4 playfields + 2 sprite layers into
    24-bit RGB per VIDEO_UPDATE(nslasher) (deco32_v.cpp mix_nslasher + deco_ace.cpp).

    Per-pixel composite (pri[0] swaps PF2/PF3 priority tags):
      backdrop pen 0x300 -> PF4(tag1) -> mid=pri?PF2:PF3 (tag2) -> front=pri?PF3:PF2 (tag4)
      -> obj0 (gfx3, opaque, drawn per pri0 vs tilemap priority)
      -> obj1 (gfx4, deco_ace get_alpha blend, per pri1) -> PF1 (text) on top.
    Pen bases (GFXDECODE nslasher): PF1=0x000 PF2=0x100 PF3=0x200 PF4=0x300, obj0=0x400 (5bpp,
    gran 32) obj1=0x600 (4bpp, gran 16). obj pixel = {colour[7:0],pen[7:0]} from jtnslasher_obj.

    Build A: obj1 alpha = deco_ace get_alpha(ace[0x00-0x05]) gated by alpha1/alpha2, not a fixed 50%.
    Build B: ACE palette = faded (lerped toward ace[0x20-0x26]) + raw (CPU value). Sprites read RAW
    when (m_pri&4)==0 (pri[2]==0), else faded; PF always read faded. The faded half is recomputed by
    a VBLANK FSM whenever the palette DMA (0x16c008) or a fade-reg (ace[0x20-0x26]) write fires
    (fade_trig).

    Build D (dual-mirror snapshot -- replaces the nf16 single-RAM "live-sweep" design that shipped to
    HW and FAILED): nf16 computed faded[i]=fade(raw[i]) by sweeping a raw/faded address-split of ONE
    RAM that stayed CPU-writable, on the SAME address the FSM was sweeping, for the whole ~2048-entry
    sweep. A scene-transition batch write landing mid-sweep produced a TORN faded image (some entries
    fade(old), some fade(new)) -- reproduced here in ver/gfx/tb_colmix_midsweep_tear.v against the
    undamaged Build B baseline (jtnslasher_colmix.v.orig-buffered-fix-bak).

    The fix replaces that single RAM with two full mirrored copies of the palette:
      pal_A (u_live)        : ALWAYS live. Every CPU palette write lands here immediately, every
                               cycle, unconditionally -- never gated, stalled, or delayed by the FSM.
                               This is the RAW/opaque display-read source (sprites read this when
                               pri[2]==0, matching the HW-proven nf15 raw/sprite-colour behaviour).
      pal_B (u_buf)          : a MIRROR of pal_A. Every CPU write is DUAL-WRITTEN into pal_B too,
                               UNLESS a freeze is active, in which case the write reaches pal_A only.
    On fade_trig (paldma OR an ace[0x20-0x26] write -- the same broad trigger set as before, not
    narrowed): pal_B's dual-write is gated off (FREEZE) from that instant, so pal_B is a coherent,
    provably-static snapshot of whatever pal_A held at the trigger, no matter how long the sweep
    takes (no further CPU write can reach it while frozen). The VBLANK FSM sweeps pal_B (never
    pal_A) to compute faded[idx] <= fade(pal_B[idx]) -- the SAME reciprocal-mult /255 pipeline as
    Build B, byte-for-byte unchanged.

    When the sweep completes, pal_B has fallen behind every CPU write that landed only in pal_A
    during the freeze, so an explicit RESYNC state walks pal_A[idx] -> pal_B[idx] for all 2048
    entries before dual-write is re-enabled. A fade_trig arriving while a freeze/sweep/resync is
    already in flight is latched in trig_pending and only allowed to start a new freeze once the FSM
    is back in IDLE (i.e. RESYNC has fully completed) -- so pal_B can never re-freeze on a stale,
    partially-resynced image.

    pal_A needs a write port plus TWO independent read consumers that must never contend: the
    mixer's raw display read, and the RESYNC source read pal_A[fsm_idx]. jtframe_dual_ram exposes
    only 2 ports, so pal_A is instantiated TWICE (u_live / u_live_shadow) with an IDENTICAL port0
    write every cycle (same addr/data/we) -- two physically separate BRAMs holding the same live
    contents. u_live's port1 is dedicated only to the mixer's raw read; u_live_shadow's port1 is
    dedicated only to the RESYNC read. This means pal_A's read path is NEVER time-multiplexed, so
    proof (3) (pal_A/raw never stalled or torn) holds unconditionally, not just "in practice".

    The externally-visible 4096-pen combined RAM (u_pal, address {1,idx}=raw/buffered upper half,
    {0,idx}=faded lower half) is kept as a plain WRITE-MIRROR of pal_B (upper half) and the FSM's
    faded output (lower half), purely so pre-existing test hierarchical references
    (u_dut.u_pal.u_ram.mem[...]) keep working unmodified; it plays no role in the freeze/resync
    mechanism itself.
*/
module jtnslasher_colmix(
    input             clk,
    input             pxl_cen,
    input             LVBL,            // VBLANK (low) — fade FSM runs here

    // CPU palette write (24-bit 0x00BBGGRR) -> RAW half
    input             pal_we,
    input      [10:0] pal_waddr,
    input      [23:0] pal_din,

    // layer pixels (aligned at hdump): PF = {colour,pix}; obj = 16-bit mix
    input      [ 7:0] pf1_pxl,
    input      [ 7:0] pf2_pxl,
    input      [ 7:0] pf3_pxl,
    input      [ 7:0] pf4_pxl,
    input      [15:0] obj0_pxl,
    input      [15:0] obj1_pxl,

    input             en1, en2, en3, en4,
    input      [ 2:0] pri,            // deco32_pri (bit2 = m_pri&4 raw/faded coloffs select)
    input      [47:0] ace_alpha,      // deco_ace obj-alpha bytes {ace[5..0][7:0]} for get_alpha()

    // deco_ace fade (Build B): {fdps_b,fdps_g,fdps_r, fdpt_b,fdpt_g,fdpt_r} = ace[0x25..0x20] low bytes
    input      [47:0] ace_fade,
    input             fade_mult,       // 1 = multiplicative (mode 0x1100) / 0 = additive (0x1000)
    input             fade_trig,       // pulse: palette-DMA (0x16c008) or ace[0x20-0x26] write
    input             paldma,          // pulse: palette-DMA (0x16c008) ONLY. Folded into the same
                                        // broad trigger as fade_trig (see module header) -- kept as a
                                        // separate port purely for interface parity with
                                        // jtnslasher_video.v/vmem.v, which already compute + pass it.

    input      [63:0] ace_tile,        // Build C: tilemap-alpha ace[0x17-0x1e] for the mist blend
    input      [ 2:0] obj1_base,       // runtime obj1 (gfx4 shadow) palette base bank (0x164008); attract=6=0x600
    input      [ 2:0] tm_bank0,        // runtime tilemap colour bank PF3 (0x164000 bits[2:0]); attract=2
    input      [ 2:0] tm_bank1,        // runtime tilemap colour bank PF4 (0x164000 bits[5:3]); attract=3 (reserved, not yet used)

    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue,
    output     [111:0] dbg_pixcap,       // DIAGNOSTIC (diag6): captured shadow/mist blend src+dst+alpha
    output     [ 7:0] dbg_mist           // DIAGNOSTIC (diag9): per-frame mist-enable-chain forensics
);

// deco_ace get_alpha (deco_ace.cpp:208-224): >0x20 -> 0x80 special ; else 255-(v<<3) clamp>=0
function [7:0] get_alpha(input [7:0] v);
    reg [8:0] sub;
    begin
        sub = 9'd255 - {v[5:0], 3'b000};
        get_alpha = (v > 8'h20) ? 8'h80 : (sub[8] ? 8'd0 : sub[7:0]);
    end
endfunction

// mixAlphaTilemap flag (deco32_v.cpp:470-471): ace[0x17]!=0 && (m_pri&3). In JOINT-8bpp mode
// (pri[1], deco32_v.cpp:491-495) the alpha-tilemap BITMAP is never drawn — the combined PF3/4
// layer + PF2-on-top replace the whole plain stack — so the mist blend and the front-PF holdout
// must NOT fire there. The raw flag still drives the obj0-pri2 on-top rule (mix_nslasher:363),
// which MAME applies in both modes (the empty alpha bitmap makes its blend a no-op, not the flag).
wire alpha_flag    = (ace_tile[7:0]!=8'd0) & (pri[1:0]!=2'd0);
wire alpha_mist_en = alpha_flag & ~pri[1];

// ---- per-PF pens + visibility ----
wire pf1on = en1 & (pf1_pxl[3:0]!=0);
wire pf2on = en2 & (pf2_pxl[3:0]!=0);
wire pf3on = en3 & (pf3_pxl[3:0]!=0);
wire pf4on = en4 & (pf4_pxl[3:0]!=0);
wire [10:0] pen1 = {3'h0, pf1_pxl};       // 0x000 | {colour,pix}
wire [10:0] pen2 = {3'h1, pf2_pxl};       // 0x100
wire [10:0] pen3 = {3'h2, pf3_pxl};       // 0x200
wire [10:0] pen4 = {3'h3, pf4_pxl};       // 0x300

wire        midon    = pri[0] ? pf2on : pf3on;
wire [10:0] midpen   = pri[0] ? pen2  : pen3;
wire        fronton  = pri[0] ? pf3on : pf2on;
wire [10:0] frontpen = pri[0] ? pen3  : pen2;

// ---- FIX B: JOINT-8bpp combined PF3/4 (pri[1]; deco32_v.cpp:491-495) ----
// mix_callback (deco32.cpp:936-939): pen = ((p&0x70f) + (((p&0x30)|(p2&0x0f))<<4)) & 0x7ff with
// p/p2 = {colour_bank, colour, pen} of PF3/PF4 (runtime tm_bank0/1 <<8 — static 2/3 in nslasher);
// transparent when the post-mix LOW BYTE (the two 4bpp pens) is 0; enable = PF3's
// (control0&0x80, doc/mame_deco16ic.c:991). PF4 must be sampled at PF3's scroll in this mode
// (custom_tilemap_draw same-src_x sampling) — muxed in jtnslasher_vmem at the u_video port map.
// OFFLINE GATE PASSED: ver/gfx/bio_render.py replays the captured Jake-bio frame (vancaps f03000;
// pri=6 there per the attract_pri.txt COMPLETE 0x150000 write log) through this exact formula ->
// 0/76800 vs MAME's own snapshot; the plain path renders the green-banded ghost = the cab symptom.
// RTL gate: ver/gfx/tb_colmix_bio.v (wsl/run_bio.sh) — pre-fix FAIL 53715, post-fix must be 76800/76800.
wire [10:0] jp    = {tm_bank0, pf3_pxl};
wire [10:0] jp2   = {tm_bank1, pf4_pxl};
wire [11:0] jsum  = {1'b0, jp & 11'h70f} + {2'b00, jp[5:4], jp2[3:0], 4'b0000};
wire [10:0] jpen  = jsum[10:0];
wire        jointon = en3 & (jpen[7:0]!=8'd0);

// ---- background stack (plain: PF4 tag1, mid tag2, front tag4 / joint: combined tag1, PF2 tag4) ----
reg  [10:0] bgpen;
reg  [ 2:0] tpri;
always @* begin
    bgpen = 11'h300; tpri = 3'd0;                       // backdrop = pen 0x300 (deco32_v.cpp:476; was 0x200 = the green left line)
    if( pri[1] ) begin
        if( jointon ) begin bgpen = jpen; tpri[0] = 1'b1; end
        if( pf2on   ) begin bgpen = pen2; tpri[2] = 1'b1; end   // PF2 on top (tag4, deco32_v.cpp:494)
    end else begin
        if( pf4on   ) begin bgpen = pen4;     tpri[0] = 1'b1; end
        if( midon   ) begin bgpen = midpen;   tpri[1] = 1'b1; end
        if( fronton ) begin
            if( ~alpha_mist_en ) bgpen = frontpen;      // mist mode: front PF held out of the stack for the alpha blend
            tpri[2] = 1'b1;                              // priority tag present either way (sprite gating)
        end
    end
end

// ---- obj0 (gfx3 5bpp): opaque, drawn per priority vs tilemap priority ----
wire        o0on  = obj0_pxl[7:0]!=8'd0;
wire [1:0]  p0    = obj0_pxl[14:13];
wire [10:0] o0pen = {2'b10, obj0_pxl[11:8], obj0_pxl[4:0]};       // 0x400 | (col0*32 + c)
// F3: MAME (deco32_v.cpp:364) draws obj0-pri2 ON TOP when mixAlphaTilemap, so the alpha foliage blends OVER the
// character (see-through), instead of the front PF dropping it. alpha_mist_en==0 -> collapses to the old (tpri<4).
wire o0draw = o0on & ( (p0==2'd0) | (p0==2'd1) | ((p0==2'd2)&(alpha_flag | (tpri<3'd4))) | ((p0==2'd3)&(tpri<3'd2)) );
wire [10:0] underpen = o0draw ? o0pen : bgpen;

// ---- obj1 (gfx4 4bpp): deco_ace variable-alpha blend (get_alpha), per priority ----
wire        o1on  = obj1_pxl[7:0]!=8'd0;
wire [1:0]  p1    = obj1_pxl[14:13];
wire        o1a   = obj1_pxl[15];                                // alpha1 (deco32_v.cpp:348)
wire [10:0] o1pen = {obj1_base, obj1_pxl[11:8], obj1_pxl[3:0]};   // (obj1_base<<8) | (col1*16 + c); base is a
                                                                  // RUNTIME reg (0x164008, MAME sprite2_color_bank_w);
                                                                  // hardcoding 3'h6 was the warm-shadow bug (base moves in-game)
wire        over0 = ~o0on | (p0==2'd3);
// FIX C (mechanism G): obj1 ALPHA pri1 0/1 tilemap-side suppression (deco32_v.cpp:410-418).
//   pri1==0 outer gate: (m_pri&1)==0 || tilemapPri[x]<4 || (mixAlphaTilemap && alphaTilemap-pen==0)
//     — alphaTilemap-pen==0 is ~fronton in plain-mist mode; in JOINT mode the alpha bitmap is
//     never drawn so the pen reads 0 everywhere (term always true).
//   pri1==1 gates: ((m_pri&1)==0 || tilemapPri[x]<4)  AND  the pri0 term relaxes to allow
//     pri0==2 when (m_pri&1)==0.  tilemapPri>=4 == tpri[2] (front PF/PF2-top tag).
// Shadows under foreground scenery (front PF) are now hidden exactly as MAME hides them.
wire alpha_empty = pri[1] | ~fronton;                            // (alphaTilemap[x]&0xf)==0
wire o1p0_tm  = ~pri[0] | ~tpri[2] | (alpha_flag & alpha_empty);
wire o1p1_tm  = ~pri[0] | ~tpri[2];
wire over0p1  = ~o0on | (p0==2'd3) | ((p0==2'd2) & ~pri[0]);
wire o1op = o1on & ~o1a & ( ((p1==2'd0)&(~o0on|(p0!=2'd0))) | (p1==2'd1) | (p1==2'd2) | (p1==2'd3) );
wire o1ad = o1on &  o1a & ( ((p1==2'd0)&over0&o1p0_tm) | ((p1==2'd1)&over0p1&o1p1_tm) | (p1==2'd2) | (p1==2'd3) );
wire o1_draw = o1op | o1ad;                                      // obj1 visible

// --- deco_ace obj alpha: aidx from obj1 colour, get_alpha LUT, gate by alpha1/alpha2 (deco32_v.cpp:390) ---
wire [3:0] o1col = obj1_pxl[11:8];
wire [2:0] aidx  = o1col[3] ? {2'b10, o1col[1]} : {1'b0, o1col[2:1]}; // (col1&8)?4+((col1&3)/2):((col1&7)/2)
wire [7:0] ace_b = (aidx==3'd0)?ace_alpha[ 7: 0] :
                   (aidx==3'd1)?ace_alpha[15: 8] :
                   (aidx==3'd2)?ace_alpha[23:16] :
                   (aidx==3'd3)?ace_alpha[31:24] :
                   (aidx==3'd4)?ace_alpha[39:32] : ace_alpha[47:40];
wire [7:0] a_lut = get_alpha(ace_b);
wire       agate = (~obj1_pxl[15]) | (~obj1_pxl[12]);            // (!alpha1 || alpha2)
wire [7:0] alpha_eff = agate ? a_lut : 8'hFF;                    // 0xFF opaque / 0 transparent / else blend

wire o1_opaque = o1_draw & (alpha_eff==8'hFF);
wire o1_blend  = o1_draw & (alpha_eff!=8'hFF) & (alpha_eff!=8'd0);

// PF1 (text) is on top of the sprite mix
wire [10:0] portA    = pf1on ? pen1 : (o1_opaque ? o1pen : underpen);
wire [10:0] portB    = o1pen;
wire        do_blend = o1_blend & ~pf1on;

// ---- raw/faded select (deco_ace coloffs): sprite -> raw when pri[2]==0 ; PF -> faded ----
// obj0 coloffs (deco32_v.cpp:352) = ~pri[2]. obj1 coloffs (deco32_v.cpp:387) = ~pri[2] & sprite1_drawn,
// where sprite1_drawn = "obj0 drew at this pixel" = o0draw. Shadows are obj1 where obj0 did NOT draw ->
// must read FADED (not raw); selB=~pri[2] alone dropped that term -> wrong shadow colour (the regression).
wire portA_o1 = ~pf1on & o1_opaque;                              // portA = o1pen  -> obj1 coloffs
wire portA_o0 = ~pf1on & ~o1_opaque & o0draw;                    // portA = o0pen  -> obj0 coloffs
// FIX C-PF1RAW (adversarial-verify confirmed, 2026-07-02): PF1 text reads the RAW half ALWAYS.
// MAME 0284 decodes the 8x8 chars at colorbase 0x800 (deco32.cpp:1884) and deco_ace maps pens
// 0x800-0xfff to the raw palette (deco_ace.cpp:181) -> PF1 is never touched by the ACE fade.
// The old "PF always read faded" premise was 2009-driver descent; visible on door-fades/scene
// fades where MAME keeps text full-colour.
wire selA = pf1on    ? 1'b1
          : portA_o1 ? (~pri[2] & o0draw) : (portA_o0 ? ~pri[2] : 1'b0);
wire selB = ~pri[2] & o0draw;                                    // portB = o1pen  -> obj1 coloffs

// ---- Build C: alpha-tilemap (mist). Front PF (pri tag4) alpha-blended last (deco32_v.cpp:443-456):
//      p=frontpen ; alpha=get_alpha(0x17 + (front_colour>>1)) ; coloffs = obj1's ; gated by sprite pri. ----
wire [7:0] frontpf  = pri[0] ? pf3_pxl : pf2_pxl;
wire [2:0] tile_off = frontpf[7:5];                              // (p&0xf0)>>4 then /2 = colour[3:1]
// F2-FIX (nf14): MAME mist pen = pal2[coloffs | p].  p = alphaTilemap[x] is the FRONT PF tilemap drawn to
// REVERTED (nf18): the nf14 "resolved pen" theory ({3'h2,frontpf}/{3'h3,frontpf}=0x200/0x300) never
// fixed the dialog on HW (that was always the separate palette-fade tearing bug, fixed properly in
// nf17 -- see the dual-mirror pal_A/pal_B header note) AND regressed the stage-2 foliage/mist, which
// HW-CONFIRMED rendered correctly under the original F2 formula. Foliage/mist usually has an obj0
// character drawn underneath it (o0draw=1 -> selC=1 -> RAW read, colmix.v:208/366), so it was NEVER
// touched by the faded-half tearing bug regardless of which mistpen base was used -- nf14's change
// was a pure regression with no compensating fix. Back to pal2 base ALONE (bare frontpf, no PF-own
// colour base baked in): pal2 = gfx[(m_pri&1)?1:2].colorbase (GFXDECODE nslasher: gfx1=0x000/gfx2=0x200).
// TILEMAP COLOUR-BANK (0x164000) applied to the mist pen. MAME: the alpha-tilemap/mist is drawn from
// tilegen[1]->tilemap_1_draw = PF3 (deco32_v.cpp:503) when pri[0]=1, and PF3 carries the runtime colour
// bank set_tilemap_colour_bank(0,(data&7)<<4) (=tm_bank0). deco16ic adds that bank to the tile COLOUR,
// which is then x16 for the pen -> pen contribution = tm_bank0<<8. Our pf3_pxl (frontpf) has colour*16+pix
// but NOT the bank, so the mist landed in bank 0x000 (green text) -> green dialog / bio / door-fade /
// absent mist. Add tm_bank0<<8. Width-safe: {3'h0,frontpf} has [10:8]=0 and frontpf in [7:0], so the add
// == OR (no carry into the colour nibble). tm_bank0=0 (default/attract) => byte-identical to before (green
// symptoms are in scenes where the game sets tm_bank0=2). PF2 (pri[0]=0) is tilegen[0] = never banked.
// REVERTED (nf23): nf22 added tm_bank0<<8 to the mist pen, which with the measured tm_bank0=2 shoved the
// stage-2 foliage mist to BANK 2 -- the exact nf14 regression. HW PROBE (diag9) PROVED the mist FIRES there
// (mist byte=1F) but is INVISIBLE at bank 2. So bank 2 is wrong for this mist; back to bank 0 (nf12/nf18,
// the "mist works!" formula). tm_bank0 plumbing kept (unused here) for the separate dialog/bio PF-bank fix.
// FIX C (mechanism G) mist pen, 0284-faithful (deco32_v.cpp:443-456): p = alphaTilemap[x] is the
// front-PF PIXMAP value, which INCLUDES the tilemap colour bank — (tm_bank0<<8) for PF3 (runtime
// set_tilemap_colour_bank, boot-static =2) / 0x100 for PF2 (static col_bank 0x10) — and pal2's
// colorbase()==0 for BOTH gfx1/gfx2 in 0284 (deco32.cpp:1885-1887; the old 0x000/0x200 pal2 bases
// were 2009-driver descent). The nf22-vs-nf12/nf18 foliage conflict is ARBITRATED (A3): the
// complete attract 0x164000 write log (mame-dump/vancaps/attract_pri.txt) shows tm_bank0 is
// written ONCE at boot (=2) and never moves -> MAME's foliage mist pen base IS 0x200; the
// "foliage right at bank 0" nf12/nf18 report is impeached. Special moves were confirmed
// MAME-accurate at this pen shape on nf22.
wire [10:0] mistpen = pri[0] ? {tm_bank0, frontpf}               // front=PF3 pixmap: (tm_bank0<<8)|p
                             : {3'h1, frontpf};                  // front=PF2 pixmap: 0x100|p
wire [7:0] tile_b   = (tile_off==3'd0)?ace_tile[ 7: 0] : (tile_off==3'd1)?ace_tile[15: 8] :
                      (tile_off==3'd2)?ace_tile[23:16] : (tile_off==3'd3)?ace_tile[31:24] :
                      (tile_off==3'd4)?ace_tile[39:32] : (tile_off==3'd5)?ace_tile[47:40] :
                      (tile_off==3'd6)?ace_tile[55:48] : ace_tile[63:56];
wire [7:0] mist_alpha = get_alpha(tile_b);
wire mist_g0   = ~o0on | (p0==2'd2) | (p0==2'd3);               // obj0 absent or low pri (deco32_v.cpp:450)
wire mist_g1   = ~o1on | (p1==2'd2) | (p1==2'd3) | o1a;         // obj1 absent/low pri/alpha (:451)
// FIX C (mechanism G): & ~pf1on — MAME mixes the alpha tilemap BEFORE drawing PF1
// (deco32_v.cpp:517-519), so text renders OVER the fog and is never tinted by it.
wire mist_draw = alpha_mist_en & fronton & mist_g0 & mist_g1 & ~pf1on;
wire selC      = ~pri[2] & o0draw;                              // mist pen coloffs (= obj1 coloffs, :456)

// ============== dual-mirror palette (pal_A live/raw, pal_B frozen-snapshot) + VBLANK fade FSM ====
// See the module header for the full design rationale. Summary of the RAM instances below:
//   pal_A (u_live)        port0 = CPU write (we=pal_we, addr=pal_waddr, ALWAYS -- unconditional)
//                         port1 = mixer raw display read (rd_addr), dedicated, never shared
//   pal_A (u_live_shadow) port0 = IDENTICAL CPU write (same addr/data/we as u_live, every cycle)
//                         port1 = RESYNC source read (pal_A[fsm_idx]), dedicated, never shared
//   pal_B (u_buf)         port0 = write, MUXED between the CPU dual-write (addr=pal_waddr,
//                                  we=pal_we & ~freeze) and the RESYNC write (addr=fsm_idx,
//                                  data=u_live_shadow[fsm_idx], during RS). These two writers never
//                                  overlap: dual-write is gated off for the ENTIRE freeze+sweep+
//                                  resync span (freeze deasserts only back in IDLE).
//                         port1 = FSM sweep read (pal_B[fsm_idx], during FC)
//   u_pal (display mirror, 4096-deep, kept for existing-TB hierarchical compatibility)
//                         port0 = write, MUXED between a write-mirror of pal_B's port0 (upper half,
//                                  address {1,pal_B's write addr}) and the FSM's faded write (lower
//                                  half, address {0,fsm_idx}, during FW)
//                         port1 = display read (rd_pen, address-selected raw-upper/faded-lower)
wire [23:0] palA_q;         // pal_A/u_live read (raw/live display source, dedicated, never shared)
wire [23:0] palA_shadow_q;  // pal_A/u_live_shadow read (RESYNC source, dedicated, never shared)
wire [23:0] palB_snap_q;    // pal_B read (FSM sweep source)
wire [23:0] faded_q;        // u_pal read (display, combined RAM)

wire [7:0] fdpt_r = ace_fade[ 7: 0], fdpt_g = ace_fade[15: 8], fdpt_b = ace_fade[23:16];
wire [7:0] fdps_r = ace_fade[31:24], fdps_g = ace_fade[39:32], fdps_b = ace_fade[47:40];

// ---- FSM states: sweep (freeze pal_B, fade it) then resync (catch pal_B back up to pal_A) ----
localparam FR=3'd0, FC=3'd1, FM1=3'd2, FM2=3'd3, FW=3'd4, RS=3'd5, IDLE=3'd6, RS2=3'd7;
reg  [ 2:0] fstate=IDLE;
reg  [10:0] fsm_idx=0;
reg         freeze=0;            // 1 = pal_B dual-write gated off: asserted from fade_trig through the
                                  // end of RESYNC (sweep + resync are both part of the frozen window)
reg         fade_dirty=0, trig_pending=0, pal_a_touched=0;
reg  [ 1:0] rs_retry=0;           // BOUNDED resync-retry counter: caps the clean-pass retry so continuous
                                   // CPU palette writes can never livelock the freeze (see RS2 comment)
reg  [23:0] raw_c, faded_r;
wire        trig_any   = fade_trig | paldma;      // same broad trigger set as before (not narrowed)
wire        resync     = (fstate==RS) | (fstate==RS2); // RESYNC in progress (pal_A -> pal_B copy)
wire        resync_wr  = (fstate==RS2);                // the WRITE-valid half-cycle of resync (read settled)
wire        fsm_active = (fstate!=IDLE) & ~LVBL;  // advance only inside VBLANK

// FM1 inputs (combinational from raw_c): |pt-c| per channel
wire [7:0] c_r = raw_c[ 7: 0], c_g = raw_c[15: 8], c_b = raw_c[23:16];
wire       ge_r = fdpt_r>=c_r, ge_g = fdpt_g>=c_g, ge_b = fdpt_b>=c_b;
wire [7:0] mg_r = ge_r?(fdpt_r-c_r):(c_r-fdpt_r);
wire [7:0] mg_g = ge_g?(fdpt_g-c_g):(c_g-fdpt_g);
wire [7:0] mg_b = ge_b?(fdpt_b-c_b):(c_b-fdpt_b);
// FM1 registers (mag*ps + carried c/ps/sign)
reg  [15:0] pr_r, pr_g, pr_b;
reg  [ 7:0] cc_r, cc_g, cc_b, sp_r, sp_g, sp_b;
reg         sg_r, sg_g, sg_b;
// FM2 combinational: q = floor(prod/255) ; combine (mult) / 9-bit saturating add
wire [31:0] qm_r = pr_r*32'h8081, qm_g = pr_g*32'h8081, qm_b = pr_b*32'h8081;
wire [7:0]  q_r = qm_r[30:23], q_g = qm_g[30:23], q_b = qm_b[30:23];
wire [8:0]  ad_r = {1'b0,cc_r}+{1'b0,sp_r}, ad_g = {1'b0,cc_g}+{1'b0,sp_g}, ad_b = {1'b0,cc_b}+{1'b0,sp_b};
wire [7:0]  fr_v = fade_mult ? (sg_r?(cc_r+q_r):(cc_r-q_r)) : (ad_r[8]?8'hFF:ad_r[7:0]);
wire [7:0]  fg_v = fade_mult ? (sg_g?(cc_g+q_g):(cc_g-q_g)) : (ad_g[8]?8'hFF:ad_g[7:0]);
wire [7:0]  fb_v = fade_mult ? (sg_b?(cc_b+q_b):(cc_b-q_b)) : (ad_b[8]?8'hFF:ad_b[7:0]);

always @(posedge clk) begin
    if( trig_any ) begin
        if( fstate!=IDLE ) trig_pending <= 1'b1;   // freeze/sweep/resync already in flight: queue it,
                                                    // do NOT let a new freeze start until back in IDLE
                                                    // (i.e. RESYNC has fully completed)
        else                fade_dirty  <= 1'b1;   // otherwise mark dirty (freeze starts next VBLANK)
    end
    case( fstate )
        IDLE: begin
            freeze <= 1'b0;
            if( ~LVBL & fade_dirty ) begin
                freeze      <= 1'b1;             // FREEZE pal_B NOW (this cycle's dual-write is gated)
                fade_dirty  <= 1'b0;
                fsm_idx     <= 11'd0;
                fstate      <= FR;
            end
        end
        FR:  if( ~LVBL ) fstate <= FC;                        // addr presented; read latency
             // (freeze stays asserted through the whole sweep+resync regardless of LVBL)
        FC:  if( ~LVBL ) begin raw_c <= palB_snap_q; fstate <= FM1; end
        FM1: if( ~LVBL ) begin                                 // stage 1: mag*ps (one mult)
                 pr_r<=mg_r*fdps_r; pr_g<=mg_g*fdps_g; pr_b<=mg_b*fdps_b;
                 cc_r<=c_r; cc_g<=c_g; cc_b<=c_b; sp_r<=fdps_r; sp_g<=fdps_g; sp_b<=fdps_b;
                 sg_r<=ge_r; sg_g<=ge_g; sg_b<=ge_b; fstate<=FM2;
             end
        FM2: if( ~LVBL ) begin faded_r <= {fb_v, fg_v, fr_v}; fstate<=FW; end   // stage 2: *recip + combine
        FW:  if( ~LVBL ) begin                                 // dedicated faded[] write, no CPU contention
                 if( fsm_idx==11'd2047 ) begin
                     fsm_idx <= 11'd0; fstate <= RS; pal_a_touched <= 1'b0; rs_retry <= 2'd0; // sweep done -> resync a CLEAN pass
                 end else begin
                     fsm_idx <= fsm_idx + 11'd1; fstate <= FR;
                 end
             end
        RS:  fstate <= RS2;                                    // address presented to u_live_shadow port1;
                                                                 // wait one cycle for the registered read
                                                                 // (jtframe_dual_ram is synchronous-read:
                                                                 // q1 reflects addr1 from the PREVIOUS
                                                                 // cycle) before using palA_shadow_q.
        RS2: begin                                             // RESYNC: pal_A[idx] -> pal_B[idx] (write
                 // NOW valid: palA_shadow_q corresponds to the address RS presented last cycle).
                 // freeze stays 1 here too (dual-write still gated) -- pal_B is caught up explicitly
                 // by this copy, NOT by re-enabling dual-write mid-resync (that could race a fresh
                 // CPU write landing in the gap between "copy" and "dual-write re-enabled"). RS/RS2 are
                 // not gated by ~LVBL: resync may spill past VBLANK into active display if it needs to.
                 // This is safe because RESYNC reads pal_A via the DEDICATED shadow-mirror read port
                 // (u_live_shadow), which never shares a cycle with the mixer's raw display read.
                 if( fsm_idx==11'd2047 ) begin
                     // BOUNDED dirty-retry: retry a clean pass if pal_A was written during this one, but at
                     // most rs_retry times, then release UNCONDITIONALLY. The old code retried on ANY write
                     // with no bound; under continuous in-game palette writes that condition is ALWAYS true,
                     // so the resync never completed -> freeze never released -> a queued fade re-trigger
                     // (trig_pending) was NEVER honored -> the faded palette half froze at a STALE fade.
                     // That is precisely the cab symptom: warm-tan in-game shadow + green dialog (both read
                     // the faded half), while the RAW portrait shadow stays correct (raw = live pal_A, never
                     // frozen). Reproduced in ver/gfx/tb_colmix_livelock.v: faded stuck 2048/2048 at the OLD
                     // fade under continuous writes, self-healing ONLY if writes pause (which they don't in
                     // combat). The bound (3) still catches the rare 2nd-trigger-during-resync race
                     // (ver/gfx/tb_colmix_resync_gate.v: a one-shot palette change settles within a couple of
                     // passes) but can never livelock: after 3 dirty passes it releases regardless. Under the
                     // continuous-write case the writes are re-uploads of the SAME content, so pal_B holds
                     // the correct (stable) palette anyway, and the freed sweep recomputes faded correctly.
                     if( pal_a_touched && (rs_retry != 2'd3) ) begin
                         fsm_idx <= 11'd0; pal_a_touched <= 1'b0; rs_retry <= rs_retry + 2'd1; fstate <= RS; // retry (bounded)
                     end else begin
                         fstate <= IDLE;                            // resync complete OR retry budget spent; clear freeze next cycle
                         if( trig_pending ) begin fade_dirty <= 1'b1; trig_pending <= 1'b0; end // queued trig free to start
                     end
                 end else begin
                     fsm_idx <= fsm_idx + 11'd1; fstate <= RS;
                 end
             end
        default: fstate <= IDLE;
    endcase
    if( pal_we ) pal_a_touched <= 1'b1;    // sticky within a resync pass; cleared only at a pass boundary above
end

// ---- pal_A: always-live write port (fans out to BOTH u_live and u_live_shadow, identically). ----
// ---- pal_B: dual-written with pal_A's CPU write UNLESS freeze is asserted (frozen snapshot). ----
wire        palA_we = pal_we;
wire [10:0] palA_wa = pal_waddr;
wire [23:0] palA_wd = pal_din;

// pal_B has TWO write sources that never overlap in time: the CPU dual-write (~freeze) and the
// RESYNC sweep (freeze&resync, sequential pal_A->pal_B copy). Both target port0 of pal_B, and
// freeze is asserted for the ENTIRE span from fade_trig through end-of-RESYNC, so palB_dualwr and
// palB_rswr are mutually exclusive by construction (never both 1 in the same cycle).
wire        palB_dualwr = pal_we & ~freeze;                    // normal mirror path
wire        palB_rswr   = resync_wr;                           // resync copy path (source = the
                                                                 // dedicated pal_A shadow read, valid
                                                                 // only during RS2 -- see RS/RS2 comment)
wire [10:0] palB_wa     = palB_rswr ? fsm_idx : pal_waddr;
wire [23:0] palB_wd     = palB_rswr ? palA_shadow_q : pal_din;
wire        palB_we     = palB_dualwr | palB_rswr;

// faded[] write into u_pal's lower half: FSM only, during FW
wire        faded_we = fsm_active & (fstate==FW);

// pal_B port1 (read): FSM sweep read (fsm_idx) during FC.
wire [10:0] palB_saddr = fsm_idx;

reg         pcen_d=0, pcen_dd=0, pcen_ddd=0, pcen_d4=0, do_blend_r=0, mist_draw_r=0;
reg  [ 7:0] alpha_r=0, mist_alpha_r=0;
reg  [23:0] rgbA_r, scene_r, out_rgb;
// PIPELINE COHERENCY (F5): the layer inputs (pf/obj0/obj1) arrive 1 clk AFTER pxl_cen (obj-buffer/tilemap RAM
// latency). The old timing read the under-pixel + latched the blend control on pxl_cen (phase 0 = STALE inputs)
// while o1pen/mist read on pcen_d/dd (fresh) -> 1-pixel comb/dithering (and the bio "monochrome" banding).
// FIX: shift every read + the control latch one phase later so ALL of them index the SAME (fresh) pixel:
//   under-pixel @ pcen_d, o1pen @ pcen_dd, mist @ pcen_ddd, control @ pcen_d, output @ pxl_cen (+1 clk latency).
wire [11:0] rd_addr  = pcen_ddd ? {selC, mistpen}    // 3rd read: mist pen (MAME pal2 base, F2)
                     : pcen_dd  ? {selB, portB}      // 2nd read: o1pen
                     :            {selA, portA};       // 1st read: under-pixel (@ pcen_d; phase-0 read unused)
wire        rd_sel   = rd_addr[11];                  // 1 = raw/live (pal_A) ; 0 = faded
wire [10:0] rd_pen   = rd_addr[10:0];

// pal_A (u_live) port1 (read): the mixer's raw display read address, DEDICATED (never shared/muxed).
// IMPORTANT: raw display reads must reflect pal_A directly (palA_q) -- NOT u_pal's upper half, which
// mirrors pal_B and therefore FREEZES during a sweep. Sprites reading raw (pri[2]==0) must never
// stall or see stale data during a freeze (proof 3), so they read palA_q, always live, unconditionally.
wire [10:0] palA_r1_addr = rd_pen;

// combined display read: RAW/live selects go straight to pal_A (u_live, always live, never frozen);
// FADED selects go through u_pal's lower half (the FSM's faded output). u_pal's upper half is kept
// only for hierarchical-reference compatibility with legacy testbenches that poke it directly; it is
// NOT read by the live mixer path (that would reintroduce the freeze-during-raw-read bug).
// ================== DIAG7 (HARDWARE DISCRIMINATOR -- NOT A KEEPER) ==================
// SIX consecutive fade/faded-half fixes (F1,F2,nf14,nf16,nf17,nf18/19) all passed simulation and
// changed NOTHING on the cab (green dialog + tan shadow persist, byte-identical). Build integrity is
// verified (files.qip -> the edited hdl, rbf md5 matches). So the faded-half machinery behaves in a
// way NO behavioural sim reproduces. This build settles WHERE the bug is, with a test that cannot be
// fooled by a self-consistent sim: FORCE every faded read to return the RAW/live palette (palA_q).
//   - If shadow + dialog now render DARK/correct on the cab => the entire fade FSM (pal_B/freeze/
//     resync/faded RAM) is the culprit (stale / never-runs / RAM-inference garbage on HW) => the fix
//     is to DELETE it and fade INLINE on read (as MAME does atomically). No more FSM patches.
//   - If shadow + dialog STILL read tan/green => the fade half is NOT the mechanism; the RAW pen at
//     the shadow/dialog index is itself wrong (obj1 colour-bank / pen index, or palette content
//     upstream) => a completely different fix. Either way we stop guessing.
// Trade-off (expected, benign): with faded==raw there is NO fade-to-black/tint; scene fades won't
// darken. In-game the fade is ~identity so normal play should look ~correct. Revert = restore the
// `rd_sel ? palA_q : faded_q` line below.
// ⚠️ The earlier "DIAG7 RESULT" was INVALID -- the cab was running the diag6 core, not diag7 (user found the
// core mix-up). So diag7 never actually ran. nf21's CONFIRMED reading gives clean evidence the OTHER way:
// char-select shadow reads RAW = correct/dark; in-game shadow reads FADED = light. Same obj1 sprite, same
// base 0x600 -> raw is right, FADED is wrong. This build (diag7b) re-runs the real experiment on the
// confirmed core: force every faded read to raw. If in-game shadow + dialog + bio ALL snap correct, the
// faded path is the unifying bug (fix = inline fade / delete FSM). Sync byte changed to 0x5A so the core is
// unmistakable this time. Revert = restore `rd_sel ? palA_q : faded_q`.
// DIAG7b RESULT (confirmed 0x5A core): forcing faded=raw changed NOTHING (shadow still light, dialog/
// bio/mist/door-fade still green, stagecoach still corrupt). => the fade path is DEFINITIVELY exonerated;
// the bug is the palette INDEX (wrong pen selected), wrong in BOTH raw and faded halves. Fade restored.
// FIX C-SELPHASE (found while gating FIX C-PF1RAW): palA_q/faded_q are SYNCHRONOUS-read outputs
// (they reflect the PREVIOUS cycle's rd_pen), but rd_sel was the CURRENT cycle's rd_addr[11] —
// the raw/faded mux select was one phase ahead of its data. The old selA/selB/selC values were
// accidentally pairwise-equal across consecutive phases so the misalignment never surfaced;
// PF1RAW (selA=1 on text while selB=0) broke the accident. Register the select so it travels
// with the data — exact at every phase and any cen ratio.
reg rd_sel_r;
always @(posedge clk) rd_sel_r <= rd_sel;
wire [23:0] pal_q = rd_sel_r ? palA_q : faded_q;

// deco_ace alpha_blend_r32(d,s,a) = (s*a + d*(256-a))>>8 ; a=0xFF routed as opaque replace upstream
function [7:0] blend8(input [7:0] d, input [7:0] s, input [7:0] a);
    reg [16:0] t;
    begin
        t = s*a + d*(9'd256 - {1'b0,a});
        blend8 = t[15:8];
    end
endfunction

always @(posedge clk) begin
    pcen_d   <= pxl_cen;
    pcen_dd  <= pcen_d;
    pcen_ddd <= pcen_dd;
    pcen_d4  <= pcen_ddd;
    if( pcen_d   ) begin do_blend_r <= do_blend; alpha_r <= alpha_eff;   // control latched on FRESH inputs (was pxl_cen=stale)
                         mist_draw_r <= mist_draw; mist_alpha_r <= mist_alpha; end
    if( pcen_dd  ) rgbA_r  <= pal_q;                    // pal[portA] (under-pixel, read @ pcen_d)
    if( pcen_ddd ) scene_r <= do_blend_r ?              // pal[portB]=o1pen (read @ pcen_dd) : obj1 deco_ace blend
          { blend8(rgbA_r[23:16], pal_q[23:16], alpha_r),
            blend8(rgbA_r[15: 8], pal_q[15: 8], alpha_r),
            blend8(rgbA_r[ 7: 0], pal_q[ 7: 0], alpha_r) }
          : rgbA_r;
    // FIX C-CEN (found by the fixc-adversarial-verify pass, 2026-07-02 — THE S7 ROOT-CAUSE CLASS):
    // this final latch was `if( pxl_cen )`. The mist pen address is presented at pcen_ddd, so
    // pal_q holds pal[mistpen] exactly ONE cycle later. Every colmix tb runs a 4-clk cen where
    // pcen_ddd+1 == the next pxl_cen, so the sims aligned BY ACCIDENT — but the real core runs
    // JTFRAME_PXLCLK=6 off clk=48 MHz = an 8-clk cen (cfg/macros.def:12), where pal_q at pxl_cen
    // has fallen back to pal[{selA,portA}] (the rd_addr default arm). blend(scene, scene, a) is
    // a NO-OP -> the mist was INVISIBLE ON HW at ANY pen/alpha (diag9 "fires but nothing shows",
    // five pen-formula builds changing nothing, the user's "softer screens" = partial un-blend of
    // obj1 pixels). Latching at pcen_d4 (= pcen_ddd+1, cen-ratio-independent) is byte-identical
    // at the TBs' 4-clk cen and correct at the hardware's 8. TBs now run BOTH spacings.
    if( pcen_d4  ) out_rgb <= mist_draw_r ?             // pal[portC]=mist pen (read @ pcen_ddd) : alpha-mist over the scene
          { blend8(scene_r[23:16], pal_q[23:16], mist_alpha_r),
            blend8(scene_r[15: 8], pal_q[15: 8], mist_alpha_r),
            blend8(scene_r[ 7: 0], pal_q[ 7: 0], mist_alpha_r) }
          : scene_r;
end

// DIAGNOSTIC (diag6): three theory-driven colmix fixes in a row (mist-base, buffered-DMA, dual-mirror
// tearing) all sim-verified but did NOT move the persistent HW symptom (green dialog, light in-game
// shadow) -- time to read the ACTUAL blend inputs off the cab instead of guessing a 4th time. Capture
// the real src/dst/alpha the shadow (obj1) and mist (dialog) blends used, the LAST time each fired.
reg [23:0] cap_shadow_src=0, cap_shadow_dst=0, cap_mist_src=0, cap_mist_dst=0;
reg [ 7:0] cap_shadow_a=0, cap_mist_a=0;
always @(posedge clk) begin
    if( pcen_ddd & do_blend_r ) begin            // shadow blend firing THIS cycle: s=pal_q d=rgbA_r a=alpha_r
        cap_shadow_src <= pal_q; cap_shadow_dst <= rgbA_r; cap_shadow_a <= alpha_r;
    end
    if( pcen_d4 & mist_draw_r ) begin            // mist/dialog blend firing THIS cycle: s=pal_q d=scene_r a=mist_alpha_r
        // FIX C-CEN: was pxl_cen — the same wrong-phase sample as the old out_rgb latch, so any
        // HW mistSrc probe reading would have shown the UNDER-PIXEL colour and misled diagnosis.
        cap_mist_src <= pal_q; cap_mist_dst <= scene_r; cap_mist_a <= mist_alpha_r;
    end
end

// DIAG9 mist-enable-chain forensics: per-frame sticky flags showing HOW FAR the mist gets. Read on a
// scene where mist SHOULD show (stage-2 mist, dialog): 0x00=not armed (ace[0x17]==0 or pri&3==0);
// 0x01=armed only (front PF absent -> mist source layer missing); 0x03=+front present; 0x07=+obj0 not
// blocking; 0x0F=full mist_draw condition met; 0x1F=mist actually FIRED (so absence is the pen/blend).
reg s_en=0, s_front=0, s_g0=0, s_g1=0, s_draw=0, lvbl_dly=0;
reg [7:0] dbg_mist_r=0;
assign dbg_mist = dbg_mist_r;
always @(posedge clk) begin
    lvbl_dly <= LVBL;
    if( LVBL & ~lvbl_dly ) begin                 // frame edge (LVBL rising) -> latch + clear stickies
        dbg_mist_r <= {3'd0, s_draw, s_g1, s_g0, s_front, s_en};
        s_en<=0; s_front<=0; s_g0<=0; s_g1<=0; s_draw<=0;
    end else begin
        if( alpha_mist_en )                                 s_en    <= 1'b1;
        if( alpha_mist_en & fronton )                       s_front <= 1'b1;
        if( alpha_mist_en & fronton & mist_g0 )             s_g0    <= 1'b1;
        if( alpha_mist_en & fronton & mist_g0 & mist_g1 )   s_g1    <= 1'b1;
        if( mist_draw )                                     s_draw  <= 1'b1;
    end
end
// pack: [111:88]=shadow_src [87:64]=shadow_dst [63:56]=shadow_a [55:32]=mist_src [31:8]=mist_dst [7:0]=mist_a
assign dbg_pixcap = { cap_shadow_src, cap_shadow_dst, cap_shadow_a, cap_mist_src, cap_mist_dst, cap_mist_a };

// pal_A (u_live): port0 = CPU write (always live, never gated, never stalled by the FSM) ;
//                 port1 = mixer raw display read (rd_addr), dedicated, never shared with anything.
// Named u_live to match the hierarchical refs the existing colmix testbenches
// (tb_colmix_bufferfade.v / tb_colmix_fade_stall.v) already use.
jtframe_dual_ram #(.DW(24),.AW(11)) u_live(
    .clk0(clk), .data0(palA_wd), .addr0(palA_wa), .we0(palA_we), .q0(),
    .clk1(clk), .data1(24'd0),   .addr1(palA_r1_addr), .we1(1'b0),  .q1(palA_q) );

// pal_A shadow (u_live_shadow): a SECOND physical copy of pal_A, written IDENTICALLY to u_live every
// cycle (same addr/data/we), whose port1 is dedicated solely to the RESYNC source read
// pal_A[fsm_idx]. This is what makes proof (3) (pal_A never stalled) hold unconditionally: the
// mixer's raw read (u_live port1) is never time-shared with the resync read (u_live_shadow port1).
jtframe_dual_ram #(.DW(24),.AW(11)) u_live_shadow(
    .clk0(clk), .data0(palA_wd), .addr0(palA_wa), .we0(palA_we), .q0(),
    .clk1(clk), .data1(24'd0),   .addr1(fsm_idx),  .we1(1'b0),  .q1(palA_shadow_q) );

// pal_B (u_buf): the freeze/resync mirror. Written by the CPU dual-write when NOT frozen, or by the
// RESYNC copy (source = u_live_shadow[fsm_idx]) once the sweep has drained pal_B. Read by the FSM
// sweep (palB_saddr=fsm_idx during FC).
jtframe_dual_ram #(.DW(24),.AW(11)) u_buf(
    .clk0(clk), .data0(palB_wd), .addr0(palB_wa), .we0(palB_we), .q0(),
    .clk1(clk), .data1(24'd0),   .addr1(palB_saddr), .we1(1'b0),  .q1(palB_snap_q) );

// u_pal: combined 4096-pen DISPLAY RAM, kept as a single addressable RAM with the SAME address split
// as Build B ({1,idx}=raw/buffered upper half, {0,idx}=faded lower half) purely so pre-existing test
// hierarchical references (u_dut.u_pal.u_ram.mem[...]) keep working unmodified. Upper half is a
// WRITE-MIRROR of pal_B's port0 (whatever pal_B's write port receives -- dual-write OR resync-write
// -- lands here too, same cycle); lower half is the FSM's faded output. u_pal is a display-read
// mirror only; it plays no role in the freeze/resync mechanism.
wire [11:0] palU_wa = faded_we ? {1'b0, fsm_idx} : {1'b1, palB_wa};
wire [23:0] palU_wd = faded_we ? faded_r         : palB_wd;
wire        palU_we = faded_we | palB_we;

jtframe_dual_ram #(.DW(24),.AW(12)) u_pal(
    .clk0(clk), .data0(palU_wd), .addr0(palU_wa), .we0(palU_we), .q0(),
    .clk1(clk), .data1(24'd0),   .addr1({1'b0, rd_pen}),  .we1(1'b0),    .q1(faded_q) );

assign red   = out_rgb[ 7: 0];
assign green = out_rgb[15: 8];
assign blue  = out_rgb[23:16];

endmodule
