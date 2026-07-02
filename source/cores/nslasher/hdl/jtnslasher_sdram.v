/*  Night Slashers — gfx SDRAM fetch adapter (task #7c, Arch B + obj0 nf24 SINGLE-FETCH 8-byte-slot fold).
    Maps the 6 render-engine gfx ROM buses (from jtnslasher_video) onto the JTFRAME-generated SDRAM
    bus ports (jtnslasher_game_sdram, from cfg/mem.yaml).

      PF1/PF2 <- gfx1 (mbh-00, ENCRYPTED reorder(raw), 16-bit) via jtnslasher_gfxdec wrappers that
                 decrypt(deco56)+reshuffle at fetch: PF1 chars8 (8x8), PF2 tiles16 (16x16). Both read
                 the SAME gfx1 region through two framework ports gfx1a (PF1) / gfx1b (PF2).
      PF3/PF4 <- gfx2 (mbh-01, ENCRYPTED reorder(raw), 16-bit) via deco74 tiles16 wrappers -> gfx2a/gfx2b.

      obj0 (gfx3 5bpp) <- nf24 SINGLE-FETCH: ONE DW32-DOUBLE bus over an 8-byte-slot pack in a 16 MB BA3
                 (JTFRAME_SDRAM_LARGE + JTFRAME_BA3_LEN=64). Per nwi: planes word @ byte 8*nwi, plane4
                 byte @ byte 8*nwi+4 (dwnld pack, ver/gfx/verify_fold8_gateB.py PASS).
                 read#1 = planes word @ 32b-word {nwi,0}: ONE 4-beat burst fills the bcache with BOTH
                 32-bit lines of the slot; read#2 = plane4 word @ {nwi,1} = guaranteed CACHE HIT (~2 clk).
                 => ONE SDRAM row-cycle per fetch (nf23 HW probe measured 46-66 clk on the 2-burst dense
                 layout = the heavy-combat comb; the pipelined engine absorbs ~19 clk).
                 plane4 = read#2 data[7:0] (byte 8*nwi+4 = the EVEN byte; .mra doubles the plane4 stream
                 with map="01" so the byte lands in the even lane — nf5's map="10" put it in the ODD lane
                 while reading [7:0] = THE garble; closed by GATE B, real-loader byte-exact 1495296/1495296).
      obj1 (gfx4 4bpp) <- obj1 (1 MB, nf24: relocated to the BA2 tail @ GFX4_OFFSET; addr/data/transform
                 unchanged — only the bank moved. nwi high bits unused -> truncate to 18).

    HANDSHAKE: LEVEL ok (obj0_cs & obj0_ok) on both reads. The romrq_bcache data_ok is combinational on
    the (registered) cache hit: read#1's ok cannot assert before the 4-beat burst completes (cache_ok is
    gated off during the fill with DOUBLE=1), read#2's ok asserts ~2 clk after the addr switch (hit on
    the second cached line, NO second SDRAM burst). The 1-clk cs drop in O0_GAP keeps the request
    boundary clean (romrq "toggle addr_ok per request"). No OKLATCH edge-detect needed (bcache OKLATCH
    is vestigial in this jtframe version; data_ok is hit-based).

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
    output reg        obj0_cs,   output reg [21:0] obj0_addr, input [31:0] obj0_data, input obj0_ok,
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

// ---- obj0: 2-read FSM over the nf24 8-byte-slot pack (DW32-DOUBLE, SDRAM_LARGE, BA3_LEN=64) ----
// per nwi: read#1 planes word @ 32b-word {nwi,0} (byte 8*nwi). The DOUBLE slot's 4-beat burst fills
// the bcache with BOTH 32-bit lines of the slot ({nwi,0}=planes, {nwi,1}=plane4 word). read#2 then
// switches to {nwi,1} = a guaranteed CACHE HIT (~2 clk, NO second SDRAM burst) -> ONE row-cycle/fetch.
// LEVEL ok handshake on both reads: with DOUBLE=1 the bcache holds cache_ok low for the WHOLE 4-beat
// fill (read#1 ok cannot fire early/torn) and serves read#2 combinationally from the hit. The 1-clk cs
// drop in O0_GAP = clean re-request (matches jtframe_romrq "toggle addr_ok per request").
// Byte-exact vs MAME spritelayout_5bpp per ver/gfx/verify_fold8_gateA.py (packing math) +
// verify_fold8_gateB.py (REAL loader: .mra -> big-endian mra2rom -> dwnld remap -> this read model).
localparam O0_IDLE=3'd0, O0_PL=3'd1, O0_GAP=3'd2, O0_P4=3'd3, O0_DONE=3'd4;
reg  [2:0]  o0st;
reg  [20:0] o0_nwi;
reg  [31:0] o0_planes, o0_p4word;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        o0st<=O0_IDLE; obj0_cs<=1'b0; obj0_addr<=22'd0; o0_nwi<=21'd0; o0_planes<=32'd0; o0_p4word<=32'd0;
    end else begin
        case( o0st )
            O0_IDLE: if( obj0_rom_cs ) begin
                        o0_nwi    <= obj0_nwi;
                        obj0_addr <= { obj0_nwi, 1'b0 };   // planes word @ 32b-word 2*nwi (byte 8*nwi)
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
                        obj0_addr <= { o0_nwi, 1'b1 };     // plane4 word @ 2*nwi+1 (byte 8*nwi+4) = cache HIT
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
// planes: hwswap16 (un-swap the .mra interleave16 big-endian pair order) then plane_permute (proven).
// plane4: byte 8*nwi+4 = the EVEN byte of the plane4 word = data[7:0] RAW (identity byte-lane model,
// HW-proven by the nf4-dense raw lane-select nf11-nf23 + GATE B end-to-end). The .mra map="01" puts
// the plane4 byte in the even lane; bytes 8n+5..7 are unwritten/garbage and NEVER selected.
wire [7:0]  o0_p4byte = o0_p4word[7:0];
assign obj0_rom_data = { o0_p4byte, plane_permute(hwswap16(o0_planes)) };
assign obj0_rom_ok   = (o0st==O0_DONE);

// obj1 gfx4 4bpp (1 MB, nf24: BA2 tail @ GFX4_OFFSET; nwi high bits 0 for gfx4 -> truncate to 18)
// nf26 FIX A: hwswap16 ADDED. The old "no hwswap, proven 800/800" claim came from check_obj1_unpack.py
// whose golden used a WRONG region model (16-bit interleaved, 2009-driver style); pinned mame0284
// loads gfx4 PLAIN SEQUENTIAL (deco32.cpp:3861) with tilelayout planeoff {RGN/2+8,RGN/2,8,0}. Without
// hwswap16 every pen's bit-pairs swap: pen -> ((pen&3)<<2)|(pen>>2), so shadow tiles 8/9/A (single-pen
// 0xE) drew pen 0xB -> pal[0x60B]=00a6c3db = the EXACT warm tan (DB,C3,A6) the diag6 cab probe
// measured; the correct pal[0x60E] is BLACK = MAME's dark shadow. Rebuilt checker
// (check_obj1_unpack_0284.py): no-hwswap FAILS, this transform = 535040/535040 px vs 0284 golden.
assign obj1_cs    = obj1_rom_cs;  assign obj1_addr  = obj1_nwi[17:0];
assign obj1_rom_data = plane_permute(hwswap16(obj1_data)); assign obj1_rom_ok = obj1_ok;

endmodule
