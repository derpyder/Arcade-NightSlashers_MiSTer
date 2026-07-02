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
module jtnslasher_obj #(parameter BPP=5) (
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

reg         parse_busy, HSl, cen2;
reg         fx, fy, flash, colhi;
reg  [ 1:0] r_msz;
reg  [ 6:0] veff;            // 0..127 within sprite
reg  [15:0] code;
reg  [ 7:0] line_cnt;

// ---- parse -> draw 1-deep pipeline slot (COMB FIX stage-B, see draw FSM banner) ----
// The parser runs ONE sprite ahead of the draw FSM: at word2 it deposits the fully-resolved draw
// request here (tile/row/flip resolved combinationally from regs latched at word0/word1, colour/x
// taken straight off tbl_dout) and continues scanning. The draw FSM pops it (pend_pop) when it can
// accept it -- and can PREFETCH its first ROM word while the previous sprite's pixels still drain.
reg         pend_v;          // slot full (set by parser, cleared on pend_pop)
reg  [15:0] pend_tile;
reg  [ 3:0] pend_rowf;
reg         pend_fxd;
reg  [ 7:0] pend_col;
reg  [ 8:0] pend_x;
wire        pend_pop;        // driven by the draw FSM

// ---- parse FSM ----
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        tbl_addr<=0; parse_busy<=0; HSl<=0; cen2<=0; pend_v<=0;
    end else begin
        HSl  <= HS;
        cen2 <= ~cen2;                    // half-rate: give the table RAM 1 clk for tbl_dout
        if( pend_pop ) pend_v <= 1'b0;    // draw FSM consumed the slot
        if( HSl && !HS ) begin            // new line -> restart scan
            tbl_addr   <= 0;
            parse_busy <= 1;
            cen2       <= 0;
        end
        if( parse_busy && !pend_v && cen2 ) begin        // advance while the pipeline slot is free
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
                2'd2: begin               // word2: x / colour -> deposit the draw request
                    if( (!flash) | frame ) begin
                        pend_v    <= 1'b1;                // (cannot collide with pend_pop: parser
                        pend_tile <= tile;                //  only reaches here while pend_v==0)
                        pend_rowf <= rowf;
                        pend_fxd  <= fxd;
                        pend_col  <= { colhi, tbl_dout[15:9] };
                        pend_x    <= tbl_dout[8:0];  // 9-bit: x-512 (off-screen) == x mod 512; wrap+<320 filter clip it
                    end
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
// COMB FIX stage-B (PIPELINED FETCH, sim-gated tb_obj_f2700.v byte-exact + tb_obj_f2700_lat.v):
// the serial FSM waited fetch->drain->fetch->drain, leaving the ROM path idle during every 8-px
// drain, so a heavy line's total = Nspr*2*(LAT+8) and the ~3072-clk budget overran at LAT>~7
// (real obj0 2-burst LAT ~14-16 -> 41-50/240 lines over = the in-game comb). This version issues
// the NEXT fetch while the current 8 pixels drain -- the 2nd half during drain-1, and the PENDING
// sprite's 1st half during drain-2 (the parser runs one sprite ahead via pend_*) -- hiding up to
// 8 clk of every fetch: steady-state per half = max(LAT,8) instead of LAT+8. The SDRAM protocol
// is UNCHANGED: same addresses, same data, same order, same >=1-cycle cs drop between fetches --
// only the issue TIME moves earlier. The working set (d_tile/d_rowf/d_fxd/d_col) is latched at
// pop so the parser running ahead can never disturb an in-flight draw.
reg  [8*BPP-1:0] draw_data;
reg  [ 3:0] draw_cnt;
reg         rom_good;
reg  [ 8:0] buf_waddr;
reg         buf_we;

localparam [2:0] D_IDLE=3'd0, D_F1=3'd1, D_D1=3'd2, D_F2=3'd3, D_D2=3'd4;
reg  [ 2:0] dstate;
reg         pf_on;           // cross-sprite prefetch issued during D_D2 (pend's h1 already in flight)
reg         pend_pop_r;
assign      pend_pop = pend_pop_r;

// latched working set for the sprite being drawn (stable while the parser runs ahead)
reg  [15:0] d_tile;
reg  [ 3:0] d_rowf;
reg         d_fxd;
reg  [ 7:0] d_col;

wire [BPP-1:0] draw_pxl;
genvar gi;
generate for( gi=0; gi<BPP; gi=gi+1 ) begin: g_pxl
    assign draw_pxl[gi] = d_fxd ? draw_data[8*gi] : draw_data[8*gi+7];
end endgenerate
wire [15:0] buf_wdata = { d_col, {(8-BPP){1'b0}}, draw_pxl };

wire draw_busy = (dstate != D_IDLE);     // kept for the obj_buffer interlock below

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        dstate<=D_IDLE; buf_we<=0; buf_waddr<=0; rom_cs<=0; draw_cnt<=0; rom_good<=0;
        line_cnt<=0; pf_on<=0; pend_pop_r<=0;
    end else begin
        rom_good   <= rom_cs & rom_ok;
        pend_pop_r <= 0;
        if( !parse_busy && dstate==D_IDLE && !pend_v ) line_cnt <= 0;

        // shared 8-px drain (runs under D_D1/D_D2); placed BEFORE the case so a same-cycle
        // pop's buf_waddr<=pend_x (below) takes precedence over the ++ here
        if( buf_we ) begin
            draw_data <= d_fxd ? draw_data >> 1 : draw_data << 1;
            buf_waddr <= buf_waddr + 9'd1;
            draw_cnt  <= draw_cnt - 1'd1;
        end

        case( dstate )
            D_IDLE: if( pend_v && !pend_pop_r ) begin      // accept the parser's request
                d_tile<=pend_tile; d_rowf<=pend_rowf; d_fxd<=pend_fxd; d_col<=pend_col;
                buf_waddr <= pend_x;
                pend_pop_r<= 1;
                rom_addr  <= { pend_tile, pend_rowf, pend_fxd };   // h1 ({code,row,half})
                rom_cs    <= 1;                            // (if a D_D2 prefetch already had cs up
                rom_good  <= 0;                            //  with this same addr, it just carries on)
                dstate    <= D_F1;
            end
            D_F1: if( rom_cs && rom_good && rom_ok ) begin // h1 data fresh (2-cycle-ok guard as before)
                draw_data <= rom_data;
                rom_cs    <= 0;  rom_good <= 0;
                buf_we    <= 1;  draw_cnt <= 4'd7;
                dstate    <= D_D1;
            end
            D_D1: begin
                if( !rom_cs )                              // 1st drain cycle: issue h2 (cs saw >=1 low cycle)
                    begin rom_addr <= { d_tile, d_rowf, ~d_fxd }; rom_cs <= 1; rom_good <= 0; end
                if( buf_we && draw_cnt==4'd0 ) begin buf_we <= 0; dstate <= D_F2; end
            end
            D_F2: if( rom_cs && rom_good && rom_ok ) begin // h2 data fresh (often already waiting)
                draw_data <= rom_data;
                rom_cs    <= 0;  rom_good <= 0;
                buf_we    <= 1;  draw_cnt <= 4'd7;
                dstate    <= D_D2;
            end
            D_D2: begin
                // cross-sprite prefetch: launch the pending sprite's h1 while draining (not on the
                // final drain cycle, so the pop below always sees pf_on already settled)
                if( !rom_cs && pend_v && !pf_on && draw_cnt!=4'd0 ) begin
                    rom_addr <= { pend_tile, pend_rowf, pend_fxd };
                    rom_cs   <= 1;  rom_good <= 0;
                    pf_on    <= 1;
                end
                if( buf_we && draw_cnt==4'd0 ) begin
                    buf_we   <= 0;
                    line_cnt <= line_cnt + 1'd1;
                    if( pf_on ) begin                      // prefetched: pop + go straight to h1 wait
                        d_tile<=pend_tile; d_rowf<=pend_rowf; d_fxd<=pend_fxd; d_col<=pend_col;
                        buf_waddr <= pend_x;
                        pend_pop_r<= 1;
                        pf_on     <= 0;
                        dstate    <= D_F1;
                    end else
                        dstate <= D_IDLE;                  // (a waiting pend_v pops there next cycle)
                end
            end
            default: dstate <= D_IDLE;
        endcase
    end
end

// COMB FIX (sim-proven tb_obj_comb.v): the stock jtframe_obj_buffer swaps its ping-pong halves
// UNCONDITIONALLY on LHBL-fall; the slow 5bpp obj0 over-runs the scanline budget under heavy load,
// so a half still being written is displayed -> alternating-parity sprite comb. Core-local
// jtnslasher_obj_buffer defers the swap until the draw FSM is idle (obj_draw_busy=0). At realistic
// obj0 latency the comb -> 0 with sprites byte-identical to golden. Never a vtimer/clock change.
wire obj_draw_busy = parse_busy | draw_busy | pend_v | buf_we;   // parse scanning | pixel-write FSM | queued request | write in flight
jtnslasher_obj_buffer #(.DW(16), .AW(9), .ALPHAW(8), .ALPHA(16'h0)) u_buffer(
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
