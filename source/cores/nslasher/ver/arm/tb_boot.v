`timescale 1ns/1ps
// Night Slashers — REAL ARM boot observation testbench (M2-int).
//  Boots the actual encrypted mainprg ROM (raw_rom.hex, built by make_rom.py) on the
//  Amber a23 through jtnslasher_main (with deco156 descramble on the fetch path).
//  Behavioral ROM (raw) + 128 KB work RAM; periodic VBlank IRQ. Observes the boot:
//  PC progress, work-RAM activity, and writes to the deco32 I/O regions (palette / Ace /
//  sprite / playfield / soundlatch) — those are the boot-progress fingerprints.
//  Not a strict PASS/FAIL (a full boot is complex): the win is "a23 runs real decrypted
//  code, makes sane accesses, doesn't fault at a low PC."
module tb_boot;
    reg         clk = 0, rst = 1;
    reg         cen_arm = 0;
    reg         vbl = 0, vbl_irq = 0;
    reg  [15:0] in0 = 16'hffff, in1 = 16'hffff;  // idle (active-low): no coins/buttons pressed
    wire        vbl_ack;
    wire [21:0] rom_addr;  wire rom_cs;  reg [31:0] rom_data; reg rom_ok = 0;
    wire [16:2] ram_addr;  wire ram_cs;  wire [3:0] ram_we; wire [31:0] ram_dout;
    reg  [31:0] ram_data;  reg ram_ok = 0;
    wire [ 7:0] snd_latch; wire snd_req;
    wire [31:0] pc;

    // ---- architectural-state taps (clean execution view; bypasses fetch prefetch) ----
    wire [23:0] apc   = u_dut.u_arm.u_execute.u_register_bank.r15;   // arch PC (word addr; byte = <<2)
    wire [31:0] ar1   = u_dut.u_arm.u_execute.u_register_bank.r1;
    wire [31:0] ar2   = u_dut.u_arm.u_execute.u_register_bank.r2;
    wire [31:0] ar14  = u_dut.u_arm.u_execute.u_register_bank.r14;   // lr
    wire        imask = u_dut.u_arm.execute_status_bits[27];        // ACTUAL IRQ mask (CPSR I-bit, execute stage; 1=masked)
    wire [ 2:0] nxti  = u_dut.u_arm.u_decode.next_interrupt;         // 1=dabt 2=firq 3=irq 4=adex 5=iabt 6=undef 7=swi
    wire        eeprom_sdo_tap = u_dut.eeprom_sdo;                   // 93C46 serial data out

    always #10.416 clk = ~clk;   // 48 MHz master (matches jtnslasher_game_sdram cen0_clk MFREQ=48000)

    // ----------------------------------------------------------------------------------
    // cen_arm pacing.
    //  Baseline (default):  cen_arm=1 every clk  -> ARM at full 48 MHz (boot-observation; ~7x fast).
    //  +DREALCEN:           cen_arm = real-hardware fractional pace (NUM/DEN of clk = 7.0805 MHz),
    //                       exactly the jtframe_gated_cen NUM=7753/DEN=52559 @48MHz used in
    //                       mister/jtnslasher_game_sdram.v -> 1 pulse / 6.779 clk (~1 in 7).
    //  The VBL cadence below is in ABSOLUTE sim time (200us/frame), INDEPENDENT of cen_arm, so
    //  DREALCEN reproduces the real CPU-vs-video timing ratio of the cab (the freeze hypothesis).
    // ----------------------------------------------------------------------------------
`ifdef REALCEN
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
`else
    initial cen_arm = 1;
    always @(posedge clk) cen_arm <= 1'b1;
`endif

    // raw (encrypted) program ROM, 256K words. jtnslasher_main descrambles on fetch.
    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin
        rom_data <= rawrom[rom_addr[17:0]];
        rom_ok   <= rom_cs;
    end

    // 128 KB byte-addressable work RAM
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

    // ---- observation ----
    integer fetches=0, ramwr=0, iowr=0;
    integer protrd=0, vblack=0;             // 104 prot reads ; VBL-IRQ acks (writes to 0x140000)
    reg [23:0] pcmin=24'hffffff, pcmax=0;
    reg [21:0] lastpc=22'h3fffff;
    reg [23:0] adr;
    reg        trace_on=0; integer ti=0; reg [23:0] tr[0:47];  // capture a loop PC trace after 3 ms
    reg        advanced=0;  // one-shot: boot left the <=0xc00 init/memset region
    // write-commit edge (one event per acknowledged write; robust to cen=1 holding wb_ack >1 clk)
    reg        wcommit_d=0, rcommit_d=0;
    integer    eepwr=0;                                   // 0x150000 EEPROM bit-bang writes (throttled log)
    reg        m_pal=0, m_dma=0, m_spr=0, m_vbl=0;        // milestone one-shots (post-memset progress)
    // ---- VRAM capture (M3b): snoop the boot's video-RAM writes; dump the final frame at $finish ----
    reg [31:0] vpal [0:2047];  // palette   0x168000 (word = 0x00BBGGRR)
    reg [31:0] vpf1 [0:2047];  // PF1 data  0x182000 (tile[11:0]+colour[15:12] in low 16)
    reg [31:0] vpf2 [0:2047];  // PF2 data  0x184000
    reg [31:0] vpf3 [0:2047];  // PF3 data  0x1c2000
    reg [31:0] vpf4 [0:2047];  // PF4 data  0x1c4000
    reg [31:0] vspr0[0:2047];  // spriteram  0x170000
    reg [31:0] vspr1[0:2047];  // spriteram2 0x178000
    reg [31:0] vctl12[0:7];    // PF12 control 0x1a0000
    reg [31:0] vctl34[0:7];    // PF34 control 0x1e0000
    reg [31:0] vace [0:63];    // Ace RAM   0x163000 (0xa0 bytes)
    reg [31:0] vpal2[0:2047];  // 7a cross-check: palette captured via the NEW cpu_we bus (vs wb-snoop)
    integer    vidwr=0, palmis=0;
    integer vi;
    integer vidrd=0; reg vrcommit_d=0;
    initial begin
        for (vi=0;vi<2048;vi=vi+1) begin vpal[vi]=0;vpf1[vi]=0;vpf2[vi]=0;vpf3[vi]=0;vpf4[vi]=0;vspr0[vi]=0;vspr1[vi]=0;vpal2[vi]=0; end
        for (vi=0;vi<8; vi=vi+1) begin vctl12[vi]=0; vctl34[vi]=0; end
        for (vi=0;vi<64;vi=vi+1) vace[vi]=0;
    end
    always @(posedge clk) begin
        if (rom_cs && rom_addr!=lastpc) begin
            lastpc<=rom_addr; fetches<=fetches+1;
            if (pc[23:0]<pcmin) pcmin<=pc[23:0];
            if (pc[23:0]>pcmax) pcmax<=pc[23:0];
            if (trace_on && ti<48) begin tr[ti]<=pc[23:0]; ti<=ti+1; end
            if (!advanced && pc[23:0]>24'h000c04) begin
                advanced<=1;
                $display("[%8t] *** BOOT ADVANCED past memset: PC=%06x (clear done) ***", $time, pc[23:0]);
            end
        end
        if ($time>3000000 && !trace_on) trace_on<=1;

        // ---- 104/prot READS (what the boot polls), deduped on the read-commit rising edge ----
        rcommit_d <= (u_dut.rd & u_dut.wb_ack & u_dut.is_prot);
        if ((u_dut.rd & u_dut.wb_ack & u_dut.is_prot) && !rcommit_d) begin
            protrd<=protrd+1;
            if (protrd<80) begin
                $write("[%8t] PROT rd %06x -> %08x  (PC=%06x) ", $time, u_dut.wb_adr[23:0], u_dut.wb_rdat, pc[23:0]);
                if      (u_dut.wb_adr[11:0]==12'h500) $display("IN0");
                else if (u_dut.wb_adr[11:0]==12'h988) $display("IN1 (bit20=vbl)");
                else if (u_dut.wb_adr[11:0]==12'h6b4) $display("EEPROM sdo");
                else $display("(other prot)");
            end
        end

        // ---- VIDEO-REGION CPU READS (0x120000-0x1FFFFF): our core returns 0 (read-back not impl).
        // If the boot reads these, the suspected video-RAM POST is real -> the read-back fix is needed.
        vrcommit_d <= (u_dut.rd & u_dut.wb_ack & ~u_dut.is_rom & ~u_dut.is_ram & ~u_dut.is_prot & (u_dut.wb_adr[23:20]==4'h1));
        if ((u_dut.rd & u_dut.wb_ack & ~u_dut.is_rom & ~u_dut.is_ram & ~u_dut.is_prot & (u_dut.wb_adr[23:20]==4'h1)) && !vrcommit_d) begin
            vidrd<=vidrd+1;
            if (vidrd<60) $display("[%8t] VID rd %06x -> %08x  (PC=%06x)", $time, u_dut.wb_adr[23:0], u_dut.wb_rdat, pc[23:0]);
        end

        if (ram_cs && |ram_we) ramwr<=ramwr+1;

        // ---- deco32 I/O WRITES, deduped on the write-commit rising edge ----
        wcommit_d <= (u_dut.wr & u_dut.wb_ack & ~u_dut.is_rom & ~u_dut.is_ram);
        if ((u_dut.wr & u_dut.wb_ack & ~u_dut.is_rom & ~u_dut.is_ram) && !wcommit_d) begin
            adr = u_dut.wb_adr[23:0]; iowr<=iowr+1;
            // VRAM capture (last write wins = final-frame state)
            if      (adr>=24'h168000 && adr<24'h16a000) vpal [(adr-24'h168000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h182000 && adr<24'h184000) vpf1 [(adr-24'h182000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h184000 && adr<24'h186000) vpf2 [(adr-24'h184000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h1c2000 && adr<24'h1c4000) vpf3 [(adr-24'h1c2000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h1c4000 && adr<24'h1c6000) vpf4 [(adr-24'h1c4000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h170000 && adr<24'h172000) vspr0[(adr-24'h170000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h178000 && adr<24'h17a000) vspr1[(adr-24'h178000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h1a0000 && adr<24'h1a0020) vctl12[(adr-24'h1a0000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h1e0000 && adr<24'h1e0020) vctl34[(adr-24'h1e0000)>>2] <= u_dut.wb_wdat;
            else if (adr>=24'h163000 && adr<24'h1630a0) vace [(adr-24'h163000)>>2] <= u_dut.wb_wdat;
            // post-memset progress milestones (one-shot)
            if (adr==24'h140000 && !m_vbl) begin m_vbl<=1; $display("[%8t] *** VBL ACK (0x140000) — IRQ path live ***", $time); end
            if (adr[23:12]==12'h168 && !m_pal) begin m_pal<=1; $display("[%8t] *** PALETTE DATA @%06x — video setup ***", $time, adr); end
            if (adr==24'h16c008 && !m_dma) begin m_dma<=1; $display("[%8t] *** PALETTE DMA trigger (0x16c008) ***", $time); end
            if ((adr[23:12]==12'h170||adr[23:12]==12'h178) && !m_spr) begin m_spr<=1; $display("[%8t] *** SPRITE DATA @%06x ***", $time, adr); end
            if (adr==24'h140000) vblack<=vblack+1;
            // throttle the repetitive 0x150000 EEPROM bit-bang (count all, print first few)
            if (adr==24'h150000) begin
                eepwr<=eepwr+1;
                // log a window of bit-bang writes AFTER the boot enters the EEPROM-heavy phase (~7.2ms),
                // to see a real transaction (clk/di/cs). scs=~d[6] per MAME nslasher_eeprom_w.
                if (eepwr>=1 && eepwr<60) $display("[%8t] EEwr %04x: clk=%0d di=%0d scs=%0d  (sdo now=%0d)",
                                      $time, u_dut.wb_wdat[15:0], u_dut.wb_wdat[5], u_dut.wb_wdat[4], u_dut.wb_wdat[6], eeprom_sdo_tap);
            end
            else if (iowr<80) begin
                $write("[%8t] IO wr %06x = %08x  ", $time, adr, u_dut.wb_wdat);
                if      (adr[23:0]==24'h140000) $display("(vbl ack)");
                else if (adr[23:12]==12'h163)   $display("(Ace RAM)");
                else if (adr[23:12]==12'h168)   $display("(palette DATA)");
                else if (adr[23:0]==24'h16c008) $display("(palette DMA)");
                else if (adr[23:12]==12'h170 || adr[23:12]==12'h178) $display("(sprite DATA)");
                else if (adr[23:16]==8'h18 || adr[23:16]==8'h19 || adr[23:16]==8'h1a ||
                         adr[23:16]==8'h1c || adr[23:16]==8'h1d || adr[23:16]==8'h1e) $display("(playfield)");
                else if (adr[23:12]==12'h200)   $display("(104 prot/sound)");
                else $display("(?)");
            end
        end
        if (snd_req) $display("[%8t] *** SOUND COMMAND latch=%02x ***", $time, snd_latch);

        // ---- 7a: snoop the NEW CPU video-write bus (cpu_we one-clk pulses) ----
        // Capture palette writes via cpu_we; at $finish compare to the wb-snoop vpal (must be identical).
        if (|u_dut.cpu_we) begin
            vidwr <= vidwr + 1;
            if (u_dut.cpu_addr>=24'h168000 && u_dut.cpu_addr<24'h16a000)
                vpal2[(u_dut.cpu_addr-24'h168000)>>2] <= u_dut.cpu_dout;
        end
    end

    // ---- exception / IRQ-mask / arch-PC diagnostics ----
    integer xcnt[0:7];                 // count each next_interrupt code as it is freshly decoded
    integer ii;
    reg [2:0]  nxti_d   = 3'd0;
    reg [23:0] apc_d    = 24'hffffff;
    reg        atrace_on= 0; integer ati=0;
    reg [25:0] atr [0:63];             // arch-PC (byte addr) loop trace, captured during the STALL (>45ms)
    reg [31:0] atr1[0:63];             // r1 at each step
    reg        irq_en_ever=0;          // did the boot ever UNMASK irq (imask==0)?
    // IRQ-mask write probe: does the boot ever TRY to enable IRQ (write mask=0)?
    wire       imask_wen = u_dut.u_arm.status_bits_irq_mask_wen;
    wire       imask_new = u_dut.u_arm.status_bits_irq_mask;
    integer    maskwr0=0, maskwr1=0;
    initial for (ii=0; ii<8; ii=ii+1) xcnt[ii]=0;
    always @(posedge clk) begin
        if (nxti != nxti_d) begin nxti_d <= nxti; if (nxti!=3'd0) xcnt[nxti] <= xcnt[nxti]+1; end
        if (!imask) irq_en_ever<=1;
        if (imask_wen) begin
            if (imask_new) maskwr1<=maskwr1+1;
            else begin maskwr0<=maskwr0+1; if (maskwr0<8) $display("[%8t] *** IRQ-mask cleared (enable) attempt #%0d, PC~%06x ***", $time, maskwr0, {apc,2'd0}); end
        end
        if ($time>41000000 && !atrace_on) atrace_on<=1;   // capture the lead-in to the post-init B-self hang
        if (apc != apc_d) begin
            apc_d <= apc;
            if (atrace_on && ati<64) begin atr[ati]<={apc,2'd0}; atr1[ati]<=ar1; ati<=ati+1; end
        end
    end

    // ---- late-phase BUS trace: dump accesses after 45 ms to identify the stall loop ----
    //  data_access=1 -> data read/write ; 0 -> instruction fetch.  Deduped on the access-commit edge.
    wire        dacc = u_dut.u_arm.data_access;
    reg         lateon=0, lacc_d=0; integer latek=0;
    reg [27:0]  lastbus=28'hfffffff;     // {we, dacc, adr[23:0]} of last logged access (dedup repeats)
    always @(posedge clk) begin
        if ($time>47450000 && !lateon) lateon<=1;     // ~47.5ms: capture the main loop / VBL-IRQ-handler render activity
        lacc_d <= (u_dut.wb_cyc & u_dut.wb_stb & u_dut.wb_ack);
        if (lateon && latek<150 && (u_dut.wb_cyc & u_dut.wb_stb & u_dut.wb_ack) && !lacc_d
            && {u_dut.wb_we,dacc,u_dut.wb_adr[23:0]} != lastbus) begin   // skip consecutive identical (collapses the B-self spin)
            latek<=latek+1; lastbus<={u_dut.wb_we,dacc,u_dut.wb_adr[23:0]};
            $display("[%8t] BUS %s %s adr=%06x dat=%08x", $time, u_dut.wb_we?"WR":"RD",
                     dacc?"data ":"FETCH", u_dut.wb_adr[23:0], u_dut.wb_we?u_dut.wb_wdat:u_dut.wb_rdat);
        end
    end

    // ==================================================================================
    // FREEZE-DETECTION instrumentation (M4 real-rate hypothesis).
    //   Watches the architectural byte-PC + VBL IRQ machinery. Emits:
    //    - a periodic HEARTBEAT (every 1ms sim time): bytePC, irq_l, vbl_irq seen, vbl acks,
    //      IRQ-taken count, imask, lr — so a frozen log shows a flat PC + frozen counters.
    //    - VBL-IRQ pulse + IRQ-taken + ack edge counters (separate, to expose a storm/drop).
    //    - a PC-STUCK detector: tracks the architectural-PC span seen in a sliding 0.5ms window;
    //      if the span stays <=64 bytes for >5ms while VBL pulses keep arriving (i.e. the CPU is
    //      pinned in a tiny loop across many frames), it prints a one-shot STALL banner with the
    //      loop window + what the loop is doing, and from then on logs the loop's bus accesses.
    // ==================================================================================
    reg  [25:0] hb_apc_byte;
    integer     vblpulse=0;                 // count of vbl_irq rising edges (frames offered)
    integer     irqtaken=0;                 // count of IRQ exception entries actually taken (nxti==3 fresh)
    reg         vblp_d=0;
    // sliding-window PC span (reset every 0.5ms)
    reg  [25:0] win_lo=26'h3ffffff, win_hi=0;
    reg  [25:0] last_span_lo=0, last_span_hi=0;
    integer     stuck_ms=0;                 // consecutive 0.5ms windows with a tiny PC span
    reg  [23:0] pcmax_prev=0;               // pcmax at the previous window (forward-progress check)
    integer     noprog=0;                   // consecutive windows with NO new pcmax high-water-mark
    integer     ramwr_prev=0;               // work-RAM write count at previous window (memset still running?)
    reg         stall_announced=0;
    integer     stall_buslog=0; reg stall_lacc_d=0; reg [27:0] stall_lastbus=28'hfffffff;
    always @(posedge clk) begin
        hb_apc_byte <= {apc,2'd0};
        // VBL pulse edge
        vblp_d <= vbl_irq;
        if (vbl_irq & ~vblp_d) vblpulse <= vblpulse+1;
        // IRQ actually taken (fresh decode of irq exception)
        if (nxti==3'd3 && nxti_d!=3'd3) irqtaken <= irqtaken+1;
        // sliding PC-span tracking
        if ({apc,2'd0} < win_lo) win_lo <= {apc,2'd0};
        if ({apc,2'd0} > win_hi) win_hi <= {apc,2'd0};
        // after the stall is announced, log the loop's distinct bus accesses
        if (stall_announced && stall_buslog<200) begin
            stall_lacc_d <= (u_dut.wb_cyc & u_dut.wb_stb & u_dut.wb_ack);
            if ((u_dut.wb_cyc & u_dut.wb_stb & u_dut.wb_ack) && !stall_lacc_d
                && {u_dut.wb_we,u_dut.u_arm.data_access,u_dut.wb_adr[23:0]} != stall_lastbus) begin
                stall_buslog<=stall_buslog+1; stall_lastbus<={u_dut.wb_we,u_dut.u_arm.data_access,u_dut.wb_adr[23:0]};
                $display("[%8t] STALL-BUS %s %s adr=%06x dat=%08x (PC=%06x irq_l=%0d imask=%0d)",
                    $time, u_dut.wb_we?"WR":"RD", u_dut.u_arm.data_access?"data ":"FETCH",
                    u_dut.wb_adr[23:0], u_dut.wb_we?u_dut.wb_wdat:u_dut.wb_rdat,
                    {apc,2'd0}, u_dut.irq_l, imask);
            end
        end
    end
    // heartbeat + stuck detector, on a 0.5ms sim-time grid (independent of cen_arm)
    integer hb=0;
    initial forever begin
        #500000;  // 0.5 ms
        $display("[HB %0dus] bytePC=%06x irq_l=%0d vbl=%0d vblpulse=%0d irqtaken=%0d vblack=%0d imask=%0d lr=%08x fetches=%0d PCmax=%06x",
                 $time/1000, {apc,2'd0}, u_dut.irq_l, vbl, vblpulse, irqtaken, vblack, imask, ar14, fetches, pcmax);
        // ---- TRUE-freeze eval (distinguish a real hang from the long but progressing memset) ----
        // A real freeze = the architectural PC is pinned in a TINY window AND the boot's furthest-
        // reached PC (pcmax) stops climbing AND we're already PAST the memset (advanced=1, PC>0xc04).
        // The memset trips "tiny window" too, but it (a) runs below 0xc04 and (b) keeps pcmax/ramwr
        // ticking — so it is excluded by the `advanced` gate and the no-progress requirement.
        if (pcmax == pcmax_prev) noprog <= noprog + 1; else noprog <= 0;
        if ((win_hi - win_lo) <= 26'd64 && advanced && (pcmax > 24'h000c04)) begin
            stuck_ms <= stuck_ms + 1;
            // declare freeze: tiny PC window AND pcmax frozen for >=10 windows (>=5ms) AND VBL frames arriving
            if (stuck_ms >= 10 && noprog >= 10 && !stall_announced && vblpulse > 4) begin
                stall_announced <= 1;
                $display("==================== *** PC STALL DETECTED *** ====================");
                $display("[HB %0dus] architectural PC pinned in [%06x..%06x] for >=%0d windows (>=%0dms); pcmax frozen at %06x for %0d windows",
                         $time/1000, win_lo, win_hi, stuck_ms, stuck_ms/2, pcmax, noprog);
                $display("  irq_l=%0d imask=%0d vblpulse=%0d irqtaken=%0d vblack=%0d lr=%08x r1=%08x r2=%08x",
                         u_dut.irq_l, imask, vblpulse, irqtaken, vblack, ar14, ar1, ar2);
                $display("  -> the loop window byte-PC = %06x..%06x  (disassemble this range)", win_lo, win_hi);
            end
        end else begin
            stuck_ms <= 0;   // PC moved out of a tiny window (or still in memset) -> not a freeze
        end
        last_span_lo <= win_lo; last_span_hi <= win_hi;
        pcmax_prev <= pcmax; ramwr_prev <= ramwr;
        win_lo <= {apc,2'd0}; win_hi <= {apc,2'd0};   // reset window
    end

    initial begin
        // VCD disabled for the long (50 ms) boot-advance run — re-enable for waveform debugging.
        // $dumpfile("tb_boot.vcd"); $dumpvars(1, tb_boot);
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- reset released; booting REAL nslasher ARM ROM ---");
        $display("    reset vector word[0] raw=%08x -> (decrypted shown via first fetch)", rawrom[0]);
    end
    // periodic VBlank (~200us "frame" in sim time). vbl is a LEVEL (active-high, ~10% duty =
    // the vblank window) feeding IN1[4]; vbl_irq is held 3 clks at vbl-rising so jtnslasher_main
    // latches irq_l cleanly (a 1-clk pulse races the clear). The boot enables IRQ itself during
    // init (execute_status_bits[27] -> 0) and then takes these VBL IRQs to run its frame loop.
    initial forever begin
        #180000 vbl = 1; vbl_irq = 1; repeat(3) @(posedge clk); vbl_irq = 0;  // enter vblank + clean IRQ pulse
        #20000  vbl = 0;                                                       // leave vblank (active display)
    end

    integer t;
`ifdef REALCEN
    localparam integer NSTEPS = 1400;   // up to 700ms sim time at the real ~1/6.78 pace (boot is ~7x slower)
`else
    localparam integer NSTEPS = 104;    // 52 ms: baseline full-speed run
`endif
    integer stall_grace=0;
    initial begin
        for (t=0; t<NSTEPS; t=t+1) begin
            #500000;  // 0.5 ms steps
            $display("[t=%0d] fetches=%0d  PC range %06x..%06x  RAMwr=%0d  IOwr=%0d",
                     t, fetches, pcmin, pcmax, ramwr, iowr);
            // early-exit: once the freeze is found, log ~10 more windows of the stuck loop, then stop.
            if (stall_announced) begin
                stall_grace = stall_grace + 1;
                if (stall_grace >= 10) begin
                    $display(">>> EARLY EXIT: PC stall confirmed; ending run to analyze. <<<");
                    t = NSTEPS;  // force loop end
                end
            end
            // early-exit: reached the title region (baseline endpoint ~0xacd3c) -> boot succeeded
            if (pcmax >= 24'h0acd00) begin
                $display(">>> EARLY EXIT: PC reached title region (pcmax=%06x) -> boot did NOT freeze. <<<", pcmax);
                t = NSTEPS;
            end
        end
        $display("==================== BOOT SUMMARY ====================");
        $display("total fetches=%0d  distinct PC range=%06x..%06x", fetches, pcmin, pcmax);
        $display("work-RAM writes=%0d   I/O writes=%0d", ramwr, iowr);
        $display("104 prot READS=%0d   VBL-IRQ acks (0x140000 wr)=%0d   EEPROM bitbang writes=%0d", protrd, vblack, eepwr);
        $display(">>> VIDEO-REGION CPU READS (0x120000-0x1FFFFF, our core returns 0) = %0d <<<", vidrd);
        $display("milestones: advanced(past memset)=%0d  vbl_ack=%0d  palette_data=%0d  palette_dma=%0d  sprite_data=%0d",
                 advanced, m_vbl, m_pal, m_dma, m_spr);
        // 7a: the new CPU video-write bus must carry the same palette data as the proven wb-snoop
        palmis=0; for (t=0;t<2048;t=t+1) if (vpal2[t]!==vpal[t]) palmis=palmis+1;
        $display("CPU video-bus (cpu_we): writes=%0d  palette mismatches vs wb-snoop=%0d  %s",
                 vidwr, palmis, (palmis==0 && vidwr>0) ? "(BUS OK)" : "(CHECK)");
        $display("exception decode counts: dabt=%0d firq=%0d irq=%0d adex=%0d iabt=%0d UNDEF=%0d swi=%0d",
                 xcnt[1],xcnt[2],xcnt[3],xcnt[4],xcnt[5],xcnt[6],xcnt[7]);
        $display("final IRQ mask (1=masked)=%0d   IRQ ever unmasked=%0d   irq_l pending now=%0d", imask, irq_en_ever, u_dut.irq_l);
        $display("IRQ-mask writes: to-0(enable)=%0d  to-1(disable)=%0d", maskwr0, maskwr1);
        $write("arch-PC trace (after 3ms) [bytePC(r1)]: ");
        for (t=0; t<ati; t=t+1) $write("%06x(%0x) ", atr[t], atr1[t]);
        $display("");
        $write("fetch PC trace (after 3ms): ");
        for (t=0; t<ti; t=t+1) $write("%03x ", tr[t]);
        $display("");
        if (fetches>1000 && pcmax>pcmin+24'h40)
            $display("a23 is running REAL decrypted code (PC advanced across %0d bytes)", pcmax-pcmin);
        else
            $display("a23 stalled/looping at low PC -- inspect (deco156? ISA gap? memory map?)");
        // ---- dump the captured final-frame VRAM for the M3b offline renderer ----
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_pal.hex",  vpal);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_pf1.hex",  vpf1);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_pf2.hex",  vpf2);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_pf3.hex",  vpf3);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_pf4.hex",  vpf4);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_spr0.hex", vspr0);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_spr1.hex", vspr1);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_ctl12.hex",vctl12);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_ctl34.hex",vctl34);
        $writememh("/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/vram_ace.hex",  vace);
        $display("VRAM dumped to ver/gfx/vram_*.hex (palette/pf1-4/spr0-1/ctl12-34/ace)");
        $finish;
    end
endmodule
