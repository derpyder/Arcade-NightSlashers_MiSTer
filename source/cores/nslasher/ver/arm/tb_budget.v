`timescale 1ns/1ps
// ============================================================================
//  tb_budget.v — CANDIDATE 6 ARBITER (fast-boot + real frame-budget measure)
// ----------------------------------------------------------------------------
//  Boots the REAL nslasher ARM ROM at cen=1 (fast) to reach the IRQ-driven game
//  loop (detected: pcmax in title region AND imask has toggled 0->1->0 = handler
//  entered+returned, i.e. the game is running its VBL-IRQ frame loop).
//  THEN it locks vbl_irq to the REAL hardware frame period measured IN cen_arm
//  TICKS:  FRAME_CEN = 7080500/59.1856 = 119632 cen ticks/frame.  cen stays =1 so
//  1 cen tick == 1 clk == fast sim, but the IRQ cadence is the true HW budget.
//
//  Per frame (between consecutive vbl_irq), measures:
//    cenF      = cen ticks in the frame (== FRAME_CEN by construction)
//    fetchF    = NEW rom-fetches (retired-instr proxy) in the frame
//    busyF     = cen ticks the pipeline actually advanced (PC moved) = WORK
//    idleF     = cen ticks the ARM sat in a tiny wait window (idle tail)
//    handlerF  = cen ticks with imask=1 (inside the IRQ handler)
//    overrun   = at next vbl_irq, was imask=1 (still in handler) or irq_l already
//                pending (didn't finish)?  1 == OVERRUN.
//  VERDICT: handler/idle split. If the ARM reaches a real idle wait every frame
//  (idleF>0, handlerF<<frame) => FITS (so slow-motion is NOT throughput).  If it
//  is busy the entire frame / still in handler at next IRQ => OVERRUN.
// ============================================================================
module tb_budget;
    reg         clk = 0, rst = 1;
    reg         cen_arm = 1;
    reg         vbl = 0, vbl_irq = 0;
    reg  [15:0] in0 = 16'hffff, in1 = 16'hffff;
    wire        vbl_ack;
    wire [21:0] rom_addr;  wire rom_cs;  reg [31:0] rom_data; reg rom_ok = 0;
    wire [16:2] ram_addr;  wire ram_cs;  wire [3:0] ram_we; wire [31:0] ram_dout;
    reg  [31:0] ram_data;  reg ram_ok = 0;
    wire [ 7:0] snd_latch; wire snd_req;
    wire [31:0] pc;

    wire [23:0] apc   = u_dut.u_arm.u_execute.u_register_bank.r15;
    wire        imask = u_dut.u_arm.execute_status_bits[27];
    wire [ 2:0] nxti  = u_dut.u_arm.u_decode.next_interrupt;

    always #10.416 clk = ~clk;
    always @(posedge clk) cen_arm <= 1'b1;   // cen=1 fast boot; IRQ cadence carries the real budget

    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin rom_data <= rawrom[rom_addr[17:0]]; rom_ok <= rom_cs; end

    reg [31:0] wram [0:32767];
    integer j; initial for (j=0;j<32768;j=j+1) wram[j]=0;
    always @(posedge clk) begin
        ram_ok <= ram_cs;
        if (ram_cs) begin
            if (ram_we[0]) wram[ram_addr][ 7: 0] <= ram_dout[ 7: 0];
            if (ram_we[1]) wram[ram_addr][15: 8] <= ram_dout[15: 8];
            if (ram_we[2]) wram[ram_addr][23:16] <= ram_dout[23:16];
            if (ram_we[3]) wram[ram_addr][31:24] <= ram_dout[31:24];
            ram_data <= wram[ram_addr];
        end
    end

    jtnslasher_main u_dut(
        .rst(rst), .clk(clk), .cen_arm(cen_arm),
        .in0(in0), .in1(in1), .vbl(vbl), .vbl_irq(vbl_irq), .vbl_ack(vbl_ack),
        .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_data(rom_data), .rom_ok(rom_ok),
        .ram_addr(ram_addr), .ram_cs(ram_cs), .ram_we(ram_we), .ram_dout(ram_dout),
        .ram_data(ram_data), .ram_ok(ram_ok),
        .snd_latch(snd_latch), .snd_req(snd_req), .dbg_pc_addr(pc));

    // ---- progress + IRQ-loop detection ----
    integer fetches=0;
    reg [23:0] pcmax=0, lastpc=22'h3fffff;
    reg imask_d=1; integer mask_toggles=0;
    reg gameloop=0;
    always @(posedge clk) begin
        if (rom_cs && rom_addr!=lastpc) begin lastpc<=rom_addr; fetches<=fetches+1;
            if (pc[23:0]>pcmax) pcmax<=pc[23:0]; end
        imask_d <= imask;
        if (imask!=imask_d) mask_toggles<=mask_toggles+1;
        // game loop reached: the IRQ handler has run+returned at least twice (imask 1->0->1->0).
        // This is the moment the game's VBL-IRQ frame loop is live (boot enables IRQ ~vbl230).
        if (!gameloop && mask_toggles>=4) gameloop<=1;
    end

    // ---- per-clk work/idle/handler accounting (cen=1 so each clk is a cen tick) ----
    reg [23:0] apc_d2=0;
    wire pc_moved = (apc != apc_d2);
    always @(posedge clk) apc_d2 <= apc;

    // ---- IRQ edge counters ----
    integer vblpulse=0, irqtaken=0; reg vblp_d=0, nxti3_d=0;
    always @(posedge clk) begin
        vblp_d <= vbl_irq;
        if (vbl_irq & ~vblp_d) vblpulse<=vblpulse+1;
        nxti3_d <= (nxti==3'd3);
        if ((nxti==3'd3) & ~nxti3_d) irqtaken<=irqtaken+1;
    end

    // ===================== real-budget frame engine ======================
    localparam integer FRAME_CEN = 119632;  // 7080500 / 59.1856 Hz
    localparam integer VBL_CEN   = 9572;     // ~24/264 lines = vblank window
    integer fcnt=0; reg frames_on=0;
    // per-frame accumulators
    integer accCen=0, accFetch=0, accBusy=0, accIdle=0, accHandler=0;
    integer prevFetch=0;
    // idle = pipeline not advancing AND not in handler (waiting). busy = advancing.
    always @(posedge clk) if (frames_on) begin
        accCen <= accCen+1;
        if (imask) accHandler <= accHandler+1;
        if (pc_moved) accBusy <= accBusy+1;
        else if (!imask) accIdle <= accIdle+1;
        // frame boundary
        if (fcnt >= FRAME_CEN-1) begin
            fcnt <= 0;
            vbl_irq <= 1'b1; vbl <= 1'b1;
        end else begin
            fcnt <= fcnt+1;
            if (fcnt==VBL_CEN) vbl <= 1'b0;
        end
    end
    always @(posedge clk) if (vbl_irq && fcnt!=0) vbl_irq <= 1'b0;  // 1-clk pulse

    // ---- log a frame's accumulators at each vbl_irq edge ----
    reg [31:0] L_cen[0:255], L_fetch[0:255], L_busy[0:255], L_idle[0:255], L_handler[0:255];
    reg        L_over[0:255];
    integer nlog=0;
    reg measuring=0;
    always @(posedge clk) if (frames_on && vbl_irq && ~vblp_d) begin
        if (measuring && nlog<256) begin
            L_cen[nlog]    = accCen;
            L_fetch[nlog]  = fetches - prevFetch;
            L_busy[nlog]   = accBusy;
            L_idle[nlog]   = accIdle;
            L_handler[nlog]= accHandler;
            L_over[nlog]   = imask | u_dut.irq_l;   // still busy/pending at frame end?
            nlog = nlog+1;
        end
        // reset accumulators for next frame
        accCen=0; accFetch=0; accBusy=0; accIdle=0; accHandler=0;
        prevFetch = fetches;
        measuring = 1;
    end

    integer hb=0;
    initial forever begin #500000;
        $display("[HB %0dus] pcmax=%06x fetches=%0d gameloop=%0d masktog=%0d vblp=%0d irqtaken=%0d imask=%0d frames_on=%0d nlog=%0d",
                 $time/1000, pcmax, fetches, gameloop, mask_toggles, vblpulse, irqtaken, imask, frames_on, nlog);
        $fflush(1);
    end

    integer k;
    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- tb_budget: cen=1 fast boot; FRAME_CEN budget=%0d cen ticks ---", FRAME_CEN);
        // Phase 1: artificial fast frames to drive boot to the game loop.
        fork
          begin : bootframes
            while (!gameloop) begin
                #150000 vbl=1; vbl_irq=1; repeat(3)@(posedge clk); vbl_irq=0;
                #30000  vbl=0;
            end
          end
        join_none
        // wait for game loop
        k=0; while (!gameloop && k<400) begin #500000; k=k+1; end
        if (gameloop) $display(">>> GAME LOOP reached (pcmax=%06x masktog=%0d) at t=%0t <<<", pcmax, mask_toggles, $time);
        else          $display(">>> game loop NOT reached (pcmax=%06x); measuring anyway <<<", pcmax);
        // hand off to the real-budget frame engine
        disable bootframes;
        vbl=0; vbl_irq=0; fcnt=0;
        @(posedge clk); frames_on=1;
        $display(">>> real-budget frames engaged (FRAME_CEN=%0d). measuring %0d frames... <<<", FRAME_CEN, 16);
        $fflush(1);
        // run ~16 budget frames (enough for the fit/overrun verdict)
        while (nlog<16 && k<2000) begin #500000; k=k+1; end

        // ===================== REPORT =====================
        $display("==================== FRAME-BUDGET REPORT ====================");
        $display("FRAME_CEN = %0d cen_arm ticks (= 7080500/59.1856 Hz)", FRAME_CEN);
        $display(" idx    cenF   fetchF    busyF   idleF  handlerF  busy%%  hand%%  OVER");
        begin : rpt
        integer i; integer sBusy=0,sIdle=0,sHand=0,sFetch=0,sCen=0,nOver=0;
        for (i=0;i<nlog;i=i+1) begin
            sCen=sCen+L_cen[i]; sBusy=sBusy+L_busy[i]; sIdle=sIdle+L_idle[i];
            sHand=sHand+L_handler[i]; sFetch=sFetch+L_fetch[i]; if(L_over[i]) nOver=nOver+1;
            if (i<48 || i>=nlog-6)
            $display(" %3d  %7d  %6d  %7d %7d  %7d   %3d%%   %3d%%   %0d",
                i, L_cen[i], L_fetch[i], L_busy[i], L_idle[i], L_handler[i],
                L_cen[i]>0?(100*L_busy[i])/L_cen[i]:0, L_cen[i]>0?(100*L_handler[i])/L_cen[i]:0, L_over[i]);
        end
        if (nlog>0) begin
        $display("------------------------------------------------------------");
        $display("AVG  cenF=%0d  fetchF=%0d  busyF=%0d (%0d%%)  idleF=%0d (%0d%%)  handlerF=%0d (%0d%%)",
            sCen/nlog, sFetch/nlog, sBusy/nlog, sCen>0?(100*sBusy)/sCen:0,
            sIdle/nlog, sCen>0?(100*sIdle)/sCen:0, sHand/nlog, sCen>0?(100*sHand)/sCen:0);
        $display("frames OVERRUN (in-handler/irq-pending at next vbl) = %0d / %0d", nOver, nlog);
        if (sCen>0 && (100*sBusy)/sCen >= 90)
            $display(">>> VERDICT: ARM busy ~entire frame => OVERRUN / throughput-bound. <<<");
        else
            $display(">>> VERDICT: ARM idles %0d%% of each frame (busy %0d%%) => per-frame work FITS the budget. <<<",
                     sCen>0?(100*sIdle)/sCen:0, sCen>0?(100*sBusy)/sCen:0);
        end
        end
        $display("vblpulse=%0d irqtaken=%0d", vblpulse, irqtaken);
        $finish;
    end
endmodule
