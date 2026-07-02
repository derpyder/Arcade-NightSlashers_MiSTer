`timescale 1ns/1ps
// ============================================================================
//  tb_cpi.v  — Amber a23 effective CPI / MIPS measurement (CANDIDATE 3)
// ----------------------------------------------------------------------------
//  Boots the REAL decrypted Night Slashers ARM ROM on the REAL a23_core through
//  jtnslasher_main, with IDEAL 1-clk memory (models the nf6 ROM-cache HIT case:
//  rom_ok next clk after rom_cs; ram_ok next clk after ram_cs). This is the
//  best-case throughput the a23 can achieve at 7.0805 MHz.
//
//  cen_arm pacing: REALCEN = exact jtframe_gated_cen NUM=7753/DEN=52559 @48MHz
//  (the real 7.0805 MHz). The a23 i_system_rdy = cen_arm freezes the pipeline
//  except on cen ticks, so #cen ticks == #a23 pipeline advances.
//
//  MEASURE over a long real-code window:
//    cen_ticks       = a23 pipeline advances (== effective a23 clocks)
//    instr_retired   = ROM fetch acks (a23 internal cache is OFF, so EVERY
//                      instruction is fetched exactly once over the wishbone;
//                      rom_ack pulses once per fetch -> exact instruction count
//                      for straight-line code; branch refills add a couple
//                      extra fetches but those ARE real cycles the a23 pays).
//    data_acks       = RAM + I/O read/write acks (LDR/STR memory cycles)
//
//  CPI  = cen_ticks / instr_retired        (a23 ticks per fetched word)
//  MIPS = 7.0805 / CPI
//
//  Also independently verifies the cen_arm average frequency.
// ============================================================================
module tb_cpi;
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

    always #10.41666667 clk = ~clk;   // 48 MHz master

    // -------- cen_arm: exact real-hardware fractional pace 7.0805 MHz --------
    localparam integer CEN_NUM = 7753;
    localparam integer CEN_DEN = 52559;
    integer cen_acc = 0;
    integer cen_pulses = 0;     // independent cen-rate check
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

    // -------- IDEAL memory (nf6 cache-HIT model: 1-clk ack) --------
    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin
        rom_data <= rawrom[rom_addr[17:0]];
        rom_ok   <= rom_cs;     // 1-clk latency -> models a guaranteed nf6 cache HIT
    end

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

    // ---------------- a23 internal taps (hierarchical) ----------------
    // wishbone master signals (already exposed on jtnslasher_main internals)
    wire wb_cyc = u_dut.wb_cyc;
    wire wb_stb = u_dut.wb_stb;
    wire wb_we  = u_dut.wb_we;
    wire wb_ack = u_dut.wb_ack;
    wire is_rom = u_dut.is_rom;
    wire is_ram = u_dut.is_ram;
    wire is_prot= u_dut.is_prot;
    wire acc    = wb_cyc & wb_stb;

    // decode FSM control_state (instruction issue tracking)
    wire [4:0] cstate = u_dut.u_arm.u_decode.control_state;
    wire iexec        = u_dut.u_arm.u_decode.instruction_execute;
    wire ivalid       = u_dut.u_arm.u_decode.instruction_valid;
    localparam EXECUTE=5'd4, PRE_FETCH_EXEC=5'd5;
    // CANONICAL retirement: the decompiler latches a new instruction into execute
    // exactly when (!fetch_stall && instruction_valid). fetch_stall is asserted
    // whenever cen_arm is low, so this is naturally cen-paced.
    wire fetch_stall  = u_dut.u_arm.fetch_stall;
    wire instr_accept = (~fetch_stall) & ivalid;     // 1 retired instruction this clk

    // ---------------- measurement counters ----------------
    integer clk_cnt=0, cen_cnt=0;
    integer rom_fetch_ack=0;      // == instructions fetched (a23 cache off => 1 fetch/instr)
    integer data_ack=0;          // RAM/IO read+write acks (memory cycles)
    integer wr_ack=0, rd_ack=0;
    integer instr_issue=0;       // # times decode enters EXECUTE/PRE_FETCH_EXEC (alt. retire metric)
    integer instr_retire=0;      // CANONICAL: !fetch_stall & instruction_valid (one per retired instr)
    reg [4:0] cstate_d=0;
    reg [23:0] apc, apc_start, apc_end;
    reg started=0;

    wire [23:0] apc_tap = u_dut.u_arm.u_execute.u_register_bank.r15;

    // count ONLY on cen ticks (the a23 only advances then) — but wb_ack is a clk-level
    // signal; the IDEAL memory acks the clk after cs, which may not align to a cen tick.
    // The a23 only SAMPLES wb_ack on cen ticks (fetch_stall holds otherwise). So count an
    // ack as "consumed" on the cen tick where acc&wb_ack is true.
    always @(posedge clk) begin
        if( rst ) begin
            clk_cnt<=0; cen_cnt<=0; rom_fetch_ack<=0; data_ack<=0;
            wr_ack<=0; rd_ack<=0; instr_issue<=0; instr_retire<=0; cstate_d<=0; started<=0;
        end else begin
            clk_cnt <= clk_cnt + 1;
            if( cen_arm ) cen_cnt <= cen_cnt + 1;
            // canonical retirement (counts on the clk it happens; gated by fetch_stall
            // which is low only on a cen tick, so it is inherently cen-paced)
            if( instr_accept ) instr_retire <= instr_retire + 1;
            // count bus acks that the a23 actually consumes (on a cen tick)
            if( cen_arm & acc & wb_ack ) begin
                if( is_rom )                      rom_fetch_ack <= rom_fetch_ack + 1;
                else begin
                    data_ack <= data_ack + 1;
                    if( wb_we ) wr_ack <= wr_ack + 1; else rd_ack <= rd_ack + 1;
                end
            end
            // decode-FSM instruction issue edge (entering an execute state)
            if( cen_arm ) begin
                cstate_d <= cstate;
                if( (cstate==EXECUTE || cstate==PRE_FETCH_EXEC) &&
                    !(cstate_d==EXECUTE || cstate_d==PRE_FETCH_EXEC) )
                    instr_issue <= instr_issue + 1;
            end
        end
    end

    // ---------------- VBL cadence (absolute time, ~60Hz) just to keep IRQs realistic ----------------
    // 16.67 ms/frame. Keeps the boot's IRQ path exercised so the mix includes IRQ entry/exit.
    initial begin
        vbl = 0; vbl_irq = 0;
        @(negedge rst);
        forever begin
            #16670000;             // 16.67 ms
            @(posedge clk); vbl_irq <= 1; vbl <= 1;
            @(posedge clk); vbl_irq <= 0;
            #1000000;              // ~1ms vblank
            @(posedge clk); vbl <= 0;
        end
    end

    // ---------------- run ----------------
    integer WARM_CLKS = 420000;    // ~8.75ms: past memset, into the 0x39xxx init game code
    integer MEAS_CLKS = 900000;    // ~18.75ms window of real ALU/branch/load/store game code
    integer t0_cen, t0_rom, t0_data, t0_clk, t0_issue, t0_retire;
    real cpi_fetch, cpi_issue, cpi_retire, mips_fetch, mips_issue, mips_retire, cen_hz;

    initial begin
        rst = 1;
        repeat(20) @(posedge clk);
        rst = 0;
        // warm up (let reset/init churn settle into real game code)
        repeat(WARM_CLKS) @(posedge clk);
        // snapshot
        t0_clk   = clk_cnt;
        t0_cen   = cen_cnt;
        t0_rom   = rom_fetch_ack;
        t0_data  = data_ack;
        t0_issue = instr_issue;
        t0_retire= instr_retire;
        cen_pulses = 0;
        apc_start = apc_tap;
        // measure
        repeat(MEAS_CLKS) @(posedge clk);
        apc_end = apc_tap;

        // ---- report ----
        $display("==================================================================");
        $display(" Amber a23 CPI / MIPS measurement  (Night Slashers real boot code)");
        $display("==================================================================");
        $display(" measurement window:");
        $display("   clk cycles (48MHz)   = %0d", clk_cnt - t0_clk);
        $display("   cen_arm ticks        = %0d   (a23 pipeline advances)", cen_cnt - t0_cen);
        $display("   ROM fetch acks       = %0d   (fetched words, incl branch refill)", rom_fetch_ack - t0_rom);
        $display("   data acks (LDR/STR)  = %0d", data_ack - t0_data);
        $display("   INSTR RETIRED        = %0d   (CANONICAL: !fetch_stall & instr_valid)", instr_retire - t0_retire);
        $display("   decode EXEC issues   = %0d   (edge metric, undercounts)", instr_issue - t0_issue);
        $display("------------------------------------------------------------------");
        // cen rate cross-check
        cen_hz = (1.0*(cen_cnt - t0_cen)) / ((clk_cnt - t0_clk)*1.0/48000000.0);
        $display(" cen_arm measured freq  = %0.4f MHz   (target 7.0805)", cen_hz/1e6);
        $display(" cen/clk ratio          = %0.5f       (ideal %0.5f = NUM/DEN)",
                 (1.0*(cen_cnt-t0_cen))/(clk_cnt-t0_clk), 7753.0/52559.0);
        $display("------------------------------------------------------------------");
        if( (instr_retire - t0_retire) > 0 ) begin
            cpi_retire  = (1.0*(cen_cnt - t0_cen)) / (instr_retire - t0_retire);
            mips_retire = 7.0805 / cpi_retire;
            $display(" >>> CPI (cen ticks / RETIRED instr) = %0.3f   <<< CANONICAL", cpi_retire);
            $display(" >>> effective MIPS                  = %0.3f   <<<", mips_retire);
        end
        if( (rom_fetch_ack - t0_rom) > 0 ) begin
            cpi_fetch  = (1.0*(cen_cnt - t0_cen)) / (rom_fetch_ack - t0_rom);
            mips_fetch = 7.0805 / cpi_fetch;
            $display(" CPI (cen ticks / fetched word)   = %0.3f  (incl branch refills)", cpi_fetch);
            $display(" effective MIPS (fetch-based)     = %0.3f", mips_fetch);
        end
        $display("------------------------------------------------------------------");
        $display(" data accesses / retired instr = %0.3f",
                 1.0*(data_ack - t0_data)/((instr_retire - t0_retire)>0?(instr_retire - t0_retire):1));
        $display(" arch PC start=0x%06h end=0x%06h (byte 0x%06h..0x%06h)",
                 apc_start, apc_end, apc_start<<2, apc_end<<2);
        $display("==================================================================");
        $finish;
    end

    // safety timeout
    initial begin
        #120000000;   // 120 ms sim time hard cap
        $display("TIMEOUT");
        $finish;
    end
endmodule
