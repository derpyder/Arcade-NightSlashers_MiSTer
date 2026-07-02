/*  Night Slashers — deco16ic-class tilemap engine (one PF layer), generalized for nslasher.

    Handles both tile sizes + banking, per deco32.c VIDEO_START/UPDATE(nslasher):
      tile8=0  16x16 (PF2/PF3/PF4): scan = deco16_scan_rows {col[5],row[4:0],col[4:0]},
               map 1024x512, gfx word addr = {tile[13:0], suby[3:0], half} (2 fetches = 16 px)
      tile8=1   8x8  (PF1, text)  : scan = tilemap_scan_rows row*64+col = {row[4:0],col[5:0]},
               map  512x256, gfx word addr = {tile[13:0], suby[2:0]}        (1 fetch  =  8 px)
    tile index = { bank[1:0], data[11:0] }  (deco32 bank -> tile[13:12]); colour = data[15:12].

    Scanline pipeline modeled on jtcop_bac06: per line, scan the tile map reading PF data RAM,
    fetch each tile row from the reshuffled planar gfx ROM, shift 4bpp into a line buffer; read
    out at pixel rate. gfx ROM layout = ver/gfx/reshuffle_gfx.py (32-bit word = 8 px, 4 planes
    byte-interleaved, bit7=leftmost: pixel = {d[31],d[23],d[15],d[7]}).

    Output pxl = { colour[3:0], pix[3:0] }; pix==0 transparent (handled by the mixer).

    PER-TILE FLIP + colour mask (FIX C2 / task #9, doc/mame_deco16ic.c get_pfN_tile_info:248-345):
    when the layer's ctl[6] flip-enable bit is set AND the tile's bit15 is set, the tile is
    flipped on that axis AND the colour attribute is masked to 3 bits (colour &= 7 — bit15+enables
    repurpose the colour MSB as the flip trigger). flip_en = {FLIPY-en, FLIPX-en}:
      PF1 = ctl12[6][1:0]  PF2 = ctl12[6][9:8]  PF3 = ctl34[6][1:0]  PF4 = ctl34[6][9:8].
    No captured attract/bio frame enables these bits (all caps ctl[6] flip bits = 0), so with
    flip_en==0 this engine is bit-identical to the pre-FIX-C2 version (layer regressions prove it);
    the mask is the C2 candidate for the invisible stage-2 mist (tile_off polluted by colour bit3).
*/
module jtnslasher_tilemap(
    input             rst,
    input             clk,
    input             pxl_cen,

    // mode / banking (from the deco16 control regs)
    input             tile8,       // 1 = 8x8 (PF1), 0 = 16x16 (PF2/PF3/PF4)
    input      [ 1:0] bank,        // tile[13:12] bank (deco32: ((ctl[7]>>k)&3))
    input      [ 1:0] flip_en,     // {FLIPY-en, FLIPX-en} per-layer ctl[6] bits (FIX C2 header note)

    // timing (shared vtimer)
    input      [ 8:0] vrender,
    input      [ 8:0] hdump,
    input             HS,
    input             LHBL,

    // scroll (16x16 map 1024x512; 8x8 map 512x256 -> low bits used)
    input      [ 9:0] scrx,
    input      [ 8:0] scry,

    // PF data RAM (tilemap VRAM): 2048 x 16-bit (tile[11:0], colour[15:12])
    output reg        ram_cs,
    output reg [10:0] ram_addr,
    input      [15:0] ram_data,
    input             ram_ok,

    // gfx ROM (planar, reshuffled): 19-bit word address, 32-bit data = 8 pixels
    output reg        rom_cs,
    output reg [18:0] rom_addr,
    input      [31:0] rom_data,
    input             rom_ok,

    output     [ 7:0] pxl          // { colour[3:0], pix[3:0] }
);

// ---- line buffer (write a line ahead, read at hdump) ----
reg  [ 8:0] buf_waddr;
reg         buf_we;

jtframe_linebuf #(.DW(8),.AW(9)) u_buffer(
    .clk     ( clk       ),
    .LHBL    ( LHBL      ),
    .wr_addr ( buf_waddr ),
    .wr_data ( buf_wdata ),
    .we      ( buf_we    ),
    .rd_addr ( hdump     ),
    .rd_data (           ),
    .rd_gated( pxl       )
);

// effective scroll position + tile geometry (mux 8x8 / 16x16)
wire [ 8:0] veff = vrender + scry;
reg  [ 9:0] hn;                                   // running scrolled X
wire [ 4:0] row  = tile8 ? veff[7:3] : veff[8:4];
wire [ 3:0] suby = tile8 ? {1'b0, veff[2:0]} : veff[3:0];
wire [ 5:0] col  = tile8 ? hn[8:3] : hn[9:4];
// 8x8 : row*64 + col = {row[4:0], col[5:0]} ; 16x16 : {col[5], row[4:0], col[4:0]}
wire [10:0] scan_addr = tile8 ? {row[4:0], col[5:0]} : {col[5], row[4:0], col[4:0]};

// ---- scan FSM: read PF data, hand tiles to the draw FSM ----
reg         scan_busy, HSl, draw, ram_good;
reg  [13:0] tile_id;
reg  [ 3:0] tile_pal;
reg         tile_fx, tile_fy;    // per-tile flip (bit15 & enable); stable through the draw —
                                  // the scan is handshake-blocked (draw_busy) until the tile drains
reg  [ 5:0] tilecnt;
reg         draw_busy;
reg         get_hsub;
wire [ 5:0] tilelim = tile8 ? 6'd42 : 6'd21;      // 320/size + margin

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ram_cs <= 0; scan_busy <= 0; HSl <= 0; draw <= 0; ram_good <= 0;
        hn <= 0; tilecnt <= 0; ram_addr <= 0; tile_fx <= 0; tile_fy <= 0;
    end else begin
        HSl      <= HS;
        draw     <= 0;
        ram_good <= ram_cs & ram_ok;
        ram_addr <= scan_addr;
        if( HSl && !HS ) begin           // start of a new line
            hn        <= scrx;
            tilecnt   <= 0;
            ram_cs    <= 1;
            scan_busy <= 1;
            ram_good  <= 0;
        end
        if( scan_busy && ram_good && !draw && !draw_busy ) begin
            tile_id  <= { bank, ram_data[11:0] };
            // FIX C2: bit15 + flip-enable => flip that axis AND colour &= 7 (see header)
            tile_pal <= (ram_data[15] & |flip_en) ? {1'b0, ram_data[14:12]} : ram_data[15:12];
            tile_fx  <= ram_data[15] & flip_en[0];
            tile_fy  <= ram_data[15] & flip_en[1];
            draw     <= 1;
            hn       <= hn + (tile8 ? 10'd8 : 10'd16);
            tilecnt  <= tilecnt + 1'd1;
            ram_good <= 0;
            if( tilecnt >= tilelim ) begin
                scan_busy <= 0;
                ram_cs    <= 0;
            end
        end
    end
end

// ---- draw FSM: fetch the tile row, shift pixels into the line buffer ----
reg  [31:0] draw_data;
reg  [ 3:0] draw_cnt;
reg         half;        // 0 = first-fetched 8 px, 1 = second (16x16 only)
reg         rom_good;
// FLIPY: invert the row within the tile. FLIPX: fetch the RIGHT half first (16x16) and emit each
// half's pixels right-to-left = shift right, tapping bit0 of each plane byte (bit7=leftmost layout).
wire [ 3:0] suby_e    = tile_fy ? (tile8 ? {1'b0, ~suby[2:0]} : ~suby) : suby;
wire [ 3:0] draw_pxl  = tile_fx ? { draw_data[24], draw_data[16], draw_data[ 8], draw_data[0] }
                                : { draw_data[31], draw_data[23], draw_data[15], draw_data[7] };
wire [ 7:0] buf_wdata = { tile_pal, draw_pxl };

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        draw_busy <= 0; buf_we <= 0; buf_waddr <= 0; rom_cs <= 0;
        draw_cnt <= 0; half <= 0; rom_good <= 0; get_hsub <= 0;
    end else begin
        rom_good <= rom_cs & rom_ok;
        if( HSl && !HS ) begin buf_waddr <= 0; get_hsub <= 1; end   // line start: arm sub-tile X scroll
        if( draw ) begin
            draw_busy <= 1;
            half      <= 0;
            rom_addr  <= tile8 ? {2'b00, tile_id, suby_e[2:0]} : {tile_id, suby_e, tile_fx};
            rom_cs    <= 1;
            rom_good  <= 0;
            draw_cnt  <= 0;
            if( get_hsub ) begin                    // sub-tile X scroll on the first tile
                buf_waddr <= 9'd0 - (tile8 ? {6'd0, hn[2:0]} : {5'd0, hn[3:0]});
                get_hsub  <= 0;
            end
        end
        if( !buf_we && rom_cs && rom_good && rom_ok && draw_cnt==0 ) begin
            draw_data <= rom_data;
            rom_cs    <= 0;
            buf_we    <= 1;
            draw_cnt  <= 7;
        end
        if( buf_we ) begin
            draw_data <= tile_fx ? (draw_data >> 1) : (draw_data << 1);
            buf_waddr <= buf_waddr + 9'd1;
            draw_cnt  <= draw_cnt - 1'd1;
            if( draw_cnt==0 ) begin
                buf_we <= 0;
                if( half || tile8 ) begin           // 8x8 = single fetch; 16x16 = two halves
                    draw_busy <= 0;
                end else begin
                    half     <= 1;
                    rom_addr <= {tile_id, suby_e, ~tile_fx};  // 2nd half (flipped: the LEFT 8 px)
                    rom_cs   <= 1;
                    rom_good <= 0;
                    draw_cnt <= 0;
                end
            end
        end
    end
end

endmodule
