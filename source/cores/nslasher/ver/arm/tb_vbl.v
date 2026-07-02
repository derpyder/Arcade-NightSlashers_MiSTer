`timescale 1ns/1ps
// ============================================================================
//  tb_vbl.v  —  CANDIDATE 1: VBLANK-IRQ measurement (real cen_arm + real vbl rate)
// ----------------------------------------------------------------------------
//  Boots the REAL nslasher ROM on the REAL a23 inside the REAL jtnslasher_main,
//  paced by the REAL cen_arm (jtframe_frac_cen 7753/52559 @ 48MHz = 7.0805 MHz),
//  and drives vbl/vbl_irq at the REAL nslasher video rate derived from the actual
//  vtimer parameters (384 H x 264 V pxl_cen @ 6 MHz = 59.17 Hz).
//
//  This is the FIT/RATE test the existing sims (cen_arm=1, fake-fast frames) cannot do.
//  Measures:
//    1. vbl_irq period  -> Hz   (should be ~59)
//    2. dbg_irq_cnt / dbg_virq_cnt   (should be ~1.0; >>1 = ARM re-enters handler = spin)
//    3. ack-race: does the 0x140000 (is_vbl) write's wr&wb_ack pulse EVER land while
//       cen_arm==0 ? If so, irq_l is NOT cleared -> level held -> ARM re-IRQs (spin).
//    4. irq_l held-high duration distribution (frames the level is stuck asserted).
// ============================================================================
module tb_vbl;
    localparam real CLK_NS = 20.8333;     // 48 MHz

    reg clk=0, rst=1;
    always #(CLK_NS/2.0) clk = ~clk;

    // ---- REAL cen_arm: fractional accumulator EXACTLY as jtframe_frac_cen does for W=1 ----
    //   step=n=7753, lim=m=52559; cen fires the clk the accumulator overflows (next>=lim),
    //   carrying the remainder (next-lim). Average rate = 48MHz * 7753/52559 = 7.0805 MHz.
    localparam [16:0] FC_N=17'd7753, FC_M=17'd52559;
    reg  [16:0] fc_cnt=0;
    wire [16:0] fc_next = fc_cnt + FC_N;
    wire        fc_over = fc_next >= FC_M;
    reg         cen_arm = 0;
    always @(posedge clk) begin
        cen_arm <= 1'b0;
        if(fc_cnt >= (FC_M+FC_N)) fc_cnt <= 0;        // safety restart (mirrors frac_cen)
        else if(fc_over) begin fc_cnt <= fc_next-FC_M; cen_arm <= 1'b1; end
        else fc_cnt <= fc_next;
    end

    // ---- REAL pxl_cen = 6 MHz = 48/8 ----  (JTFRAME_PXLCLK=6)
    reg [2:0] pxdiv=0; reg pxl_cen=0;
    always @(posedge clk) begin pxdiv<=pxdiv+3'd1; pxl_cen<=(pxdiv==3'd7); end

    // ---- REAL nslasher V/H timing model (matches jtnslasher_game vtimer params) ----
    //   HCNT_END=383 -> 384 H counts/line ; VCNT_END=263 -> 264 lines/frame.
    //   VB_START=240 (LVBL drops at line 240 = vblank start).
    localparam [8:0] HTOTAL=9'd384, VTOTAL=9'd264, VB_START=9'd240;
    reg [8:0] hcnt=0, vcnt=0;
    reg LVBL=1;
    always @(posedge clk) if(pxl_cen) begin
        if(hcnt==HTOTAL-1) begin
            hcnt<=0;
            if(vcnt==VTOTAL-1) vcnt<=0; else vcnt<=vcnt+9'd1;
        end else hcnt<=hcnt+9'd1;
        // LVBL active-low: 1 during active (vcnt<240), 0 during vblank (vcnt>=240)
        LVBL <= (vcnt < VB_START);
    end
    // vbl level + 1-clk irq pulse on LVBL falling edge (EXACT copy of game.v L48-49)
    reg LVBLl; wire vbl = ~LVBL; reg vbl_irq;
    always @(posedge clk) begin LVBLl<=LVBL; vbl_irq<=LVBLl & ~LVBL; end

    // ---- ROM (raw, deco156-enc, HW byte-rev orientation) — 1-clk behavioral, like tb_game ----
    wire [21:0] rom_addr; wire rom_cs; reg [31:0] rom_data; reg rom_ok=0;
    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin rom_data<=rawrom[rom_addr[17:0]]; rom_ok<=rom_cs; end

    // ---- work RAM (BRAM behavioral, 1-clk) ----
    wire [16:2] ram_addr; wire ram_cs; wire [3:0] ram_we; wire [31:0] ram_dout;
    reg [31:0] ram_data; reg ram_ok=0;
    reg [31:0] wram [0:32767]; integer j;
    initial for(j=0;j<32768;j=j+1) wram[j]=0;
    always @(posedge clk) begin
        ram_ok<=ram_cs;
        if(ram_cs) begin
            if(ram_we[0]) wram[ram_addr][ 7: 0]<=ram_dout[ 7: 0];
            if(ram_we[1]) wram[ram_addr][15: 8]<=ram_dout[15: 8];
            if(ram_we[2]) wram[ram_addr][23:16]<=ram_dout[23:16];
            if(ram_we[3]) wram[ram_addr][31:24]<=ram_dout[31:24];
            ram_data<=wram[ram_addr];
        end
    end

    // ---- DUT ----
    wire [15:0] in0=16'hffff, in1=16'hffff;
    wire vbl_ack; wire [7:0] snd_latch; wire snd_req;
    wire [23:0] cpu_addr; wire [31:0] cpu_dout; wire [3:0] cpu_we; wire [1:0] pri;
    wire [31:0] dbg_pc, dbg_romdec; wire [19:0] dbg_pcmax,dbg_pcnow;
    wire [23:0] dbg_poll_a; wire [31:0] dbg_poll_d;
    wire [15:0] dbg_virq_cnt, dbg_irq_cnt;
    wire [23:0] dbg_vid_a; wire [15:0] dbg_vidrd_cnt; wire [31:0] dbg_ctl;
    wire [15:0] dbg_vidwr_cnt,dbg_vidwr_d,dbg_sndwr_cnt; wire [23:0] dbg_vidwr_a;
    wire [15:0] dbg_pfnz_cnt,dbg_pfnz_d; wire [23:0] dbg_pfnz_a,dbg_anynz_a;
    wire [15:0] dbg_pal_cnt,dbg_pfbg_cnt,dbg_ctl_cnt,dbg_ctl12_5,dbg_ctl34_5;

    jtnslasher_main u_dut(
        .rst(rst), .clk(clk), .cen_arm(cen_arm),
        .in0(in0), .in1(in1), .vbl(vbl), .vbl_irq(vbl_irq), .vbl_ack(vbl_ack),
        .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_data(rom_data), .rom_ok(rom_ok),
        .ram_addr(ram_addr), .ram_cs(ram_cs), .ram_we(ram_we), .ram_dout(ram_dout),
        .ram_data(ram_data), .ram_ok(ram_ok),
        .snd_latch(snd_latch), .snd_req(snd_req),
        .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_we(cpu_we), .pri(pri),
        .dbg_pc_addr(dbg_pc), .dbg_romdec(dbg_romdec),
        .dbg_pcmax(dbg_pcmax), .dbg_pcnow(dbg_pcnow), .dbg_poll_a(dbg_poll_a), .dbg_poll_d(dbg_poll_d),
        .dbg_virq_cnt(dbg_virq_cnt), .dbg_irq_cnt(dbg_irq_cnt),
        .dbg_vid_a(dbg_vid_a), .dbg_vidrd_cnt(dbg_vidrd_cnt), .dbg_ctl(dbg_ctl),
        .dbg_vidwr_cnt(dbg_vidwr_cnt), .dbg_vidwr_a(dbg_vidwr_a), .dbg_vidwr_d(dbg_vidwr_d), .dbg_sndwr_cnt(dbg_sndwr_cnt),
        .dbg_pfnz_cnt(dbg_pfnz_cnt), .dbg_pfnz_a(dbg_pfnz_a), .dbg_pfnz_d(dbg_pfnz_d), .dbg_anynz_a(dbg_anynz_a),
        .dbg_pal_cnt(dbg_pal_cnt), .dbg_pfbg_cnt(dbg_pfbg_cnt), .dbg_ctl_cnt(dbg_ctl_cnt),
        .dbg_ctl12_5(dbg_ctl12_5), .dbg_ctl34_5(dbg_ctl34_5) );

    // ---- internal taps ----
    wire irq_l   = u_dut.irq_l;
    wire is_vbl  = u_dut.is_vbl;
    wire wr_w    = u_dut.wr;
    wire ack_w   = u_dut.wb_ack;
    wire acc_w   = u_dut.acc;

    // ============================================================
    //  MEASUREMENTS
    // ============================================================
    // (1) vbl_irq period (in clks) -> Hz
    real t_last_virq=0, t_now;
    integer virq_seen=0; real virq_period_sum=0; real virq_period_min=1e30, virq_period_max=0;
    always @(posedge clk) if(vbl_irq) begin
        t_now=$realtime;
        if(virq_seen>0) begin
            virq_period_sum=virq_period_sum+(t_now-t_last_virq);
            if((t_now-t_last_virq)<virq_period_min) virq_period_min=t_now-t_last_virq;
            if((t_now-t_last_virq)>virq_period_max) virq_period_max=t_now-t_last_virq;
        end
        t_last_virq=t_now; virq_seen=virq_seen+1;
    end

    // (3) ACK-RACE: 0x140000 write transaction completes (is_vbl & wr & wb_ack).
    //     Count how many such completions land while cen_arm==1 (clears irq) vs cen_arm==0 (MISSED).
    integer vblwr_total=0, vblwr_cenhi=0, vblwr_cenlo=0;
    reg vblwr_d=0;
    wire vblwr_now = acc_w & wr_w & ack_w & is_vbl;
    always @(posedge clk) begin
        // count each distinct completion edge (the transaction holds 1 clk, but guard anyway)
        if(vblwr_now & ~vblwr_d) begin
            vblwr_total<=vblwr_total+1;
            if(cen_arm) vblwr_cenhi<=vblwr_cenhi+1; else vblwr_cenlo<=vblwr_cenlo+1;
        end
        vblwr_d<=vblwr_now;
    end

    // (4) irq_l held-high run length (in vbl_irq pulses): if irq_l is still high when the
    //     NEXT vbl_irq arrives, the ARM never acked the previous frame -> spin candidate.
    integer irq_high_at_next_virq=0;
    always @(posedge clk) if(vbl_irq) begin
        if(irq_l) irq_high_at_next_virq=irq_high_at_next_virq+1; // was set, not yet cleared
    end

    // (5) how long (in clks) irq_l stays high each assertion
    integer irq_rise_t=0; integer irq_dur_max=0, irq_dur_sum=0, irq_assert_cnt=0;
    reg irq_l_d=0;
    always @(posedge clk) begin
        if(irq_l & ~irq_l_d) irq_rise_t=$time;            // rose
        if(~irq_l & irq_l_d) begin                        // fell (acked)
            irq_dur_sum=irq_dur_sum+($time-irq_rise_t);
            if(($time-irq_rise_t)>irq_dur_max) irq_dur_max=$time-irq_rise_t;
            irq_assert_cnt=irq_assert_cnt+1;
        end
        irq_l_d<=irq_l;
    end

    // boot progress
    reg [23:0] pcmax=0;
    always @(posedge clk) if(rom_cs && dbg_pc[23:0]>pcmax) pcmax<=dbg_pc[23:0];

    integer t; integer NSTEPS;
    initial begin
        rst=1; repeat(200)@(posedge clk); rst=0;
        $display("--- tb_vbl: real cen_arm (7753/52559) + real vbl rate, booting nslasher ---");
        if(!$value$plusargs("steps=%d",NSTEPS)) NSTEPS=300;   // 300 * 0.5ms = 150 ms
        for(t=0;t<NSTEPS;t=t+1) begin
            #500000;
            if(t%20==0)
                $display("[t=%0d/%0d] pcmax=%06x virq=%0d irq=%0d ratio=%.3f  vblwr(tot=%0d hi=%0d LO=%0d) irqStuckAtNextV=%0d",
                    t,NSTEPS,pcmax,dbg_virq_cnt,dbg_irq_cnt,
                    dbg_virq_cnt? (1.0*dbg_irq_cnt)/dbg_virq_cnt : 0.0,
                    vblwr_total,vblwr_cenhi,vblwr_cenlo,irq_high_at_next_virq);
        end
        $display("==================== VBL-IRQ MEASUREMENT SUMMARY ====================");
        $display("boot pcmax = %06x", pcmax);
        if(virq_seen>1) begin
            $display("vbl_irq pulses=%0d  avg period=%.1f ns (%.2f Hz)  min=%.0f max=%.0f ns",
                virq_seen, virq_period_sum/(virq_seen-1),
                1e9/(virq_period_sum/(virq_seen-1)), virq_period_min, virq_period_max);
        end
        $display("dbg_virq_cnt=%0d  dbg_irq_cnt=%0d  ratio(irq/virq)=%.4f",
            dbg_virq_cnt, dbg_irq_cnt, dbg_virq_cnt? (1.0*dbg_irq_cnt)/dbg_virq_cnt : 0.0);
        $display("0x140000 ack writes: total=%0d  while cen_arm=1 (CLEARED)=%0d  while cen_arm=0 (MISSED)=%0d",
            vblwr_total, vblwr_cenhi, vblwr_cenlo);
        $display("irq_l assertions=%0d  avg-high=%.0f ns  max-high=%.0f ns",
            irq_assert_cnt, irq_assert_cnt? (1.0*irq_dur_sum)/irq_assert_cnt:0.0, 1.0*irq_dur_max);
        $display("irq_l STILL HIGH when next vbl_irq arrived (= un-acked frame, spin) = %0d times", irq_high_at_next_virq);
        $finish;
    end
endmodule
