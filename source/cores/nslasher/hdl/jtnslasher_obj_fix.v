/*  Night Slashers — sprite engine (one layer). deco32 sprite format (doc/mame_deco32.c
    nslasher_draw_sprites + deco32_draw_sprite). One engine per layer:
      gfx3 = 5bpp (BPP=5, pal base 1024) ; gfx4 = 4bpp (BPP=4, pal base 1536).

    Per-line scan of the buffered sprite table (256 sprites x 4 words):
      word0 : y[8:0] (9-bit signed: >=256 -> -512), flash[12], fx[13], fy[14],
              msz[10:9] (height = 16<<msz = 1/2/4/8 tiles), colour-hi[15]
      word1 : code[15:0]
      word2 : x[8:0] (>=320 -> -512), colour[15:9] (7-bit)        word3 : unused
    16x16 tiles (1 wide, msz+1 tall). For render line `vrender`: veff=vrender-y, the active tile =
      base|(fy? m : m^multi)  (base=code&~multi, multi=(1<<msz)-1, m=veff>>4), row = veff[3:0]^{4{fy}}.
    Pixel = BPP-bpp pen (0 transparent). Output mix = {colour[7:0], pen} -> jtframe_obj_buffer (DW16,
    transparent on low-8==0); the colmix/Ace mixer reads pri=mix[14:13], col=mix[12:8], alpha=mix[15].

    gfx fetch (ver/gfx/reshuffle_spr.py): word(code,row,half) at rom_addr {code,row[3:0],half},
    rom_data = BPP bytes (plane p = byte p, bit7=leftmost). 1 tile = 2 half-fetches (8 px each).
*/
module jtnslasher_obj_fix #(parameter BPP=5) (
    input              rst,
    input              clk,
    input              pxl_cen,

    input              HS,
    input              LVBL,
    input              LHBL,

    input      [ 8:0]  vrender,
    input      [ 8:0]  hdump,

    // buffered sprite table (256 x 4 words)
    output reg [ 9:0]  tbl_addr,
    input      [15:0]  tbl_dout,

    // gfx ROM (reshuffled planar, BPP bytes per 8-px half-row)
    output reg          rom_cs,
    output reg [20:0]   rom_addr,
    input  [8*BPP-1:0]  rom_data,
    input               rom_ok,

    output     [15:0]  pxl          // {colour[7:0], pen[7:0]}; low-8==0 transparent
);

// ---- frame toggle for flashing sprites ----
reg LVl, frame;
always @(posedge clk, posedge rst) begin
    if(rst) begin LVl<=0; frame<=0; end
    else begin LVl<=LVBL; if(!LVBL && LVl) frame<=~frame; end
end

// ---- per-sprite geometry from word0 ----
wire [ 8:0] spry  = tbl_dout[8:0];
wire signed [9:0] sy = spry[8] ? {1'b1,spry} : {1'b0,spry};   // 9-bit signed (>=256 -> negative)
wire [ 1:0] msz   = tbl_dout[10:9];
wire [ 8:0] hgt   = 9'd16 << msz;                              // 16/32/64/128
wire signed [10:0] veff_w = $signed({2'b0,vrender}) - sy;     // line within sprite
wire        inzone = (veff_w >= 0) && (veff_w < $signed({2'b0,hgt}));

reg         parse_busy, HSl, draw, draw_busy, cen2;
reg         fx, fy, flash, colhi;
reg  [ 1:0] r_msz;
reg  [ 6:0] veff;            // 0..127 within sprite
reg  [15:0] code;
reg  [ 7:0] colour;
reg  [ 8:0] xpos;
reg  [ 7:0] line_cnt;

// ---- parse FSM ----
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        tbl_addr<=0; parse_busy<=0; HSl<=0; draw<=0; cen2<=0;
    end else begin
        HSl  <= HS;
        draw <= 0;
        cen2 <= ~cen2;                    // half-rate: give the table RAM 1 clk for tbl_dout
        if( HSl && !HS ) begin            // new line -> restart scan
            tbl_addr   <= 0;
            parse_busy <= 1;
            cen2       <= 0;
        end
        if( parse_busy && !draw_busy && !draw && cen2 ) begin
            case( tbl_addr[1:0] )
                2'd0: begin               // word0: y / flip / size
                    fy    <= tbl_dout[14];
                    fx    <= tbl_dout[13];
                    flash <= tbl_dout[12];
                    colhi <= tbl_dout[15];
                    r_msz <= msz;
                    veff  <= veff_w[6:0];
                    if( inzone ) tbl_addr <= tbl_addr + 10'd1;       // parse this sprite
                    else begin
                        tbl_addr <= tbl_addr + 10'd4;                // skip to next
                        if( &tbl_addr[9:2] ) parse_busy <= 0;
                    end
                end
                2'd1: begin               // word1: code
                    code     <= tbl_dout;
                    tbl_addr <= tbl_addr + 10'd1;
                end
                2'd2: begin               // word2: x / colour -> draw
                    xpos     <= tbl_dout[8:0];   // 9-bit: x-512 (off-screen) == x mod 512; wrap+<320 filter clip it
                    colour   <= { colhi, tbl_dout[15:9] };
                    draw     <= (!flash) | frame;
                    tbl_addr <= tbl_addr + 10'd2;                    // skip word3
                    if( &tbl_addr[9:2] ) parse_busy <= 0;
                end
                default:;
            endcase
            if( line_cnt >= 8'd127 ) parse_busy <= 0;                // per-line sprite cap: MAME
            // (nslasher_draw_sprites, doc/mame_deco32.c:419) draws all 256 entries with NO low
            // per-line limit. The old cap=40 clipped the LATER-parsed (=frontmost, since parse
            // order is draw order/back-to-front) sprites on busy in-game lines (f2700: up to 70
            // sprites/line), so background showed through -> wrong-colour multicolor scramble on
            // large in-game scenes; char-select (<=8 sprites/line) never hit it, so it looked OK.
            // 127 covers the worst observed scene with margin (sim: 70 sprites/line = 2332 of 3072
            // clk/line) while bounding runaway. Sim-proven byte-exact: ver/gfx/tb_obj_f2700.v.
        end
    end
end

// ---- effective tile + row from veff (vertical multi) ----
// MAME: raw fx/fy (y&0x2000/0x4000) select the multi-tile order; the PIXEL flip passed to the
// draw is INVERTED (`if(fx)fx=0;else fx=1;`). So tile-select uses fy(raw), pixel flip uses ~fx/~fy.
wire        fxd    = ~fx;                                          // pixel column flip
wire        fyd    = ~fy;                                          // pixel row flip
wire [2:0] m       = veff[6:4];
wire [3:0] multi   = (4'd1 << r_msz) - 4'd1;
wire [3:0] msel    = fy ? {1'b0,m} : ({1'b0,m} ^ multi);          // tile within the stack (raw fy)
wire [15:0] tile   = (code & ~{12'd0,multi}) | {12'd0,msel};
wire [3:0]  rowf   = veff[3:0] ^ {4{fyd}};

// ---- draw FSM: 2 half-fetches (8 px each) -> line buffer ----
reg  [8*BPP-1:0] draw_data;
reg  [ 3:0] draw_cnt;
reg         half, rom_good;
reg  [ 8:0] buf_waddr;
reg         buf_we;

wire [BPP-1:0] draw_pxl;
genvar gi;
generate for( gi=0; gi<BPP; gi=gi+1 ) begin: g_pxl
    assign draw_pxl[gi] = fxd ? draw_data[8*gi] : draw_data[8*gi+7];
end endgenerate
wire [15:0] buf_wdata = { colour, {(8-BPP){1'b0}}, draw_pxl };

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        draw_busy<=0; buf_we<=0; buf_waddr<=0; rom_cs<=0; draw_cnt<=0; half<=0; rom_good<=0; line_cnt<=0;
    end else begin
        rom_good <= rom_cs & rom_ok;
        if( !parse_busy ) line_cnt <= 0;
        if( draw ) begin
            draw_busy <= 1;
            half      <= fxd;                              // flipped -> right half first
            rom_addr  <= { tile[15:0], rowf, fxd };        // {code,row,half}
            rom_cs    <= 1;
            rom_good  <= 0;
            draw_cnt  <= 0;
            buf_waddr <= xpos;
        end
        if( !buf_we && rom_cs && rom_good && rom_ok && draw_cnt==0 ) begin
            draw_data <= rom_data;
            rom_cs    <= 0;
            buf_we    <= 1;
            draw_cnt  <= 7;
        end
        if( buf_we ) begin
            draw_data <= fxd ? draw_data >> 1 : draw_data << 1;
            buf_waddr <= buf_waddr + 9'd1;
            draw_cnt  <= draw_cnt - 1'd1;
            if( draw_cnt==0 ) begin
                buf_we <= 0;
                if( half ^ fxd ) begin                     // both halves done
                    draw_busy <= 0;
                    rom_cs    <= 0;
                    line_cnt  <= line_cnt + 1'd1;
                end else begin                             // fetch the other half
                    half     <= ~half;
                    rom_addr <= { tile[15:0], rowf, ~half };
                    rom_cs   <= 1;
                    rom_good <= 0;
                    draw_cnt <= 0;
                end
            end
        end
    end
end

// draw not-idle = parse still scanning OR the pixel-write FSM busy OR a write in flight
wire obj_draw_busy = parse_busy | draw_busy | buf_we;

jtframe_obj_buffer_fix #(.DW(16), .AW(9), .ALPHAW(8), .ALPHA(16'h0)) u_buffer(
    .clk      ( clk          ),
    .LHBL     ( LHBL         ),
    .flip     ( 1'b0         ),
    .wr_data  ( buf_wdata    ),
    .wr_addr  ( buf_waddr    ),
    .we       ( buf_we       ),
    .draw_busy( obj_draw_busy),
    .rd_addr  ( hdump        ),
    .rd       ( pxl_cen      ),
    .rd_data  ( pxl          )
);

endmodule
