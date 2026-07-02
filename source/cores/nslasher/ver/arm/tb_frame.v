`timescale 1ns/1ps
// ============================================================================
//  tb_frame.v  —  CANDIDATE 6: FULL-GAME GROUND TRUTH (frame-budget arbiter)
// ----------------------------------------------------------------------------
//  Boots the REAL nslasher ARM ROM (raw_rom.hex, deco156 at-fetch, nf6 cache)
//  on the Amber a23 through the REAL jtnslasher_main, paced by the REAL
//  fractional cen_arm (7753/52559 of 48 MHz = 7.0805 MHz).
//
//  Unlike tb_boot.v (artificial 200us frame, decoupled from cen), here vbl_irq
//  fires every FRAME_CEN cen_arm ticks, where FRAME_CEN = the real hardware
//  budget: cen_arm / frame_rate = 7080500 / 59.1856 = 119632 cen_arm ticks.
//  vbl_irq is a TRUE 1-clk pulse (matches jtnslasher_game.v's LVBL-edge pulse).
//  vbl (IN1[4] level) is held high for the vblank window (~8% of the frame).
//
//  MEASURE, per frame, once the game has booted into its per-frame loop:
//   (a) cen_arm ticks between consecutive vbl_irq pulses  (== FRAME_CEN by const)
//   (b) ARM fetches (retired-instruction proxy) per frame
//   (c) FITS vs OVERRUN:  at the instant the NEXT vbl_irq fires, is the ARM
//       (i)  idle in its vblank-wait (imask=0, irq_l=0, spinning in a tiny PC
//            window) -> FITS;  or
//       (ii) still mid-handler (imask=1) / irq_l already pending -> OVERRUN.
//       We also measure HANDLER OCCUPANCY: # cen_arm ticks per frame spent with
//       imask=1 (inside the IRQ handler) vs idle (imask=0). occupancy ~100%
//       every frame = overrun; occupancy <100% with a real idle tail = fits.
// ============================================================================
module tb_frame;
    reg         clk = 0, rst = 1;
    reg         cen_arm = 0;
    reg         vbl = 0, vbl_irq = 0;
    reg  [15:0] in0 = 16'hffff, in1 = 16'hffff;
    wire        vbl_ack;
    wire [21:0] rom_addr;  wire rom_cs;  reg [31:0] rom_data; reg rom_ok = 0;
    wire [16:2] ram_addr;  wire ram_cs;  wire [3:0] ram_we; wire [31:0] ram_dout;
    reg  [31:0] ram_data;  reg ram_ok = 0;
    wire [ 7:0] snd_latch; wire snd_req;
    wire [31:0] pc;

    // architectural taps
    wire [23:0] apc   = u_dut.u_arm.u_execute.u_register_bank.r15;
    wire [31:0] ar14  = u_dut.u_arm.u_execute.u_register_bank.r14;
    wire        imask = u_dut.u_arm.execute_status_bits[27]; // CPSR I-bit (1=IRQ masked = in handler/init)
    wire [ 2:0] nxti  = u_dut.u_arm.u_decode.next_interrupt;

    always #10.416 clk = ~clk;   // 48 MHz

    // ---- REAL fractional cen_arm: 7753/52559 of 48 MHz = 7.0805 MHz ----
    localparam integer CEN_NUM = 7753;
    localparam integer CEN_DEN = 52559;
    integer cen_acc = 0;
    initial cen_arm = 0;
    always @(posedge clk) begin
        if (cen_acc + CEN_NUM >= CEN_DEN) begin
            cen_acc <= cen_acc + CEN_NUM - CEN_DEN;
            cen_arm <= 1'b1;
        end else begin
            cen_acc <= cen_acc + CEN_NUM;
            cen_arm <= 1'b0;
        end
    end

    // ---- behavioral ROM (raw, byte-reversed HW order) ----
    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin
        rom_data <= rawrom[rom_addr[17:0]];
        rom_ok   <= rom_cs;
    end

    // ---- 128 KB work RAM ----
    reg [31:0] wram [0:32767];
    integer j;
    initial for (j=0;j<32768;j=j+1) wram[j]=0;
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
        .snd_latch(snd_latch), .snd_req(snd_req), .dbg_pc_addr(pc)
    );

    // ===================== boot/progress tracking =====================
    integer fetches=0;
    reg [23:0] pcmax=0;
    reg [21:0] lastpc=22'h3fffff;
    reg        booted=0;          // reached the per-frame loop region
    always @(posedge clk) begin
        if (rom_cs && rom_addr!=lastpc) begin
            lastpc<=rom_addr; fetches<=fetches+1;
            if (pc[23:0]>pcmax) pcmax<=pc[23:0];
        end
    end

    // ===================== cen_arm tick + handler-occupancy counters ===
    integer cen_ticks_total=0;       // all cen_arm ticks since reset
    integer cen_in_handler=0;        // cen_arm ticks with imask=1 (inside handler/init)
    // per-frame snapshots
    integer f_cen_start=0;           // cen_ticks_total at last vbl_irq
    integer f_handler_start=0;       // cen_in_handler at last vbl_irq
    integer f_fetch_start=0;         // fetches at last vbl_irq
    always @(posedge clk) if (cen_arm) begin
        cen_ticks_total <= cen_ticks_total + 1;
        if (imask) cen_in_handler <= cen_in_handler + 1;
    end

    // ===================== IRQ chain edge counters =====================
    integer vblpulse=0, irqtaken=0;
    reg vblp_d=0; reg [2:0] nxti_d=3'd0;
    always @(posedge clk) begin
        nxti_d <= nxti;
        vblp_d <= vbl_irq;
        if (vbl_irq & ~vblp_d) vblpulse <= vblpulse+1;
        if (nxti==3'd3 && nxti_d!=3'd3) irqtaken <= irqtaken+1;
    end

    // ===================== FRAME GENERATOR (cen-locked) ================
    // FRAME_CEN = real budget = cen_arm/frame_rate = 7080500/59.1856 = 119632.
    // We count cen_arm ticks; at tick 0 of each frame emit a 1-clk vbl_irq pulse
    // and raise vbl (level). vbl drops after VBL_CEN ticks (vblank window).
    localparam integer FRAME_CEN = 119632;   // 7080500 / 59.1856 Hz
    localparam integer VBL_CEN   = 9572;     // ~8% (24/264 lines * budget) vblank window
    integer cen_in_frame=0;
    reg frames_armed=0;              // don't start the real-rate frames until booted
    // per-frame measurement record (printed at each vbl_irq once measuring)
    integer meas_frame=0;
    integer measuring=0;
    // state captured at the PREVIOUS vbl_irq, to evaluate the just-finished frame
    integer prev_cen=0, prev_handler=0, prev_fetch=0;
    reg     prev_valid=0;
    // overrun flag: was imask=1 (in handler) OR irq_l pending at the instant the
    // new vbl_irq fired?
    always @(posedge clk) if (cen_arm) begin
        if (frames_armed) begin
            if (cen_in_frame >= FRAME_CEN-1) begin
                cen_in_frame <= 0;
                vbl_irq <= 1'b1;     // 1-clk pulse (next cen tick it self-clears below)
                vbl     <= 1'b1;
            end else begin
                cen_in_frame <= cen_in_frame + 1;
                if (cen_in_frame == VBL_CEN) vbl <= 1'b0;
            end
        end
    end
    // self-clear vbl_irq one clk after it was set (true 1-clk pulse at clk grain)
    always @(posedge clk) if (vbl_irq && !(cen_arm && frames_armed && cen_in_frame==0)) vbl_irq <= 1'b0;

    // ===================== MEASUREMENT at each vbl_irq edge ============
    // When a vbl_irq fires, the just-finished frame's work = (counters now) -
    // (counters at previous vbl_irq). Evaluate fit/overrun by sampling, AT the
    // edge, whether the ARM was idle (imask=0 & irq_l=0) just before the edge.
    reg irql_at_edge=0, imask_at_edge=0;
    integer idle_ticks_frame=0;     // ticks in the just-finished frame with imask=0 (idle/main-loop)
    integer last_idle_run=0;        // longest consecutive idle run observed (proxy for the wait tail)
    integer cur_idle_run=0;
    always @(posedge clk) if (cen_arm && frames_armed) begin
        // track idle runs (imask=0 == not in handler) within the frame
        if (!imask) begin
            cur_idle_run <= cur_idle_run + 1;
            if (cur_idle_run+1 > last_idle_run) last_idle_run <= cur_idle_run+1;
        end else cur_idle_run <= 0;
    end

    reg [31:0] frame_log_cen [0:511];
    reg [31:0] frame_log_handler [0:511];
    reg [31:0] frame_log_fetch [0:511];
    reg [31:0] frame_log_idlerun [0:511];
    reg        frame_log_overrun [0:511];
    integer nlog=0;

    always @(posedge clk) if (vbl_irq & ~vblp_d & frames_armed) begin
        imask_at_edge = imask;
        irql_at_edge  = u_dut.irq_l;
        if (prev_valid && measuring && nlog<512) begin
            frame_log_cen[nlog]     = cen_ticks_total - prev_cen;
            frame_log_handler[nlog] = cen_in_handler  - prev_handler;
            frame_log_fetch[nlog]   = fetches         - prev_fetch;
            frame_log_idlerun[nlog] = last_idle_run;
            // OVERRUN if at the edge the ARM is still in the handler (imask=1) OR
            // an IRQ was already pending (handler didn't keep up).
            frame_log_overrun[nlog] = imask_at_edge | irql_at_edge;
            nlog = nlog + 1;
        end
        prev_cen     = cen_ticks_total;
        prev_handler = cen_in_handler;
        prev_fetch   = fetches;
        prev_valid   = 1;
        last_idle_run= 0;   // reset per-frame idle-run high-water
    end

    // ===================== sound / heartbeat =====================
    integer sndcnt=0;
    always @(posedge clk) if (snd_req) sndcnt<=sndcnt+1;

    initial forever begin
        #1000000;  // 1 ms
        $display("[HB %0dus] pcmax=%06x fetches=%0d cen=%0d vblp=%0d irqtaken=%0d imask=%0d armed=%0d meas=%0d nlog=%0d",
                 $time/1000, pcmax, fetches, cen_ticks_total, vblpulse, irqtaken, imask, frames_armed, measuring, nlog);
    end

    // ===================== run control =====================
    integer k;
    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- tb_frame: REALCEN boot, frame budget FRAME_CEN=%0d cen_arm ticks ---", FRAME_CEN);

        // Phase 1: boot WITHOUT real-rate frames but WITH periodic vbl_irq so the
        // game progresses (use a fast artificial frame to get past the EEPROM/init
        // phase quickly). We arm the real-rate frame engine once booted.
        // Simpler: arm real-rate frames immediately; the game's init does not need
        // many frames. Wait for pcmax to reach the title/attract loop, then measure.
        frames_armed = 1;

        // wait until booted to the per-frame loop (pcmax climbs to title region),
        // OR a generous time cap.
        k=0;
        while (pcmax < 24'h0acd00 && k<1200) begin #500000; k=k+1; end
        if (pcmax >= 24'h0acd00)
            $display(">>> BOOTED to per-frame loop (pcmax=%06x) at t=%0t; begin MEASURING <<<", pcmax, $time);
        else
            $display(">>> boot cap hit (pcmax=%06x) at t=%0t; MEASURING anyway (whatever loop it is) <<<", pcmax, $time);

        // let a couple of frames settle, then start logging
        repeat(2) @(posedge (vbl_irq));
        prev_valid = 0;       // reset baseline so the first logged frame is clean
        measuring  = 1;

        // measure up to 120 frames (or until log full)
        while (nlog < 120 && k<3000) begin #500000; k=k+1; end

        // ===================== REPORT =====================
        $display("==================== FRAME BUDGET REPORT ====================");
        $display("FRAME_CEN budget = %0d cen_arm ticks/frame (= 7080500/59.1856 Hz)", FRAME_CEN);
        $display("frames logged = %0d", nlog);
        $display(" idx   cen/frame  handler_cen  handler%%   fetches  idle_run  OVERRUN");
        begin : rpt
        integer i; integer sum_cen=0, sum_handler=0, sum_fetch=0, n_overrun=0;
        for (i=0;i<nlog;i=i+1) begin
            sum_cen     = sum_cen     + frame_log_cen[i];
            sum_handler = sum_handler + frame_log_handler[i];
            sum_fetch   = sum_fetch   + frame_log_fetch[i];
            if (frame_log_overrun[i]) n_overrun = n_overrun + 1;
            if (i<40 || i>=nlog-8)
            $display(" %3d   %8d   %8d    %3d%%    %7d  %7d   %0d",
                i, frame_log_cen[i], frame_log_handler[i],
                (frame_log_cen[i]>0)? (100*frame_log_handler[i])/frame_log_cen[i] : 0,
                frame_log_fetch[i], frame_log_idlerun[i], frame_log_overrun[i]);
        end
        if (nlog>0) begin
            $display("----------------------------------------------------------------");
            $display("AVG cen/frame      = %0d   (budget %0d)", sum_cen/nlog, FRAME_CEN);
            $display("AVG handler_cen    = %0d  (%0d%% of frame in IRQ handler)",
                     sum_handler/nlog, (sum_cen>0)?(100*sum_handler)/sum_cen:0);
            $display("AVG fetches/frame  = %0d", sum_fetch/nlog);
            $display("frames flagged OVERRUN (in-handler/irq-pending at next vbl) = %0d / %0d", n_overrun, nlog);
            $display("");
            if ((100*sum_handler)/sum_cen >= 95)
                $display(">>> VERDICT: ARM spends ~all of every frame in the IRQ handler => OVERRUN (throughput-bound). <<<");
            else
                $display(">>> VERDICT: ARM has an idle tail each frame (handler %0d%%) => FITS the budget. <<<",
                         (100*sum_handler)/sum_cen);
        end
        end
        $display("vblpulse=%0d irqtaken=%0d  (ratio irqtaken/vblpulse should be ~1.0)", vblpulse, irqtaken);
        $display("sound cmds = %0d", sndcnt);
        $finish;
    end
endmodule
