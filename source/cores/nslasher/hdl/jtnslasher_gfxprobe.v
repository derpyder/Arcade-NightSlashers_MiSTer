/*  Night Slashers — GFX-FETCH capture probe (DIAG, remove for real build).

    PROBE #3 (why correct PF1 tiles render as noise — measure the gfx PIXEL fetch on HW).
    Probes #1/#2 proved: drawing PF1 (tile 0x19D), palette written, layers enabled+written. So the
    bug is the gfx pixel path. This captures, at a STABLE PF1 gfx fetch (the LOWEST render-word address
    seen — deterministic once boot settles), three things so we can localise the corruption:

      cap_addr   = pf1 render-word address requested by the tilemap   (which gfx word)
      cap_dec    = the DECRYPTED 32-bit render word out of jtnslasher_gfxdec (what the tilemap draws)
      cap_sdaddr = the raw SDRAM word-address the gfxdec read
      cap_sddata = the raw 16-bit SDRAM word it got (the deco56-encrypted gfx, pre-decrypt)

    Offline compare (down_pass golden): cap_dec vs gfx1_chars8[cap_addr] -> is the gfx OUTPUT right on HW?
    cap_sddata vs r1_gfx1[cap_sdaddr] -> is the raw SDRAM right? Splits SDRAM-data vs decrypt vs address.

    cap_data is latched at the cycle pf1_ok pulses for a new minimum pf1 address. captured=1 once seen.
    Sim: ver/sdram_main/tb_gfxprobe.v -> "=== GFXPROBE SIM PASS ===". Revert: drop u_gfxprobe in
    jtnslasher_game + this file's files.qip line.
*/
module jtnslasher_gfxprobe(
    input             rst,
    input             clk,
    input             pf1_cs,
    input             pf1_ok,
    input      [18:0] pf1_addr,    // tilemap render-word address (gfxdec rom_addr)
    input      [31:0] pf1_data,    // decrypted render word (gfxdec rom_data)
    input      [19:0] gfx1a_addr,  // raw SDRAM word address
    input      [15:0] gfx1a_data,  // raw SDRAM word (encrypted)
    output reg [18:0] cap_addr,
    output reg [31:0] cap_dec,
    output reg [19:0] cap_sdaddr,
    output reg [15:0] cap_sddata,
    output reg        captured
);

reg [18:0] minaddr;
reg        pf1_ok_d;
wire       pf1_done = pf1_cs & pf1_ok & ~pf1_ok_d;   // rising edge of a completed fetch

initial begin cap_addr=0; cap_dec=0; cap_sdaddr=0; cap_sddata=0; captured=0; minaddr=19'h7ffff; end

always @(posedge clk) begin
    if( rst ) begin
        cap_addr<=0; cap_dec<=0; cap_sdaddr<=0; cap_sddata<=0; captured<=0; minaddr<=19'h7ffff; pf1_ok_d<=0;
    end else begin
        pf1_ok_d <= pf1_cs & pf1_ok;
        // require NON-ZERO decrypted data: skip blank tile-0 cells (golden 0 would be ambiguous)
        if( pf1_done && |pf1_data && (!captured || pf1_addr < minaddr) ) begin
            minaddr    <= pf1_addr;
            cap_addr   <= pf1_addr;
            cap_dec    <= pf1_data;
            cap_sdaddr <= gfx1a_addr;
            cap_sddata <= gfx1a_data;
            captured   <= 1'b1;
        end
    end
end

endmodule
