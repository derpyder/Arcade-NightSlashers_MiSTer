`timescale 1ns/1ps
`include "obj_cfg_f2700.vh"
// ============================================================================
// tb_obj_comb.v  --  OBJ line-buffer FILL-vs-SWAP RACE test  (comb/venetian-blind)
//
// Confirms or kills the hypothesis that the per-scanline sprite "comb" artifact
// is an obj line-buffer fill-vs-swap race in jtframe_obj_buffer.v:
//   - `line` (the ping-pong parity) toggles UNCONDITIONALLY on LHBL-fall
//     (jtframe_obj_buffer.v:92-96) with NO "draw complete" handshake.
//   - Writes -> {line, wr_af}; DISPLAY reads -> {~line, rd_addr}.
// Under heavy sprite load (~70 sprites/line, frame f2700) with realistic per-fetch
// latency the draw does NOT finish inside one scanline; the half still being written
// is swapped to display -> alternating-parity mismatches vs the settled golden.
//
// Unlike the older benches, this one reads the DISPLAY read port of the REAL buffer
// (through the swap), NOT buf_we (which is blind to the physical half).
//
// Build:  iverilog -g2012 -DLAT=<n> [-DFIXSWAP] -o x.vvp tb_obj_comb.v \
//            <jtnslasher_obj.v|jtnslasher_obj_fix.v> jtframe_obj_buffer[_fix].v jtframe_dual_ram.v
// ----------------------------------------------------------------------------
`ifndef LAT
 `define LAT 1
`endif
// Fast-engine clocks per scanline. Real deco32 line ~ 384 pixels * 8 = 3072 fast clks.
`ifndef LINECLKS
 `define LINECLKS 3072
`endif
// Fast clocks of hblank (LHBL low). ~64 border pixels * 8 = 512.
`ifndef HBLANK_CLKS
 `define HBLANK_CLKS 512
`endif
// Pixel cadence: one displayed pixel every PXLDIV fast clocks.
`ifndef PXLDIV
 `define PXLDIV 8
`endif

module tb_obj_comb;
    reg          clk=0, rst=1;
    reg          pxl_cen=0;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1, LVBL=1;
    wire [ 9:0]  tbl_addr; reg [15:0] tbl_dout;
    wire         rom_cs;   wire [20:0] rom_addr; reg [8*`BPP-1:0] rom_data; reg rom_ok=0;
    wire [15:0]  pxl;
    always #5 clk=~clk;

    // ---- sprite OAM (settled, read directly) ----
    reg [31:0] sprtbl [0:2047];
    initial $readmemh(`SPRFILE, sprtbl);
    always @(posedge clk) tbl_dout <= sprtbl[tbl_addr][15:0];

    // ---- gfx ROM ----
    reg [8*`BPP-1:0] gfxrom [0:`MEMW-1];
    initial $readmemh(`GFXFILE, gfxrom);

    // ---- parameterized fetch latency: rom_ok asserts LAT clks after rom_cs rises ----
    integer latctr;
    always @(posedge clk) begin
        if (!rom_cs)      begin rom_ok<=0; latctr<=0; end
        else if (!rom_ok) begin
            if (latctr >= `LAT-1) begin rom_data <= gfxrom[rom_addr]; rom_ok<=1; end
            else                   latctr <= latctr + 1;
        end
    end

    // ---- DUT: real obj engine + real jtframe_obj_buffer (inside) ----
`ifdef FIXSWAP
    jtnslasher_obj_fix #(.BPP(`BPP)) u_dut(
`else
    jtnslasher_obj #(.BPP(`BPP)) u_dut(
`endif
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
        .vrender(vrender), .hdump(hdump),
        .tbl_addr(tbl_addr), .tbl_dout(tbl_dout),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .pxl(pxl)
    );

    // ---- golden (settled) framebuffer: 320x240, one 16-bit mix word per pixel ----
    reg [15:0] golden [0:76799];
    initial $readmemh("golden_obj_f2700.hex", golden);

    // ---- DISPLAYED framebuffer captured through the swap ----
    reg [15:0] disp [0:76799];
    integer q; initial for(q=0;q<76800;q=q+1) disp[q]=16'h0;

    // ---- swap-straddle assertion (as specified): draw active across the LHBL-fall swap ----
    integer straddle_cnt;
    reg     straddle_this_pass;      // set if buf_we/draw_busy is high at negedge LHBL of a pass
    always @(negedge LHBL) begin
        if (u_dut.buf_we) begin
            straddle_cnt = straddle_cnt + 1;
            straddle_this_pass = 1'b1;
            $display("STRADDLE: draw active across swap (vrender=%0d, buf_waddr=%0d)", vrender, u_dut.buf_waddr);
        end else if (u_dut.draw_busy) begin
            // draw FSM still busy (between halves / waiting on rom_ok) at the swap boundary
            straddle_cnt = straddle_cnt + 1;
            straddle_this_pass = 1'b1;
            $display("STRADDLE: draw busy across swap (vrender=%0d)", vrender);
        end
    end

    // ---- per-line bookkeeping ----
    integer ln, k, i, px;
    integer mism_lines, mism_even, mism_odd;
    integer line_had_mismatch;
    integer straddle_and_mism, straddle_lines;
    // record the parity of u_dut.u_buffer.line that was DISPLAYED (=~line at read time)
    reg line_parity_disp [0:239];
    reg line_straddled   [0:239]; // did the DRAW of this golden line straddle the swap?

    // Faithful per-scanline sequence:
    //   * HS pulse (parse restart for THIS vrender)
    //   * draw window: run engine at fast clk for the active portion, drawing into half `line`
    //   * during active window also read the DISPLAY port (half `~line`) at pixel cadence -> that
    //     is the PREVIOUS line's rendered content (classic 1-line-delayed line buffer)
    //   * LHBL low (hblank) then LHBL high toggles `line` on the fall->...->fall edge model below.
    //
    // We drive LHBL with real polarity: LHBL HIGH during active, LOW during hblank. The buffer
    // swaps on (!LHBL && last_LHBL), i.e. the active->hblank transition (negedge LHBL).

    // One scanline, modelled in two explicit phases so stock and fix are measured on equal footing:
    //
    //   DRAW  phase: HS pulse restarts parse; LHBL held high for the active budget while the obj
    //                engine fills half `line`. NO display reads here.
    //   SWAP  phase: LHBL driven low (hblank). The buffer's swap fires here:
    //                  - stock: UNCONDITIONALLY on negedge LHBL (may straddle a still-busy draw)
    //                  - fix  : latched, applied only once draw_busy deasserts (deferred, never dropped)
    //   DISPLAY phase (of the PREVIOUS line): after the swap settles, read out half `~line`
    //                (now the just-finished line) at pixel cadence into disp[goldline].
    //
    // Because the buffer is 1-line-delayed, the half we DISPLAY-read after this pass's swap holds the
    // line drawn in THIS pass. So we display-read AFTER drawing, and attribute it to goldline=vr.
    //
    // vr        = line to DRAW then DISPLAY this pass (<240) ; blank line otherwise
    // goldline  = golden line to store the display read under (=vr if <240, else -1)
    task run_scanline(input [8:0] vr, input integer goldline);
        integer c;
        reg [8:0] rdp;
        begin
            vrender = vr;
            straddle_this_pass = 1'b0;
            // --- DRAW phase ---
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            LHBL = 1; pxl_cen = 1'b0;
            for (c=0; c<(`LINECLKS-`HBLANK_CLKS); c=c+1) @(posedge clk);
            // --- SWAP phase: LHBL low. Swap happens here (stock: now; fix: when draw idles) ---
            LHBL = 0;
            @(posedge clk);   // negedge-LHBL: straddle detector fires if draw still active
            if (goldline >= 0 && goldline < 240)
                line_straddled[goldline] = straddle_this_pass;
            for (c=1; c<`HBLANK_CLKS; c=c+1) @(posedge clk);
`ifdef FIXSWAP
            // FIX: the swap was LATCHED at negedge LHBL and only applies once draw idles. Give the
            // still-running fill FSM room to finish this line; then the deferred `line<=~line` fires.
            for (c=0; c<2*`LINECLKS && (u_dut.draw_busy || u_dut.buf_we); c=c+1) @(posedge clk);
            @(posedge clk);  // let the deferred `line<=~line` register update
`endif
            // Under STOCK the swap already fired at negedge LHBL, FREEZING half `line` (the draw
            // target) as-is; if the draw over-ran it is frozen TRUNCATED -> the comb. We read it now.
            // --- DISPLAY phase: read half {~line, hdump} which now holds THIS line's pixels ---
            LHBL = 1;
            rdp  = 0;
            if (goldline >= 0 && goldline < 240)
                line_parity_disp[goldline] = ~u_dut.u_buffer.line;
            for (c=0; c<(320*`PXLDIV + 16); c=c+1) begin
                if (c % `PXLDIV == 0 && rdp < 9'd320) begin
                    hdump   <= rdp;
                    pxl_cen <= 1'b1;
                end else pxl_cen <= 1'b0;
                @(posedge clk);
                if (c % `PXLDIV == 1 && rdp < 9'd320) begin
                    if (goldline >= 0 && goldline < 240)
                        disp[goldline*320 + rdp] = u_dut.u_buffer.dump_data;
                    rdp = rdp + 9'd1;
                end
            end
            pxl_cen <= 1'b0;
        end
    endtask

    initial begin
        straddle_cnt = 0;
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        // frame boundary pulse
        LVBL=0; LHBL=0; repeat(4) @(posedge clk); LVBL=1; LHBL=1; repeat(2) @(posedge clk);

        // The line buffer is 1-line-delayed: the display read during pass v returns what was drawn
        // during pass v-1. We DRAW line v during pass v; its finished pixels are DISPLAYED (and
        // captured) during pass v+1. So:
        //   pass 0        : draw golden line 0, display-read is garbage (goldline=-1, discarded)
        //   pass v (1..240): draw golden line v (capped at 239), display-read = golden line v-1 -> store
        for (k=0;k<240;k=k+1) line_straddled[k]=1'b0;
        for (ln=0; ln<240; ln=ln+1) begin
            run_scanline(ln[8:0], ln);   // draw line ln, freeze at swap, read it out -> disp[ln]
        end

        // ---------- ANALYSIS ----------
        mism_lines=0; mism_even=0; mism_odd=0; straddle_and_mism=0; straddle_lines=0;
        for (ln=0; ln<240; ln=ln+1) begin
            line_had_mismatch = 0;
            for (px=0; px<320; px=px+1) begin
                if (disp[ln*320+px] !== golden[ln*320+px]) line_had_mismatch = 1;
            end
            if (line_straddled[ln]) straddle_lines = straddle_lines + 1;
            if (line_had_mismatch) begin
                mism_lines = mism_lines + 1;
                if (line_parity_disp[ln] == 1'b0) mism_even = mism_even + 1;
                else                               mism_odd  = mism_odd  + 1;
                if (line_straddled[ln]) straddle_and_mism = straddle_and_mism + 1;
            end
        end

        $display("================ LAT=%0d %s ================",
                 `LAT, `ifdef FIXSWAP "[FIX: draw-idle-gated swap]" `else "[stock]" `endif);
        $display("  mismatching displayed lines : %0d / 240", mism_lines);
        $display("  mismatch parity split       : half0=%0d  half1=%0d", mism_even, mism_odd);
        if (mism_lines>0) begin
            if (mism_even==0 || mism_odd==0)
                $display("  -> mismatches confined to ONE parity: YES");
            else
                $display("  -> mismatches on BOTH parities (contiguous heavy band spans both halves)");
        end else begin
            $display("  -> no mismatches");
        end
        $display("  straddle events (total)                   : %0d", straddle_cnt);
        $display("  golden lines whose DRAW straddled the swap : %0d", straddle_lines);
        $display("  mismatching lines that ALSO straddled      : %0d / %0d", straddle_and_mism, mism_lines);
        // dump displayed frame for optional visual inspection
        begin:dd integer f;
            f=$fopen(`ifdef FIXSWAP "disp_comb_fix.hex" `else "disp_comb.hex" `endif ,"w");
            for(i=0;i<76800;i=i+1) $fwrite(f,"%04x\n", disp[i]);
            $fclose(f);
        end
        $finish;
    end
endmodule
