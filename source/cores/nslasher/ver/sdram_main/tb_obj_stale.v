`timescale 1ns/1ps
// =============================================================================
// tb_obj_stale — DECISIVE timing test for the obj0 fold + engine under IRREGULAR,
// CONTENDED obj0_ok (the Tempest "model the shared-bus contention" lesson).
//
// Replaces the real SDRAM+slot with a BEHAVIORAL slot that:
//   * returns a UNIQUE, address-derived 32-bit word for EVERY obj0_addr
//     (word = {~addr[15:0], addr[15:0]} so no value is ever X or 0), and
//   * asserts obj0_ok with a RANDOM, IRREGULAR latency (a busy-duty generator:
//     each new request waits rand(MINLAT..MAXLAT) cycles, then holds ok as a
//     LATCHED level exactly like jtframe OKLATCH=1, until cs drops).
//
// The REAL jtnslasher_obj engine drives the REAL jtnslasher_sdram obj0 fold FSM.
// On EVERY engine consume (the instant draw_data<=rom_data) we recompute the
// EXPECTED 40-bit word from the engine's CURRENT obj0_rom_addr and compare.
//   - a MISMATCH where the got-word equals a PREVIOUS tile's word  => STALE latch
//   - if every tile collapses to ONE repeated word                 => UNIFORM
//   - distinct-word count << distinct-addr count                   => collapse
//
// This isolates the engine<->fold timing handshake under the exact irregular-ok
// conditions the single-master sim never produced.
// =============================================================================
module tb_obj_stale;
    reg clk=0, rst=1;
    always #10.4 clk=~clk;

    integer SEED; reg [31:0] seedr;
    integer MINLAT, MAXLAT;
    initial begin
        if(!$value$plusargs("SEED=%d", SEED))   SEED=1;
        if(!$value$plusargs("MIN=%d", MINLAT))   MINLAT=2;
        if(!$value$plusargs("MAX=%d", MAXLAT))   MAXLAT=30;
        seedr=SEED;
    end

    reg pxl_cen=0; reg [1:0] cendiv=0;
    always @(posedge clk) begin cendiv<=cendiv+1; pxl_cen<=(cendiv==0); end
    reg        HS=0, LVBL=1, LHBL=1;
    reg  [8:0] vrender=0, hdump=0;

    // engine <-> fold
    wire        obj0_rom_cs;  wire [20:0] obj0_rom_addr;
    wire [39:0] obj0_rom_data; wire obj0_rom_ok;
    // fold <-> behavioral slot
    wire        obj0_cs;  wire [21:0] obj0_addr;
    reg  [31:0] obj0_data; reg obj0_ok;

    // sprite table
    wire [9:0]  tbl_addr;  reg [15:0] tbl [0:1023];  reg [15:0] tbl_dout;
    always @(posedge clk) tbl_dout <= tbl[tbl_addr];

    wire [15:0] pxl;
    jtnslasher_obj #(.BPP(5)) u_eng(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .HS(HS), .LVBL(LVBL), .LHBL(LHBL), .vrender(vrender), .hdump(hdump),
        .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(obj0_rom_cs), .rom_addr(obj0_rom_addr),
        .rom_data(obj0_rom_data), .rom_ok(obj0_rom_ok), .pxl(pxl) );

    jtnslasher_sdram u_fold(
        .rst(rst), .clk(clk),
        .pf1_rom_cs(1'b0), .pf1_rom_addr(19'd0), .pf1_rom_data(), .pf1_rom_ok(),
        .pf2_rom_cs(1'b0), .pf2_rom_addr(19'd0), .pf2_rom_data(), .pf2_rom_ok(),
        .pf3_rom_cs(1'b0), .pf3_rom_addr(19'd0), .pf3_rom_data(), .pf3_rom_ok(),
        .pf4_rom_cs(1'b0), .pf4_rom_addr(19'd0), .pf4_rom_data(), .pf4_rom_ok(),
        .obj0_rom_cs(obj0_rom_cs), .obj0_rom_addr(obj0_rom_addr),
        .obj0_rom_data(obj0_rom_data), .obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(1'b0), .obj1_rom_addr(21'd0), .obj1_rom_data(), .obj1_rom_ok(),
        .gfx1a_cs(), .gfx1a_addr(), .gfx1a_data(16'd0), .gfx1a_ok(1'b0),
        .gfx1b_cs(), .gfx1b_addr(), .gfx1b_data(16'd0), .gfx1b_ok(1'b0),
        .gfx2a_cs(), .gfx2a_addr(), .gfx2a_data(16'd0), .gfx2a_ok(1'b0),
        .gfx2b_cs(), .gfx2b_addr(), .gfx2b_data(16'd0), .gfx2b_ok(1'b0),
        .obj0_cs(obj0_cs), .obj0_addr(obj0_addr), .obj0_data(obj0_data), .obj0_ok(obj0_ok),
        .obj1_cs(), .obj1_addr(), .obj1_data(32'd0), .obj1_ok(1'b0) );

    // ===== behavioral slot: unique addr-derived data + IRREGULAR latched ok =====
    // model: when obj0_cs rises (or addr changes under cs), start a random countdown;
    // when it expires, present data and HOLD ok high (OKLATCH=1) until cs drops.
    function [31:0] memword(input [21:0] a);
        memword = { ~a[15:0], a[15:0] };   // unique, never X, never 0 (since ~a!=a)
    endfunction
    reg [21:0] cur_addr;
    integer    cnt;
    reg        busy;
    always @(posedge clk) begin
        if(rst) begin obj0_ok<=0; obj0_data<=0; busy<=0; cnt<=0; cur_addr<=22'h3FFFFF; end
        else begin
            if(!obj0_cs) begin
                obj0_ok<=0; busy<=0;
            end else begin
                if(!busy || obj0_addr!==cur_addr) begin
                    // new request: arm a random latency
                    cur_addr <= obj0_addr;
                    busy     <= 1;
                    obj0_ok  <= 0;
                    cnt      <= MINLAT + ({$random(seedr)} % (MAXLAT-MINLAT+1));
                end else if(cnt>0) begin
                    cnt <= cnt-1;
                end else begin
                    obj0_data <= memword(cur_addr);
`ifdef GLITCH
                    // pathological: once ok would be high, randomly DROP it for a cycle
                    // (models a mid-hold re-arbitration / refresh stealing the bus) to
                    // attack the fold's fresh-ok edge detector and the engine's 2nd-ok consume.
                    obj0_ok   <= (({$random(seedr)} % 5) != 0);
`else
                    obj0_ok   <= 1;    // latched level until cs drops
`endif
                end
            end
        end
    end

    // sprite table: 8 distinct sprites, distinct codes, one line
    integer i;
    initial begin
        for(i=0;i<1024;i=i+1) tbl[i]=16'h0000;
        for(i=0;i<8;i=i+1) begin
            tbl[i*4+0] = 16'h0000;
            tbl[i*4+1] = (i*37+11) & 16'hFFFF;        // distinct codes spread out
            tbl[i*4+2] = { 7'(i+1), 9'(i*20+8) };
            tbl[i*4+3] = 16'h0000;
        end
        tbl[8*4+0] = 16'd200;  // sentinel off-zone
    end

    // expected fold word for an engine addr = same assembly the fold does, but with our memword:
    //   planes word @ {nwi,0}, plane4 word @ {nwi,1}; fold output = {p4[15:8], permute(hwswap16(planes))}
    function [20:0] fsm_nwi(input [20:0] a);
        fsm_nwi = { a[20:5], ~a[0], a[4:1] };
    endfunction
    function [31:0] hwswap16(input [31:0] d); hwswap16={d[23:16],d[31:24],d[7:0],d[15:8]}; endfunction
    function [31:0] permute(input [31:0] d);  permute ={d[23:16],d[7:0],d[31:24],d[15:8]};  endfunction
    function [39:0] expect_word(input [20:0] eaddr);
        reg [20:0] nwi; reg [31:0] planes,p4;
        begin
            nwi    = fsm_nwi(eaddr);
            planes = memword({nwi,1'b0});
            p4     = memword({nwi,1'b1});
            expect_word = { p4[15:8], permute(hwswap16(planes)) };
        end
    endfunction

    // consume detector + checker
    wire consume = (!u_eng.buf_we) && u_eng.rom_cs && u_eng.rom_good && obj0_rom_ok && (u_eng.draw_cnt==0);
    integer ndd, dd_n, errors, j; reg found;
    reg [39:0] dd_seen [0:1023];
    reg [20:0] addr_seen [0:1023]; integer naddr;
    reg [39:0] last_got;
    initial begin ndd=0; dd_n=0; errors=0; naddr=0; end

    reg [39:0] exp; reg [39:0] prev_got; reg have_prev;
    initial have_prev=0;
    always @(posedge clk) if(!rst && consume) begin
        exp = expect_word(obj0_rom_addr);
        ndd = ndd+1;
        // distinct got-word
        found=0; for(j=0;j<dd_n;j=j+1) if(dd_seen[j]===obj0_rom_data) found=1;
        if(!found && dd_n<1024) begin dd_seen[dd_n]=obj0_rom_data; dd_n=dd_n+1; end
        // distinct requested addr
        found=0; for(j=0;j<naddr;j=j+1) if(addr_seen[j]===obj0_rom_addr) found=1;
        if(!found && naddr<1024) begin addr_seen[naddr]=obj0_rom_addr; naddr=naddr+1; end
        if( obj0_rom_data !== exp ) begin
            errors = errors+1;
            if(errors<=12)
                $display("  MISMATCH consume#%0d engaddr=%06x got=%010x exp=%010x %s",
                    ndd, obj0_rom_addr, obj0_rom_data, exp,
                    (have_prev && obj0_rom_data===prev_got)?"(==prev=STALE)":"");
        end
        prev_got = obj0_rom_data; have_prev=1;
    end

    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(20) @(posedge clk);
        $display("--- tb_obj_stale SEED=%0d LAT=%0d..%0d : REAL engine+fold, irregular latched ok ---", SEED, MINLAT, MAXLAT);
        vrender=9'd4;
        HS=1; repeat(2)@(posedge clk); HS=0; repeat(2)@(posedge clk); HS=1; @(posedge clk); HS=0;
        repeat(8000) @(posedge clk);
        $display("==================================================");
        $display("  consumes=%0d  distinct requested addrs=%0d  distinct got-words=%0d  mismatches=%0d",
                 ndd, naddr, dd_n, errors);
        if( ndd>=2 && dd_n<=1 )
            $display("  *** UNIFORM-COLLAPSE: %0d consumes, only %0d distinct word -> SPRITE WOULD BE ONE COLOR ***", ndd, dd_n);
        else if( errors>0 )
            $display("  *** DATA WRONG under contention (%0d mismatches) but NOT uniform ***", errors);
        else
            $display("  CLEAN: every consume returned the correct word for its address (no stale, no collapse)");
        $display("==================================================");
        $finish;
    end
    initial begin #300_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
