`timescale 1ns/1ps
// Night Slashers — SOUND-FLOOD hunt testbench.
// Hypothesis (2026-06-09): the cab's per-frame soundlatch re-fire is the reset preamble (0x50,
// which contains the ONLY soundlatch store @0xD4) re-entered via an ARM EXCEPTION: the vectors
// 0x04..0x1C branch to crash stubs at 0x20..0x4C (mvn lr,#0; str lr,[lr]) which FALL THROUGH to
// 0x50. (The old branch-scan missed this: fall-through, not a branch.) So any recurring a23
// fault (undef/adex/abort/swi) == one soundlatch re-fire. This tb boots the REAL ROM and watches:
//   * every fresh a23 exception decode (next_interrupt) with the architectural PC + lr
//   * every arch-PC entry into the stub region 0x20..0x4C  (the smoking gun)
//   * every snd_req pulse (sound commands; >1 == FLOOD REPRODUCED)
// Run long enough to cover boot + many frames of the attract loop.
module tb_flood;
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

    wire [23:0] apc   = u_dut.u_arm.u_execute.u_register_bank.r15;   // arch PC (word addr)
    wire [31:0] ar14  = u_dut.u_arm.u_execute.u_register_bank.r14;
    wire [ 2:0] nxti  = u_dut.u_arm.u_decode.next_interrupt;          // 1=dabt 2=firq 3=irq 4=adex 5=iabt 6=undef 7=swi

    always #10.416 clk = ~clk;   // 48 MHz

    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin
        rom_data <= rawrom[rom_addr[17:0]];
        rom_ok   <= rom_cs;
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

    // ---- exception monitor: print every fresh non-IRQ exception decode ----
    integer xcnt[0:7];
    integer ii;
    reg [2:0] nxti_d = 3'd0;
    initial for (ii=0; ii<8; ii=ii+1) xcnt[ii]=0;
    always @(posedge clk) begin
        if (nxti != nxti_d) begin
            nxti_d <= nxti;
            if (nxti!=3'd0) begin
                xcnt[nxti] <= xcnt[nxti]+1;
                if (nxti!=3'd3)   // 3 = normal IRQ; everything else is a FAULT
                    $display("[%0t] *** EXCEPTION code=%0d (%s) apc=%06x lr=%08x ***", $time, nxti,
                        nxti==3'd1?"DABT":nxti==3'd2?"FIRQ":nxti==3'd4?"ADEX":nxti==3'd5?"IABT":
                        nxti==3'd6?"UNDEF":nxti==3'd7?"SWI":"?", {apc,2'd0}, ar14);
            end
        end
    end

    // ---- stub-region entry monitor (arch PC lands in 0x20..0x4C = vector crash stubs) ----
    reg [23:0] apc_d = 24'hffffff;
    integer stubhits = 0;
    // rolling arch-PC ring (distinct PCs); dumped at the first fault = the trail INTO the wild jump
    reg [25:0] ring [0:127];
    integer    rp = 0, ri;
    integer    faults_seen = 0;
    always @(posedge clk) begin
        if (apc != apc_d) begin
            apc_d <= apc;
            ring[rp&127] <= {apc,2'd0};
            rp <= rp + 1;
            if ({apc,2'd0} >= 26'h20 && {apc,2'd0} < 26'h50) begin
                stubhits <= stubhits + 1;
                $display("[%0t] *** VECTOR-STUB ENTRY: bytePC=%06x (falls through to 0x50!) lr=%08x ***",
                         $time, {apc,2'd0}, ar14);
            end
        end
        if (nxti != nxti_d && nxti != 3'd0 && nxti != 3'd3 && faults_seen < 3) begin
            faults_seen <= faults_seen + 1;
            $display("---- arch-PC trail into fault #%0d (oldest..newest): ----", faults_seen+1);
            for (ri = 0; ri < 128; ri = ri + 1)
                $write("%06x ", ring[(rp+ri)&127]);
            $display("");
        end
    end

    // ---- sound command log ----
    integer sndcnt = 0;
    always @(posedge clk) if (snd_req) begin
        sndcnt <= sndcnt + 1;
        $display("[%0t] *** SOUND CMD #%0d latch=%02x (apc=%06x) ***", $time, sndcnt+1, snd_latch, {apc,2'd0});
    end

    // ---- frame generator: ~200us frames, 10% vblank ----
    initial forever begin
        #180000 vbl = 1; vbl_irq = 1; repeat(3) @(posedge clk); vbl_irq = 0;
        #20000  vbl = 0;
    end

    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- tb_flood: booting REAL nslashers ROM, hunting the soundlatch flood ---");
    end

    // run: 0.5ms heartbeat steps; default 600 steps = 300 ms (~1500 sim frames)
    integer t;
    integer NSTEPS;
    reg [23:0] pcmax = 0;
    always @(posedge clk) if (rom_cs && pc[23:0] > pcmax) pcmax <= pc[23:0];
    initial begin
        if (!$value$plusargs("steps=%d", NSTEPS)) NSTEPS = 600;
        for (t=0; t<NSTEPS; t=t+1) begin
            #500000;
            if (t%20==0) $display("[HB t=%0d/%0d] apc=%06x pcmax=%06x snd=%0d stubs=%0d dabt=%0d adex=%0d iabt=%0d undef=%0d swi=%0d irq=%0d",
                t, NSTEPS, {apc,2'd0}, pcmax, sndcnt, stubhits, xcnt[1],xcnt[4],xcnt[5],xcnt[6],xcnt[7],xcnt[3]);
        end
        $display("==================== FLOOD HUNT SUMMARY ====================");
        $display("sound commands = %0d   vector-stub entries = %0d", sndcnt, stubhits);
        $display("exceptions: dabt=%0d firq=%0d irq=%0d adex=%0d iabt=%0d undef=%0d swi=%0d",
                 xcnt[1],xcnt[2],xcnt[3],xcnt[4],xcnt[5],xcnt[6],xcnt[7]);
        if (sndcnt > 1) $display(">>> FLOOD REPRODUCED IN SIM (%0d sound cmds) <<<", sndcnt);
        else            $display(">>> no flood in this run (1 boot sound cmd is golden) <<<");
        $finish;
    end
endmodule
