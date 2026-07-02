/*  Night Slashers — VIDEO-WRITE probe (DIAG, remove for real build).

    PROBE #1 (parked-vs-drawing): captures the LAST NON-ZERO write to the PF tilemap
      (PF1 0x182000-0x183fff, PF2 0x184000-0x185fff, PF3 0x1c2000-0x1c3fff, PF4 0x1c4000-0x1c5fff):
        pfnz_cnt==0 => never draws real tiles (parked) ; >0 => drawing.  plus anynz_a = last non-zero
      ANY-video write addr (region discriminator).  RESULT (2026-06-07): GREEN/drawing, pfnz_a=0x182F84
      (PF1), tile 0x19D — confirmed drawing real tiles, yet screen = colorful noise.

    PROBE #2 (why correct tiles render as noise — per-region INIT breakdown):
      pal_cnt  = # writes to PALETTE   (0x168000-0x169fff)  -> is the colour table initialised?
      pfbg_cnt = # writes to PF2/PF3/PF4 tile RAM           -> are the background layers ever touched?
      ctl_cnt  = # writes to layer-control regs (0x1a0000-0x1a001f / 0x1e0000-0x1e001f)
      ctl12_5  = ctl12[5] (0x1a0014): en1=bit7, en2=bit15 (PF1/PF2 enable + cfg)
      ctl34_5  = ctl34[5] (0x1e0014): en3=bit7, en4=bit15 (PF3/PF4 enable + cfg)
      Inference: palette written + layers enabled+written => gfx-FETCH problem (next: gfx-byte probe).
      Palette/ctl/bg NOT written but a layer enabled => uninitialised-enabled layer rendering garbage.

    cpu_we is the registered one-clk video-write pulse from jtnslasher_main (is_video only), cpu_addr/
    cpu_dout held alongside it. Sim: ver/sdram_main/tb_vidnz.v (run_vidnz.sh) -> "=== VIDNZ SIM PASS ===".
    Revert for the real build: drop the u_vidprobe instance + dbg_* taps in jtnslasher_main + the
    files.qip line.
*/
module jtnslasher_vidprobe(
    input             rst,
    input             clk,
    input      [23:0] cpu_addr,   // video-space write address (held with cpu_we)
    input      [31:0] cpu_dout,   // write data
    input      [ 3:0] cpu_we,     // per-byte write strobe (registered 1-clk pulse)
    // --- probe #1 ---
    output reg [15:0] pfnz_cnt,   // # of non-zero PF-tilemap writes (0 = parked, >0 = drawing)
    output reg [23:0] pfnz_a,     // last non-zero PF write address (which PF + offset)
    output reg [15:0] pfnz_d,     // last non-zero PF write data (the tile code)
    output reg [23:0] anynz_a,    // last non-zero ANY-video write address (region)
    // --- probe #2 (per-region init) ---
    output reg [15:0] pal_cnt,    // # of palette writes (0x168xxx)
    output reg [15:0] pfbg_cnt,   // # of PF2/PF3/PF4 tile writes (background layers)
    output reg [15:0] ctl_cnt,    // # of layer-control reg writes (0x1a/0x1e)
    output reg [15:0] ctl12_5,    // ctl12[5]: en1=bit7, en2=bit15
    output reg [15:0] ctl34_5     // ctl34[5]: en3=bit7, en4=bit15
);

wire        wr   = |cpu_we;
// byte-lane mask -> non-zero content across the enabled lanes only
wire [31:0] msk  = {{8{cpu_we[3]}},{8{cpu_we[2]}},{8{cpu_we[1]}},{8{cpu_we[0]}}};
wire [31:0] data = cpu_dout & msk;
wire        nz   = |data;
// PF tilemap regions (deco32 nslasher map; matches jtnslasher_vmem pf*_w decode)
wire        is_pf = (cpu_addr>=24'h182000 && cpu_addr<24'h186000)    // PF1 + PF2
                 || (cpu_addr>=24'h1c2000 && cpu_addr<24'h1c6000);   // PF3 + PF4
wire [15:0] content = (|data[15:0]) ? cpu_dout[15:0] : cpu_dout[31:16];
// probe #2 region decode
wire        is_pal   = (cpu_addr>=24'h168000 && cpu_addr<24'h16a000);
wire        is_pfbg  = (cpu_addr>=24'h184000 && cpu_addr<24'h186000)    // PF2
                    || (cpu_addr>=24'h1c2000 && cpu_addr<24'h1c6000);   // PF3 + PF4
wire        is_ctl12 = (cpu_addr>=24'h1a0000 && cpu_addr<24'h1a0020);
wire        is_ctl34 = (cpu_addr>=24'h1e0000 && cpu_addr<24'h1e0020);

initial begin pfnz_cnt=0; pfnz_a=0; pfnz_d=0; anynz_a=0;
              pal_cnt=0; pfbg_cnt=0; ctl_cnt=0; ctl12_5=0; ctl34_5=0; end

always @(posedge clk) begin
    if( rst ) begin
        pfnz_cnt<=0; pfnz_a<=0; pfnz_d<=0; anynz_a<=0;
        pal_cnt<=0; pfbg_cnt<=0; ctl_cnt<=0; ctl12_5<=0; ctl34_5<=0;
    end else if( wr ) begin
        // probe #1: non-zero captures
        if( nz ) begin
            anynz_a <= cpu_addr;
            if( is_pf ) begin
                pfnz_cnt <= pfnz_cnt + 16'd1;
                pfnz_a   <= cpu_addr;
                pfnz_d   <= content;
            end
        end
        // probe #2: per-region init counts (any write, incl. clears -> "was the region touched")
        if( is_pal  ) pal_cnt  <= pal_cnt  + 16'd1;
        if( is_pfbg ) pfbg_cnt <= pfbg_cnt + 16'd1;
        if( is_ctl12 || is_ctl34 ) ctl_cnt <= ctl_cnt + 16'd1;
        if( is_ctl12 && cpu_addr[4:2]==3'd5 ) ctl12_5 <= cpu_dout[15:0];   // 0x1a0014 = en1/en2 reg
        if( is_ctl34 && cpu_addr[4:2]==3'd5 ) ctl34_5 <= cpu_dout[15:0];   // 0x1e0014 = en3/en4 reg
    end
end

endmodule
