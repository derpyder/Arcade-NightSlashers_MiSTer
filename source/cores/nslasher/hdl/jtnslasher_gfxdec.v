/*  Night Slashers — at-fetch tilemap gfx decrypt + reshuffle wrapper (task #7c-3, Arch B).
    Sits between one jtnslasher_tilemap's gfx ROM bus and a 16-bit SDRAM port that holds the
    deco56/deco74-ENCRYPTED, reorder(raw) gfx (chunk-swap done at download). Per render-word fetch it
    reconstructs the render-format 32-bit word the tilemap expects, decrypting on the fly — the same
    at-fetch approach as the deco156 CPU decrypt (M2b).

    Spec proven bit-exact in ver/gfx/down_pass.py (524288/524288 words, all layers):
      W      = CHARS8 ? rom_addr : {tile_id, ~half, suby}            (the two decwords are W, W+0x80000)
      a      = { W[18:11], address_table[W[10:0]] }                  (encrypted source word in SDRAM)
      decword(i,E) = BITSWAP16( E ^ xor_masks[xor_table[a&0x7ff]], swap_patterns[swap_table[i&0x7ff]] )
      render = { byteswap(decword(W+0x80000)), byteswap(decword(W)) }
    The address_table / xor / swap selects are IDENTICAL for both reads (i2=W|0x80000 shares W[10:0]),
    so a2 = a | 0x80000 and the table lookups happen once.

    CHARS8=1 -> PF1 (8x8, deco56) ; CHARS8=0 -> PF2 (deco56) / PF3,PF4 (deco74). Table .hex via params.
*/
module jtnslasher_gfxdec #(
    parameter CHARS8 = 0,
    parameter ADDRFILE = "deco56_address.hex",
    parameter XORFILE  = "deco56_xor.hex",
    parameter SWAPFILE = "deco56_swap.hex"
)(
    input             rst,
    input             clk,
    // tilemap gfx ROM bus (matches jtnslasher_tilemap)
    input             rom_cs,
    input      [18:0] rom_addr,
    output reg [31:0] rom_data,
    output reg        rom_ok,
    // 16-bit SDRAM port (encrypted reorder(raw) gfx)
    output reg        sdr_cs,
    output reg [19:0] sdr_addr,
    input      [15:0] sdr_data,
    input             sdr_ok
);

`include "deco_consts.vh"

// decrypt tables (per chip)
reg [10:0] addr_tab [0:2047];
reg [ 3:0] xor_tab  [0:2047];
reg [ 2:0] swap_tab [0:2047];
initial begin
    $readmemh(ADDRFILE, addr_tab);
    $readmemh(XORFILE,  xor_tab);
    $readmemh(SWAPFILE, swap_tab);
end

// W (dest decword index) from the render-word address
wire [18:0] W = CHARS8 ? rom_addr : { rom_addr[18:5], ~rom_addr[0], rom_addr[4:1] };

reg  [18:0] Wl;                                   // latched W
wire [10:0] wlo = Wl[10:0];
wire [10:0] ta  = addr_tab[wlo];                  // permuted source low-address
wire [ 3:0] xs  = xor_tab[ta];                    // xor-mask select (double lookup)
wire [ 2:0] ss  = swap_tab[wlo];                  // swap-pattern select

function [15:0] xorm(input [3:0] x);
    case(x)
        4'd0:xorm=XORM0; 4'd1:xorm=XORM1; 4'd2:xorm=XORM2;  4'd3:xorm=XORM3;
        4'd4:xorm=XORM4; 4'd5:xorm=XORM5; 4'd6:xorm=XORM6;  4'd7:xorm=XORM7;
        4'd8:xorm=XORM8; 4'd9:xorm=XORM9; 4'd10:xorm=XORM10; 4'd11:xorm=XORM11;
        4'd12:xorm=XORM12;4'd13:xorm=XORM13;4'd14:xorm=XORM14;4'd15:xorm=XORM15;
    endcase
endfunction
function [15:0] swapf(input [2:0] s, input [15:0] v);
    case(s)
        3'd0:swapf=`SWAP0(v); 3'd1:swapf=`SWAP1(v); 3'd2:swapf=`SWAP2(v); 3'd3:swapf=`SWAP3(v);
        3'd4:swapf=`SWAP4(v); 3'd5:swapf=`SWAP5(v); 3'd6:swapf=`SWAP6(v); 3'd7:swapf=`SWAP7(v);
    endcase
endfunction
// decword(E) for the latched selects ; bswap = byte swap for the render assembly
function [15:0] decode_word(input [15:0] e);
    decode_word = swapf(ss, e ^ xorm(xs));
endfunction
function [15:0] bswap(input [15:0] w); bswap = {w[7:0], w[15:8]}; endfunction

// HW FIX (2026-06-07, measured via probe #3 on the cab): the 16-bit gfx SDRAM word reads back
// BYTE-SWAPPED on hardware (cap_sddata=0x76E6 vs golden 0xE676 — a byteswap16; same class as the
// maincpu byteswap32, just at 16-bit width). Sound (8-bit) is immune so it never showed. Un-swap the
// SDRAM word at the decrypt input. (NOTE: the offline gfx sims load r1_gfx1.hex BIG-ENDIAN = the
// already-correct order, so they need their SDRAM hex byteswapped to match HW — TODO, separate.)
wire [15:0] sdr_data_fix = { sdr_data[7:0], sdr_data[15:8] };

reg [15:0] dec1;
localparam IDLE=3'd0, RD1=3'd1, GAP=3'd2, RD2=3'd3, HOLD=3'd4;
reg [2:0] st;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        st<=IDLE; sdr_cs<=0; rom_ok<=0; rom_data<=0; sdr_addr<=0; Wl<=0; dec1<=0;
    end else begin
        case(st)
            IDLE: begin
                rom_ok <= 0;
                if( rom_cs ) begin
                    Wl       <= W;
                    st       <= RD1;
                    sdr_cs   <= 0;          // addr/selects settle from Wl next clk
                end
            end
            RD1: begin                       // read encrypted word for W
                sdr_cs   <= 1;
                sdr_addr <= { 1'b0, Wl[18:11], ta };
                if( sdr_cs && sdr_ok ) begin
                    dec1   <= decode_word(sdr_data_fix);   // HW byteswap16 un-swap (probe #3)
                    sdr_cs <= 0;             // drop cs -> SDRAM clears ok, then request W2
                    st     <= GAP;
                end
            end
            GAP: begin
                sdr_cs   <= 1;
                sdr_addr <= { 1'b1, Wl[18:11], ta };   // a2 = a | 0x80000
                st       <= RD2;
            end
            RD2: begin                       // read encrypted word for W+0x80000
                if( sdr_cs && sdr_ok ) begin
                    rom_data <= { bswap(decode_word(sdr_data_fix)), bswap(dec1) };   // HW byteswap16 un-swap (probe #3)
                    rom_ok   <= 1;
                    sdr_cs   <= 0;
                    st       <= HOLD;
                end
            end
            HOLD: begin                      // hold rom_ok until the tilemap drops rom_cs
                if( !rom_cs ) begin rom_ok <= 0; st <= IDLE; end
            end
            default: st <= IDLE;
        endcase
    end
end

endmodule
