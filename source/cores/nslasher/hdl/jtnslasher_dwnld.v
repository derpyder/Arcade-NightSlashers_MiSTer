/*  Night Slashers — ROM download post-pass (nf24 SINGLE-FETCH obj0 8-byte-slot pack).
    BA0/BA1 identity. BA2 gfx1/gfx2 reorder (bit18<->19, tilemap region only — gfx4/obj1 now lives in
    the BA2 tail and MUST fall through to identity). BA3 = the obj0 slot pack. 23-bit addresses
    (JTFRAME_SDRAM_LARGE, 16 MB banks).

    BA3 stream the .mra delivers (16-bit-word addresses within BA3; see mra_fold8_draft.mra):
      planes (s1a+s1b interleave16, UNCHANGED shape): words [0, 0x280000)   — word w = planes half-word
        of nwi=w>>1 (2 words/nwi)
      plane4 DOUBLED (mbh-06/07 single-part <interleave output="16"> map="01" = plane4 byte in the
        EVEN blob byte): words [0x280000, 0x3C0000) — word i-0x280000 = {garbage, p4[nwi]} with p4 in
        the LOW (even) byte
    post_addr (into the 8-byte slots, byte 8*nwi..8*nwi+7):
      planes word w  -> { w[21:1], 1'b0, w[0] }  = 4*(w>>1) + (w&1)   (slot words 4n, 4n+1; lane-preserving)
      plane4 word i  -> { i[20:0], 2'b10 }       = 4*i + 2            (slot word 4n+2; p4 = byte 8n+4)
      slot word 4n+3 (bytes 8n+6/7) is NEVER written and NEVER read (beat3 lands in the unread half
      of the plane4 32-bit line).

    Byte-lane truth (the nf5 defect, now closed): the download is byte-transparent — blob byte b lands
    at SDRAM byte b (after the word remap), and a 32-bit read returns data[7:0] = the EVEN byte.
    Proven END-TO-END by ver/gfx/verify_fold8_gateB.py (real .mra -> big-endian mra2rom -> this remap
    -> single-read model == MAME golden, 1495296/1495296 px) on top of the HW-proven nf4-dense identity
    model (raw lane-select p4, byte-exact on the cab nf11-nf23).
*/
module jtnslasher_dwnld(
    input      [22:0] prog_addr,     // 16-bit-WORD address within the bank (23-bit, SDRAM_LARGE)
    input      [ 1:0] prog_ba,
    input      [ 7:0] prog_data,
    output reg [22:0] post_addr,
    output     [ 7:0] post_data
);

assign post_data = prog_data;        // no data transform at download

localparam [22:0] P4BASE = 23'h28_0000;   // (SPR1C_START - JTFRAME_BA3_START)>>1 : plane4 stream base
localparam [22:0] P4END  = 23'h3C_0000;   // plane4 stream end (0x140000 doubled words)

wire [22:0] p4i = prog_addr - P4BASE;     // doubled-plane4 stream index = nwi

always @* begin
    post_addr = prog_addr;                                  // BA0/BA1 identity
    // BA2: gfx1/gfx2 deco56/74 reorder (swap bit18<->19) ONLY in the tilemap region (< 0x200000
    // words = gfx1+gfx2). gfx4/obj1 (BA2-rel word 0x200000..) must NOT be reordered -> identity.
    if( prog_ba == 2'd2 && prog_addr < 23'h20_0000 )
        post_addr = { prog_addr[22:20], prog_addr[18], prog_addr[19], prog_addr[17:0] };
    else if( prog_ba == 2'd3 ) begin                        // BA3 obj0 8-byte-slot pack
        if( prog_addr < P4BASE )                            // planes: insert a 0 at bit1
            post_addr = { prog_addr[21:1], 1'b0, prog_addr[0] };
        else if( prog_addr < P4END )                        // doubled plane4: word i -> 4*i+2
            post_addr = { p4i[20:0], 2'b10 };
    end
end

endmodule
