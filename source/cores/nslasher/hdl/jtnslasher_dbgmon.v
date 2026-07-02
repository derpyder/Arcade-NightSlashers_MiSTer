/*  Night Slashers — ON-CAB DEBUGGER overlay (DIAG, remove for real build).
    BIG / READABLE layout. Top-left of screen, top to bottom:

      1. DECODE GRID (small, 2 rows x 8 cells): green = ARM decoding correct code (proves the machine is
         alive / the byteswap fix holds). Incidental confirmation.

      2. BIG VERDICT BLOCK (48px tall x 256px wide SOLID color — glance-able, orientation-invariant):
           GREEN  = dbg_pcnow != 0
           YELLOW = dbg_pcnow == 0 && dbg_snd[31:8] != 0
           RED    = both zero
         The MEANING of green/yellow/red is set per build by what jtnslasher_game feeds dbg_pcnow / dbg_snd.

      3. 5 BIG VALUE ROWS (24px tall each, 24 bars x 8px, MSB at LEFT, white=1/near-black=0, blue separators
         every 4 bars = 6 hex digits): row0=dbg_pcmax, row1=dbg_pcnow, row2=dbg_poll_a, row3=dbg_poll_d,
         row4=dbg_snd[31:8].

    *** Rows/verdict are REPURPOSED per build by jtnslasher_game (see its u_dbgmon NOTE for the CURRENT
        signal mapping). This file is just the renderer. ***
*/
module jtnslasher_dbgmon(
    input             clk,
    input      [23:0] dbg_pc,
    input             main_cs,
    input             main_ok,
    input      [31:0] main_data,
    input      [31:0] rom_dec,
    input      [19:0] dbg_pcmax,
    input      [19:0] dbg_pcnow,
    input      [23:0] dbg_poll_a,
    input      [31:0] dbg_poll_d,
    input      [31:0] dbg_snd,
    input      [15:0] dbg_virq_cnt,
    input      [15:0] dbg_irq_cnt,
    input      [ 8:0] hdump,
    input      [ 8:0] vdump,
    input             LHBL,
    input             LVBL,
    input      [ 7:0] vmem_r, vmem_g, vmem_b,
    output reg [ 7:0] red, green, blue
);

`include "dbg_golden.vh"

function [31:0] bsw32(input [31:0] v); bsw32 = {v[7:0],v[15:8],v[23:16],v[31:24]}; endfunction

wire [17:0] arm_word = dbg_pc[19:2];

// ---- decode-verdict capture (grid): green when the DECODED word matches golden ----
reg [31:0] raw_l [0:DBG_N-1];
reg        seen  [0:DBG_N-1];
reg [ 1:0] verd  [0:DBG_N-1];   // 0 idle, 1 OK, 2 SWAP, 3 OTHER
integer i;
initial for(i=0;i<DBG_N;i=i+1) begin raw_l[i]=0; seen[i]=0; verd[i]=2'd0; end

always @(posedge clk) begin
    if( main_cs & main_ok ) begin
        for(i=0;i<DBG_N;i=i+1)
            if( arm_word==dbg_aw[i] ) begin
                raw_l[i] <= main_data;
                seen[i]  <= 1'b1;
                verd[i]  <= (rom_dec  ==dbg_gdec[i])       ? 2'd1 :
                            (main_data==bsw32(dbg_graw[i])) ? 2'd2 : 2'd3;
            end
    end
end

localparam DGRY=8'h28, ON=8'hff, OFF=8'h08;   // OFF near-black so lit bars pop

// ---- PROBE #1 verdict signals (fed via the repurposed ports, see jtnslasher_game NOTE) ----
wire pf_draw = |dbg_pcnow;        // PF non-zero write count > 0  -> game is DRAWING real tiles
wire any_vid = |dbg_snd[31:8];    // last non-zero ANY-video addr != 0 -> some video content written

// ---- grid hit-test (2 rows x 8 cells, 16px) — small decode-verdict grid (proves ARM runs correct code) ----
reg [3:0] gcell; reg ingrid, ingrid0, ingrid1; reg [1:0] gv;
// ---- big self-classifying VERDICT block ----
reg inverd;
// ---- value rows: BIG/readable — 24px tall, 8px gap (pitch 32), 5 rows; 24 bars x 8px, MSB at left,
//      nibble separators every 4 bars group the 24 bars into 6 hex digits. ----
reg [23:0] rowval; reg in_val;
wire [4:0] bar  = hdump[7:3];
wire [4:0] bidx = 5'd23 - bar;
wire       vbit = rowval[bidx];
wire [8:0] vo   = vdump - 9'd80;            // offset into the value-row band
wire [2:0] vrow = vo[7:5];                  // value row 0..4 (pitch 32)
wire       vrow_on = (vdump>=9'd80) && (vdump<9'd240) && (vo[4:0] < 5'd24) && (hdump<9'd192);

always @(*) begin
    ingrid0 = (vdump>=9'd4)  && (vdump<9'd12) && (hdump<9'd128);
    ingrid1 = (vdump>=9'd14) && (vdump<9'd22) && (hdump<9'd128);
    ingrid  = ingrid0 | ingrid1;
    gcell   = {1'b0,hdump[6:4]} + (ingrid1 ? 4'd8 : 4'd0);
    gv      = verd[gcell];

    // big verdict block (vdump 26..73, 48px tall x 256px wide) — see color mux below
    inverd  = (vdump>=9'd26) && (vdump<9'd74) && (hdump<9'd256);

    // 5 BIG value rows (PROBE #1). See jtnslasher_game u_dbgmon NOTE for the signal mapping.
    in_val=1'b0; rowval=24'd0;
    if( vrow_on ) begin
        in_val=1'b1;
        case(vrow)                            // meanings are per-build — see jtnslasher_game u_dbgmon NOTE
            3'd0: rowval={4'd0,dbg_pcmax};    // row0 = dbg_pcmax
            3'd1: rowval={4'd0,dbg_pcnow};    // row1 = dbg_pcnow  (also drives verdict GREEN)
            3'd2: rowval=dbg_poll_a;          // row2 = dbg_poll_a
            3'd3: rowval=dbg_poll_d[23:0];    // row3 = dbg_poll_d
            default: rowval=dbg_snd[31:8];    // row4 = dbg_snd[31:8]  (also drives verdict YELLOW)
        endcase
    end
end

always @(*) begin
    red=vmem_r; green=vmem_g; blue=vmem_b;
    if( LHBL && LVBL ) begin
        if( ingrid ) begin
            case(gv)
                2'd0: begin red=DGRY;  green=DGRY;  blue=DGRY;  end
                2'd1: begin red=8'h00; green=ON;    blue=8'h00; end // OK green
                2'd2: begin red=ON;    green=8'h00; blue=8'h00; end // SWAP red
                2'd3: begin red=ON;    green=ON;    blue=8'h00; end // OTHER yellow
            endcase
        end else if( inverd ) begin
            // BIG self-classifying verdict: GREEN=drawing PF tiles, YELLOW=parked but some video, RED=parked idle
            if( pf_draw )      begin red=8'h00; green=ON;    blue=8'h00; end
            else if( any_vid ) begin red=ON;    green=ON;    blue=8'h00; end
            else               begin red=ON;    green=8'h00; blue=8'h00; end
        end else if( in_val ) begin
            red   = vbit?ON:OFF; green=vbit?ON:OFF; blue=vbit?ON:OFF;
            if( hdump[4:0]==5'd0 && bar!=5'd0 ) begin red=8'h00; green=8'h00; blue=ON; end // nibble separators (6 hex digits)
        end
    end
end

endmodule
