/*  Night Slashers — gfx SDRAM fetch adapter (task #7c, Arch B + obj0 nf4 DENSE FOLD).
    Maps the 6 render-engine gfx ROM buses (from jtnslasher_video) onto the JTFRAME-generated SDRAM
    bus ports (jtnslasher_game_sdram, from cfg/mem.yaml).

      PF1/PF2 <- gfx1 (mbh-00, ENCRYPTED reorder(raw), 16-bit) via jtnslasher_gfxdec wrappers that
                 decrypt(deco56)+reshuffle at fetch: PF1 chars8 (8x8), PF2 tiles16 (16x16). Both read
                 the SAME gfx1 region through two framework ports gfx1a (PF1) / gfx1b (PF2).
      PF3/PF4 <- gfx2 (mbh-01, ENCRYPTED reorder(raw), 16-bit) via deco74 tiles16 wrappers -> gfx2a/gfx2b.

      obj0 (gfx3 5bpp) <- nf4 DENSE FOLD: ONE DW32 bus, 2-read FSM over a DENSE pack in an 8 MB BA3 (NO
                 SDRAM_LARGE, NO DOUBLE slot).  read#1 = planes 0-3 word @ 32b-word nwi (byte 4*nwi);
                 read#2 = plane4 word @ 0x140000+(nwi>>2) (the DENSE plane4 byte-stream @ BA3-rel 0x500000,
                 4 bytes/32b word), lane-selected by nwi[1:0].  Two GENUINE bursts; level ok handshake.
                 This is the PROVEN-good layout (nf4); it reverts the nf5 8-byte-slot/16MB-LARGE pack that
                 sim-passed but garbled obj0 planes on HW.  Byte-exact per ver/gfx/verify_fold_dense.py.
      obj1 (gfx4 4bpp) <- obj1 (1 MB, in BA3 @ GFX4_OFFSET; nwi high bits unused -> truncate to 18).

    HANDSHAKE: the two obj0 reads (planes word, plane4 word) target DISTINCT BA3 regions = two GENUINE SDRAM
    bursts, so the LEVEL ok (obj0_cs & obj0_ok) is safe — the 1-clk cs drop in O0_GAP forces a clean
    re-request and the bank's ok falls until the 2nd burst completes (no stale-latch).  This is the nf4
    DENSE layout; the nf5 8-byte-slot/DOUBLE pack and its obj0_ok_l/ok_fresh edge-detect were REMOVED
    (that pack sim-passed but garbled obj0 planes on HW).

    The 4 tilemap wrappers + the obj0 2-read FSM are the sequential logic here. Decrypt tables via
    $readmemh (deco56 PF1/PF2, deco74 PF3/PF4); spec proven in ver/gfx/down_pass.py + tb_gfxdec.v.
*/
module jtnslasher_sdram(
    input             rst,
    input             clk,

    // ---- render-engine gfx ROM buses (jtnslasher_video) ----
    input             pf1_rom_cs,  input [18:0] pf1_rom_addr,  output [31:0] pf1_rom_data,  output pf1_rom_ok,
    input             pf2_rom_cs,  input [18:0] pf2_rom_addr,  output [31:0] pf2_rom_data,  output pf2_rom_ok,
    input             pf3_rom_cs,  input [18:0] pf3_rom_addr,  output [31:0] pf3_rom_data,  output pf3_rom_ok,
    input             pf4_rom_cs,  input [18:0] pf4_rom_addr,  output [31:0] pf4_rom_data,  output pf4_rom_ok,
    input             obj0_rom_cs, input [20:0] obj0_rom_addr, output [39:0] obj0_rom_data, output obj0_rom_ok,
    input             obj1_rom_cs, input [20:0] obj1_rom_addr, output [31:0] obj1_rom_data, output obj1_rom_ok,

    // ---- JTFRAME SDRAM bus ports (jtnslasher_game_sdram) ----
    output            gfx1a_cs,  output [19:0] gfx1a_addr,  input [15:0] gfx1a_data,  input gfx1a_ok,
    output            gfx1b_cs,  output [19:0] gfx1b_addr,  input [15:0] gfx1b_data,  input gfx1b_ok,
    output            gfx2a_cs,  output [19:0] gfx2a_addr,  input [15:0] gfx2a_data,  input gfx2a_ok,
    output            gfx2b_cs,  output [19:0] gfx2b_addr,  input [15:0] gfx2b_data,  input gfx2b_ok,
    output reg        obj0_cs,   output reg [20:0] obj0_addr, input [31:0] obj0_data, input obj0_ok,
    output            obj1_cs,   output [17:0] obj1_addr,   input [31:0] obj1_data,   input obj1_ok
);

// ---- PF1/PF2 <- gfx1 (deco56) ; PF3/PF4 <- gfx2 (deco74) : at-fetch decrypt+reshuffle ----
jtnslasher_gfxdec #(.CHARS8(1), .ADDRFILE("deco56_address.hex"), .XORFILE("deco56_xor.hex"), .SWAPFILE("deco56_swap.hex")) u_pf1(
    .rst(rst), .clk(clk),
    .rom_cs(pf1_rom_cs), .rom_addr(pf1_rom_addr), .rom_data(pf1_rom_data), .rom_ok(pf1_rom_ok),
    .sdr_cs(gfx1a_cs), .sdr_addr(gfx1a_addr), .sdr_data(gfx1a_data), .sdr_ok(gfx1a_ok) );

jtnslasher_gfxdec #(.CHARS8(0), .ADDRFILE("deco56_address.hex"), .XORFILE("deco56_xor.hex"), .SWAPFILE("deco56_swap.hex")) u_pf2(
    .rst(rst), .clk(clk),
    .rom_cs(pf2_rom_cs), .rom_addr(pf2_rom_addr), .rom_data(pf2_rom_data), .rom_ok(pf2_rom_ok),
    .sdr_cs(gfx1b_cs), .sdr_addr(gfx1b_addr), .sdr_data(gfx1b_data), .sdr_ok(gfx1b_ok) );

jtnslasher_gfxdec #(.CHARS8(0), .ADDRFILE("deco74_address.hex"), .XORFILE("deco74_xor.hex"), .SWAPFILE("deco74_swap.hex")) u_pf3(
    .rst(rst), .clk(clk),
    .rom_cs(pf3_rom_cs), .rom_addr(pf3_rom_addr), .rom_data(pf3_rom_data), .rom_ok(pf3_rom_ok),
    .sdr_cs(gfx2a_cs), .sdr_addr(gfx2a_addr), .sdr_data(gfx2a_data), .sdr_ok(gfx2a_ok) );

jtnslasher_gfxdec #(.CHARS8(0), .ADDRFILE("deco74_address.hex"), .XORFILE("deco74_xor.hex"), .SWAPFILE("deco74_swap.hex")) u_pf4(
    .rst(rst), .clk(clk),
    .rom_cs(pf4_rom_cs), .rom_addr(pf4_rom_addr), .rom_data(pf4_rom_data), .rom_ok(pf4_rom_ok),
    .sdr_cs(gfx2b_cs), .sdr_addr(gfx2b_addr), .sdr_data(gfx2b_data), .sdr_ok(gfx2b_ok) );

// ---- obj reshuffle helpers (unchanged from Arch B; proven == reshuffle_spr golden in down_pass.py) ----
// native {b3,b2,b1,b0} -> render planes {b2,b0,b3,b1}
function [31:0] plane_permute(input [31:0] d);
    plane_permute = { d[23:16], d[7:0], d[31:24], d[15:8] };
endfunction
// HW SDRAM byteswap: the SDRAM delivers each 16-bit half byte-swapped vs native (proven on gfxdec/playfield
// path). plane_permute expects NATIVE order, so un-swap each 16-bit half BEFORE permute.
function [31:0] hwswap16(input [31:0] d);
    hwswap16 = { d[23:16], d[31:24], d[7:0], d[15:8] };
endfunction

wire [20:0] obj0_nwi = { obj0_rom_addr[20:5], ~obj0_rom_addr[0], obj0_rom_addr[4:1] };
wire [20:0] obj1_nwi = { obj1_rom_addr[20:5], ~obj1_rom_addr[0], obj1_rom_addr[4:1] };

// ---- obj0: 2-read FSM over the nf4 DENSE pack (no DOUBLE slot, no SDRAM_LARGE) ----
// per nwi: read#1 planes word @ 32b-word `obj0_nwi` (byte 4*nwi) ; read#2 plane4 word @
//   `P4_WORD_BASE + (nwi>>2)` = the DENSE plane4 byte-stream @ BA3-rel 0x500000 (4 bytes/32b word).
// These are TWO GENUINE SDRAM bursts to DISTINCT regions, so the LEVEL ok handshake (obj0_cs & obj0_ok)
// is correct: dropping cs in O0_GAP + re-asserting with the new addr makes the bank's ok fall until the
// 2nd burst completes -> NO stale-latch (that was nf5's DOUBLE-slot SLOT0_OKLATCH hazard, gone here).
// cs toggled low 1 clk in O0_GAP = clean re-request (matches jtframe_romrq "toggle addr_ok per request").
// Byte-exact vs MAME spritelayout_5bpp per ver/gfx/verify_fold_dense.py (the proven nf4 model).
localparam O0_IDLE=3'd0, O0_PL=3'd1, O0_GAP=3'd2, O0_P4=3'd3, O0_DONE=3'd4;
localparam [20:0] P4_WORD_BASE = 21'h140000;   // dense plane4 32b-word base = 0x500000>>2
reg  [2:0]  o0st;
reg  [20:0] o0_nwi;
reg  [31:0] o0_planes, o0_p4word;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        o0st<=O0_IDLE; obj0_cs<=1'b0; obj0_addr<=21'd0; o0_nwi<=21'd0; o0_planes<=32'd0; o0_p4word<=32'd0;
    end else begin
        case( o0st )
            O0_IDLE: if( obj0_rom_cs ) begin
                        o0_nwi    <= obj0_nwi;
                        obj0_addr <= obj0_nwi;             // planes word @ 32b-word nwi (byte 4*nwi)
                        obj0_cs   <= 1'b1;
                        o0st      <= O0_PL;
                     end
            O0_PL:   if( !obj0_rom_cs ) begin obj0_cs<=1'b0; o0st<=O0_IDLE; end   // engine aborted
                     else if( obj0_cs & obj0_ok ) begin
                        o0_planes <= obj0_data;
                        obj0_cs   <= 1'b0;                 // drop cs 1 clk -> clean re-request
                        o0st      <= O0_GAP;
                     end
            O0_GAP:  begin
                        obj0_addr <= P4_WORD_BASE + (o0_nwi >> 2);  // plane4 word @ 0x140000 + (nwi>>2)
                        obj0_cs   <= 1'b1;
                        o0st      <= O0_P4;
                     end
            O0_P4:   if( !obj0_rom_cs ) begin obj0_cs<=1'b0; o0st<=O0_IDLE; end
                     else if( obj0_cs & obj0_ok ) begin
                        o0_p4word <= obj0_data;
                        obj0_cs   <= 1'b0;
                        o0st      <= O0_DONE;
                     end
            O0_DONE: if( !obj0_rom_cs ) o0st<=O0_IDLE;     // engine consumed the 40-bit word
            default: o0st<=O0_IDLE;
        endcase
    end
end

// assemble the 40-bit render word: plane4 in [39:32], planes 0-3 (permuted) in [31:0].
// planes: hwswap16 (un-swap the HW 16-bit byteswap) then plane_permute (proven non-fold transform).
// plane4: the dense 32b word holds 4 plane4 bytes; select lane o0_nwi[1:0] RAW (no hwswap — proven path).
wire [1:0]  o0_p4lane = o0_nwi[1:0];
wire [7:0]  o0_p4byte = o0_p4word[ {o0_p4lane, 3'd0} +: 8 ];
assign obj0_rom_data = { o0_p4byte, plane_permute(hwswap16(o0_planes)) };
assign obj0_rom_ok   = (o0st==O0_DONE);

// obj1 gfx4 4bpp (1 MB, in BA3 @ GFX4_OFFSET; nwi high bits 0 for gfx4 -> truncate to 18)
// NO hwswap16: the .mra delivers gfx4 NATIVE (proven check_obj1_unpack.py: no-swap=800/800, hwswap=FAIL).
// The byteswap is a controller property (same for any bank), so this proven transform holds in BA3 too.
assign obj1_cs    = obj1_rom_cs;  assign obj1_addr  = obj1_nwi[17:0];
assign obj1_rom_data = plane_permute(obj1_data); assign obj1_rom_ok = obj1_ok;

endmodule
