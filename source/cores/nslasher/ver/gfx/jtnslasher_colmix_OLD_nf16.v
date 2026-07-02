/*  RECONSTRUCTED nf16-style colour mixer for bench purposes ONLY.
    This is a faithful reconstruction (per the bug-report + tb_colmix_bufferfade.v /
    tb_colmix_fade_stall.v conventions already in this tree) of the FLAWED "live-sweep"
    design that shipped to hardware as nf16 and did not fix the green dialog / banded
    bio / light shadow bugs, and introduced a static drop-shadow regression.

    Design (the bug): CPU palette writes land in u_live (2048x24), which stays WRITABLE
    for the entire duration of the VBLANK sweep. On a fade trigger (paldma OR fade_trig
    from ace[0x20-0x26]) the FSM walks idx=0..2047 and, for each entry:
        u_pal[2048+idx] <= u_live[idx]      (buffered snapshot, WRONG: live can still move)
        u_pal[idx]      <= fade(u_live[idx])
    Because u_live can be rewritten by the CPU mid-sweep, a scene-transition batch write
    that lands after idx has already swept past some entries but before others produces a
    TORN MIX in u_pal: some entries reflect the pre-batch image, some reflect the new one.

    This file exists ONLY to reproduce and characterize that bug in sim (test 1 of the
    dual-mirror fix proof). It is NOT used by the production colmix and is NOT wired into
    jtnslasher_video.v. Uses jtframe_dual_ram (same as production) so tb_colmix_bufferfade.v /
    tb_colmix_fade_stall.v hierarchical refs (u_dut.u_pal.u_ram.mem / u_dut.u_live.u_ram.mem)
    resolve identically to how they resolved against the real built nf16.
*/
module jtnslasher_colmix_OLD_nf16(
    input             clk,
    input             pxl_cen,
    input             LVBL,

    input             pal_we,
    input      [10:0] pal_waddr,
    input      [23:0] pal_din,

    input      [ 7:0] pf1_pxl,
    input      [ 7:0] pf2_pxl,
    input      [ 7:0] pf3_pxl,
    input      [ 7:0] pf4_pxl,
    input      [15:0] obj0_pxl,
    input      [15:0] obj1_pxl,

    input             en1, en2, en3, en4,
    input      [ 2:0] pri,
    input      [47:0] ace_alpha,

    input      [47:0] ace_fade,
    input             fade_mult,
    input             fade_trig,
    input             paldma,          // palette-DMA ONLY -> snapshots live->buffered

    input      [63:0] ace_tile,

    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue
);

function [7:0] get_alpha(input [7:0] v);
    reg [8:0] sub;
    begin
        sub = 9'd255 - {v[5:0], 3'b000};
        get_alpha = (v > 8'h20) ? 8'h80 : (sub[8] ? 8'd0 : sub[7:0]);
    end
endfunction

wire alpha_mist_en = (ace_tile[7:0]!=8'd0) & (pri[1:0]!=2'd0);

wire pf1on = en1 & (pf1_pxl[3:0]!=0);
wire pf2on = en2 & (pf2_pxl[3:0]!=0);
wire pf3on = en3 & (pf3_pxl[3:0]!=0);
wire pf4on = en4 & (pf4_pxl[3:0]!=0);
wire [10:0] pen1 = {3'h0, pf1_pxl};
wire [10:0] pen2 = {3'h1, pf2_pxl};
wire [10:0] pen3 = {3'h2, pf3_pxl};
wire [10:0] pen4 = {3'h3, pf4_pxl};

wire        midon    = pri[0] ? pf2on : pf3on;
wire [10:0] midpen   = pri[0] ? pen2  : pen3;
wire        fronton  = pri[0] ? pf3on : pf2on;
wire [10:0] frontpen = pri[0] ? pen3  : pen2;

reg  [10:0] bgpen;
reg  [ 2:0] tpri;
always @* begin
    bgpen = 11'h300; tpri = 3'd0;
    if( pf4on   ) begin bgpen = pen4;     tpri[0] = 1'b1; end
    if( midon   ) begin bgpen = midpen;   tpri[1] = 1'b1; end
    if( fronton ) begin
        if( ~alpha_mist_en ) bgpen = frontpen;
        tpri[2] = 1'b1;
    end
end

wire        o0on  = obj0_pxl[7:0]!=8'd0;
wire [1:0]  p0    = obj0_pxl[14:13];
wire [10:0] o0pen = {2'b10, obj0_pxl[11:8], obj0_pxl[4:0]};
wire o0draw = o0on & ( (p0==2'd0) | (p0==2'd1) | ((p0==2'd2)&(alpha_mist_en | (tpri<3'd4))) | ((p0==2'd3)&(tpri<3'd2)) );
wire [10:0] underpen = o0draw ? o0pen : bgpen;

wire        o1on  = obj1_pxl[7:0]!=8'd0;
wire [1:0]  p1    = obj1_pxl[14:13];
wire        o1a   = obj1_pxl[15];
wire [10:0] o1pen = {3'h6, obj1_pxl[11:8], obj1_pxl[3:0]};
wire        over0 = ~o0on | (p0==2'd3);
wire o1op = o1on & ~o1a & ( ((p1==2'd0)&(~o0on|(p0!=2'd0))) | (p1==2'd1) | (p1==2'd2) | (p1==2'd3) );
wire o1ad = o1on &  o1a & ( ((p1==2'd0)&over0) | ((p1==2'd1)&over0) | (p1==2'd2) | (p1==2'd3) );
wire o1_draw = o1op | o1ad;

wire [3:0] o1col = obj1_pxl[11:8];
wire [2:0] aidx  = o1col[3] ? {2'b10, o1col[1]} : {1'b0, o1col[2:1]};
wire [7:0] ace_b = (aidx==3'd0)?ace_alpha[ 7: 0] :
                   (aidx==3'd1)?ace_alpha[15: 8] :
                   (aidx==3'd2)?ace_alpha[23:16] :
                   (aidx==3'd3)?ace_alpha[31:24] :
                   (aidx==3'd4)?ace_alpha[39:32] : ace_alpha[47:40];
wire [7:0] a_lut = get_alpha(ace_b);
wire       agate = (~obj1_pxl[15]) | (~obj1_pxl[12]);
wire [7:0] alpha_eff = agate ? a_lut : 8'hFF;

wire o1_opaque = o1_draw & (alpha_eff==8'hFF);
wire o1_blend  = o1_draw & (alpha_eff!=8'hFF) & (alpha_eff!=8'd0);

wire [10:0] portA    = pf1on ? pen1 : (o1_opaque ? o1pen : underpen);
wire [10:0] portB    = o1pen;
wire        do_blend = o1_blend & ~pf1on;

wire portA_o1 = ~pf1on & o1_opaque;
wire portA_o0 = ~pf1on & ~o1_opaque & o0draw;
wire selA = portA_o1 ? (~pri[2] & o0draw) : (portA_o0 ? ~pri[2] : 1'b0);
wire selB = ~pri[2] & o0draw;

wire [7:0] frontpf  = pri[0] ? pf3_pxl : pf2_pxl;
wire [2:0] tile_off = frontpf[7:5];
wire [10:0] mistpen = pri[0] ? {3'h2, frontpf}
                             : {3'h3, frontpf};
wire [7:0] tile_b   = (tile_off==3'd0)?ace_tile[ 7: 0] : (tile_off==3'd1)?ace_tile[15: 8] :
                      (tile_off==3'd2)?ace_tile[23:16] : (tile_off==3'd3)?ace_tile[31:24] :
                      (tile_off==3'd4)?ace_tile[39:32] : (tile_off==3'd5)?ace_tile[47:40] :
                      (tile_off==3'd6)?ace_tile[55:48] : ace_tile[63:56];
wire [7:0] mist_alpha = get_alpha(tile_b);
wire mist_g0   = ~o0on | (p0==2'd2) | (p0==2'd3);
wire mist_g1   = ~o1on | (p1==2'd2) | (p1==2'd3) | o1a;
wire mist_draw = alpha_mist_en & fronton & mist_g0 & mist_g1;
wire selC      = ~pri[2] & o0draw;

// ============== u_live (2048x24, all CPU writes) + u_pal (4096: upper=buffered, lower=faded)
// ============== VBLANK FSM sweeps u_live[idx] (STILL WRITABLE -> the bug) on a fade trigger.
wire [23:0] pal_q;
wire [23:0] live_q;

wire [7:0] fdpt_r = ace_fade[ 7: 0], fdpt_g = ace_fade[15: 8], fdpt_b = ace_fade[23:16];
wire [7:0] fdps_r = ace_fade[31:24], fdps_g = ace_fade[39:32], fdps_b = ace_fade[47:40];

localparam FR=3'd0, FC=3'd1, FM1=3'd2, FM2=3'd3, FW=3'd4, FW2=3'd5;
reg  [ 2:0] fstate=FR;
reg  [10:0] fsm_idx=0;
reg         fsm_run=0, fade_dirty=0;
reg  [23:0] raw_c, faded_r;
wire        fsm_active = fsm_run & ~LVBL;

wire [7:0] c_r = raw_c[ 7: 0], c_g = raw_c[15: 8], c_b = raw_c[23:16];
wire       ge_r = fdpt_r>=c_r, ge_g = fdpt_g>=c_g, ge_b = fdpt_b>=c_b;
wire [7:0] mg_r = ge_r?(fdpt_r-c_r):(c_r-fdpt_r);
wire [7:0] mg_g = ge_g?(fdpt_g-c_g):(c_g-fdpt_g);
wire [7:0] mg_b = ge_b?(fdpt_b-c_b):(c_b-fdpt_b);
reg  [15:0] pr_r, pr_g, pr_b;
reg  [ 7:0] cc_r, cc_g, cc_b, sp_r, sp_g, sp_b;
reg         sg_r, sg_g, sg_b;
wire [31:0] qm_r = pr_r*32'h8081, qm_g = pr_g*32'h8081, qm_b = pr_b*32'h8081;
wire [7:0]  q_r = qm_r[30:23], q_g = qm_g[30:23], q_b = qm_b[30:23];
wire [8:0]  ad_r = {1'b0,cc_r}+{1'b0,sp_r}, ad_g = {1'b0,cc_g}+{1'b0,sp_g}, ad_b = {1'b0,cc_b}+{1'b0,sp_b};
wire [7:0]  fr_v = fade_mult ? (sg_r?(cc_r+q_r):(cc_r-q_r)) : (ad_r[8]?8'hFF:ad_r[7:0]);
wire [7:0]  fg_v = fade_mult ? (sg_g?(cc_g+q_g):(cc_g-q_g)) : (ad_g[8]?8'hFF:ad_g[7:0]);
wire [7:0]  fb_v = fade_mult ? (sg_b?(cc_b+q_b):(cc_b-q_b)) : (ad_b[8]?8'hFF:ad_b[7:0]);

// port0 of u_live: CPU writes only (always on, never gated -> the bug: writable through the sweep)
// port1 of u_live: FSM read at FC, address = fsm_idx
reg  [10:0] live_raddr;
always @* live_raddr = fsm_idx;

// port0 of u_pal: FSM write, ping-ponging between the buffered-upper write (FW) and the
// faded-lower write (FW2) so each is a distinct RAM write cycle (mirrors the real 2-write-per-entry
// nature of the bug without needing a dual-write-port RAM).
reg  [11:0] pal_waddr_fsm;
reg  [23:0] pal_wdata_fsm;
reg         pal_we_fsm;
always @* begin
    pal_waddr_fsm = 12'd0; pal_wdata_fsm = 24'd0; pal_we_fsm = 1'b0;
    case(fstate)
        FW:  begin pal_waddr_fsm = {1'b1, fsm_idx}; pal_wdata_fsm = raw_c;   pal_we_fsm = fsm_active; end
        FW2: begin pal_waddr_fsm = {1'b0, fsm_idx}; pal_wdata_fsm = faded_r; pal_we_fsm = fsm_active; end
        default: ;
    endcase
end

always @(posedge clk) begin
    if( paldma | fade_trig ) fade_dirty <= 1'b1;
    if( ~fsm_run ) begin
        if( ~LVBL & fade_dirty ) begin fsm_run<=1'b1; fsm_idx<=11'd0; fstate<=FR; fade_dirty<=1'b0; end
    end else if( ~LVBL ) begin
        case( fstate )
            FR:  fstate <= FC;
            FC:  begin raw_c <= live_q; fstate <= FM1; end       // <-- reads LIVE (still writable): THE BUG
            FM1: begin
                     pr_r<=mg_r*fdps_r; pr_g<=mg_g*fdps_g; pr_b<=mg_b*fdps_b;
                     cc_r<=c_r; cc_g<=c_g; cc_b<=c_b; sp_r<=fdps_r; sp_g<=fdps_g; sp_b<=fdps_b;
                     sg_r<=ge_r; sg_g<=ge_g; sg_b<=ge_b; fstate<=FM2;
                 end
            FM2: begin faded_r <= {fb_v, fg_v, fr_v}; fstate<=FW; end
            FW:  fstate <= FW2;                                   // write buffered[idx] = live snapshot
            FW2: begin                                            // write faded[idx]
                     if( fsm_idx==11'd2047 ) fsm_run <= 1'b0;
                     else begin fsm_idx <= fsm_idx + 11'd1; fstate <= FR; end
                 end
        endcase
    end
end

// ---- port arbitration: u_pal port0 = FSM write only (dedicated, no CPU contention modelled here
//      to isolate the torn-live-read bug specifically) ; port0 ALSO accepts CPU raw writes when the
//      CPU wants to poke u_pal directly for setup (kept for tb compatibility, unused by fsm path).
wire [11:0] p0_addr = pal_we_fsm ? pal_waddr_fsm : 12'd0;
wire [23:0] p0_data = pal_wdata_fsm;
wire        p0_we   = pal_we_fsm;

reg         pcen_d=0, pcen_dd=0, pcen_ddd=0, do_blend_r=0, mist_draw_r=0;
reg  [ 7:0] alpha_r=0, mist_alpha_r=0;
reg  [23:0] rgbA_r, scene_r, out_rgb;
wire [11:0] rd_addr  = pcen_ddd ? {selC, mistpen}
                     : pcen_dd  ? {selB, portB}
                     :            {selA, portA};
wire [11:0] p1_addr  = rd_addr;

function [7:0] blend8(input [7:0] d, input [7:0] s, input [7:0] a);
    reg [16:0] t;
    begin
        t = s*a + d*(9'd256 - {1'b0,a});
        blend8 = t[15:8];
    end
endfunction

always @(posedge clk) begin
    pcen_d   <= pxl_cen;
    pcen_dd  <= pcen_d;
    pcen_ddd <= pcen_dd;
    if( pcen_d   ) begin do_blend_r <= do_blend; alpha_r <= alpha_eff;
                         mist_draw_r <= mist_draw; mist_alpha_r <= mist_alpha; end
    if( pcen_dd  ) rgbA_r  <= pal_q;
    if( pcen_ddd ) scene_r <= do_blend_r ?
          { blend8(rgbA_r[23:16], pal_q[23:16], alpha_r),
            blend8(rgbA_r[15: 8], pal_q[15: 8], alpha_r),
            blend8(rgbA_r[ 7: 0], pal_q[ 7: 0], alpha_r) }
          : rgbA_r;
    if( pxl_cen  ) out_rgb <= mist_draw_r ?
          { blend8(scene_r[23:16], pal_q[23:16], mist_alpha_r),
            blend8(scene_r[15: 8], pal_q[15: 8], mist_alpha_r),
            blend8(scene_r[ 7: 0], pal_q[ 7: 0], mist_alpha_r) }
          : scene_r;
end

jtframe_dual_ram #(.DW(24),.AW(12)) u_pal(
    .clk0(clk), .data0(p0_data), .addr0(p0_addr), .we0(p0_we), .q0(),
    .clk1(clk), .data1(24'd0),   .addr1(p1_addr), .we1(1'b0),  .q1(pal_q) );

// u_live: port0 = CPU write (always live/writable, no gating -> the bug), port1 = FSM read
jtframe_dual_ram #(.DW(24),.AW(11)) u_live(
    .clk0(clk), .data0(pal_din), .addr0(pal_waddr), .we0(pal_we), .q0(),
    .clk1(clk), .data1(24'd0),   .addr1(live_raddr), .we1(1'b0),  .q1(live_q) );

assign red   = out_rgb[ 7: 0];
assign green = out_rgb[15: 8];
assign blue  = out_rgb[23:16];

endmodule
