/*  Night Slashers — gfx SDRAM fetch adapter (task #7c, Arch B).
    Maps the 6 render-engine gfx ROM buses (from jtnslasher_video) onto the JTFRAME-generated SDRAM
    bus ports (jtnslasher_game_sdram, from cfg/mem.yaml).

      PF1/PF2 <- gfx1 (mbh-00, ENCRYPTED reorder(raw), 16-bit) via jtnslasher_gfxdec wrappers that
                 decrypt(deco56)+reshuffle at fetch: PF1 chars8 (8x8), PF2 tiles16 (16x16). Both read
                 the SAME gfx1 region through two framework ports gfx1a (PF1) / gfx1b (PF2).
      PF3/PF4 <- gfx2 (mbh-01, ENCRYPTED reorder(raw), 16-bit) via deco74 tiles16 wrappers -> gfx2a/gfx2b.

      obj0 (gfx3 5bpp) <- BANDWIDTH FOLD: ONE DW32-DOUBLE bus.  Each sprite-tile-row's 40 bits live in an
                 8-byte slot: 32-bit word @(nwi*2) = planes 0-3 (native), word @(nwi*2+1) = {pad,plane4}.
                 A DW32 DOUBLE slot bursts the full 64 bits and the bcache holds BOTH 32-bit halves, so the
                 2-read FSM below = read planes (ONE SDRAM burst) + read plane4 (CACHE HIT) -> 40-bit word in
                 ONE burst/tile (was two: obj0lo DW32 + obj0hi DW8). Mechanism proven on the real SDRAM path
                 in ver/sdram_main/tb_objread.v. Data layout proven in ver/gfx/fold64_pass.py.
      obj1 (gfx4 4bpp) <- obj1 (1 MB, in BA2; obj rom_addr high bits unused -> truncate to 18).

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
wire [17:0] obj1_nwi18;
wire [20:0] obj1_nwi = { obj1_rom_addr[20:5], ~obj1_rom_addr[0], obj1_rom_addr[4:1] };
assign obj1_nwi18 = obj1_nwi[17:0];

// ---- obj0: 2-read FSM over ONE DW32-DOUBLE slot ----
// per nwi 8-byte slot: word{nwi,0}=planes(native), word{nwi,1}={pad24,plane4}. read planes (burst) then
// plane4 (cache hit) -> ONE SDRAM burst/tile. cs toggled low for 1 clk between reads = clean re-request
// (matches jtframe_romrq "toggle addr_ok for each request"), so obj0_ok is never stale across the two reads.
//
// FRESH-OK HARDENING (sim-driven, ver/sdram_main/tb_objfold_combined.v): the obj0 slot is
// jtframe_rom_1slot DW32 DOUBLE with SLOT0_OKLATCH=1 -> obj0_ok (data_ok) is LATCHED. To make the
// two-read latch robust against ANY ok-phase relationship, each read latches its word only on a
// FRESH obj0_ok RISING EDGE observed *after* the address for that read was issued -- never on a
// level that could still be the previous read's latched ok. This mirrors jtnslasher_obj.v's
// `rom_good <= rom_cs & rom_ok;` / clear-on-new-request pattern. `o0_ok_d` is the 1-clk-delayed
// obj0_ok; a new request (state entry that drives a fresh address) forces o0_ok_d low so the next
// high obj0_ok reads as a clean rising edge for the new word.
localparam O0_IDLE=3'd0, O0_PL=3'd1, O0_GAP=3'd2, O0_P4=3'd3, O0_DONE=3'd4;
reg  [2:0]  o0st;
reg  [20:0] o0_nwi;
reg  [31:0] o0_planes, o0_p4word;
reg         o0_ok_d;                                       // 1-clk-delayed obj0_ok (edge detect)
wire        o0_ok_rise = obj0_cs & obj0_ok & ~o0_ok_d;     // FRESH ok: low->high under our cs

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        o0st<=O0_IDLE; obj0_cs<=1'b0; obj0_addr<=22'd0; o0_nwi<=21'd0; o0_planes<=32'd0; o0_p4word<=32'd0;
        o0_ok_d<=1'b0;
    end else begin
        o0_ok_d <= obj0_cs & obj0_ok;                      // track ok; auto-clears when cs drops
        case( o0st )
            O0_IDLE: if( obj0_rom_cs ) begin
                        o0_nwi    <= obj0_nwi;
                        obj0_addr <= { obj0_nwi, 1'b0 };   // planes word
                        obj0_cs   <= 1'b1;
                        o0_ok_d   <= 1'b0;                 // new request -> require a fresh ok edge
                        o0st      <= O0_PL;
                     end
            O0_PL:   if( !obj0_rom_cs ) begin obj0_cs<=1'b0; o0st<=O0_IDLE; end   // engine aborted
                     else if( o0_ok_rise ) begin           // FRESH planes ok (not a stale latched ok)
                        o0_planes <= obj0_data;
                        obj0_cs   <= 1'b0;                 // drop cs 1 clk -> clean re-request
                        o0st      <= O0_GAP;
                     end
            O0_GAP:  begin
                        obj0_addr <= { o0_nwi, 1'b1 };     // plane4 word (cache hit)
                        obj0_cs   <= 1'b1;
                        o0_ok_d   <= 1'b0;                 // new request -> require a fresh ok edge
                        o0st      <= O0_P4;
                     end
            O0_P4:   if( !obj0_rom_cs ) begin obj0_cs<=1'b0; o0st<=O0_IDLE; end
                     else if( o0_ok_rise ) begin           // FRESH plane4 ok (defeats latched stale ok)
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
// planes 0-3 are stored byteswapped in SDRAM (mame2mra reverse=true) -> hwswap16 un-swaps them.
// plane4 is stored NATIVE (mame2mra map="10", no reverse) like the byteswap-immune pre-fold DW8
// obj0hi bus -> read it straight from the low byte, do NOT hwswap it. (Candidate fix for the HW
// sprite garble: the old FSM hwswapped plane4 and the cab garbled plane4-only. Confirm on cab.)
wire [31:0] o0_p4_un = hwswap16(o0_p4word); assign obj0_rom_data = { o0_p4_un[7:0], plane_permute(hwswap16(o0_planes)) };
assign obj0_rom_ok   = (o0st==O0_DONE);

// obj1 gfx4 4bpp (1 MB, in BA2; nwi high bits 0 for gfx4 -> truncate to 18)
assign obj1_cs    = obj1_rom_cs;  assign obj1_addr  = obj1_nwi18;
assign obj1_rom_data = plane_permute(hwswap16(obj1_data)); assign obj1_rom_ok = obj1_ok;

endmodule
