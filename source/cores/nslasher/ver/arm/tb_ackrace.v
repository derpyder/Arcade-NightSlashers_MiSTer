`timescale 1ns/1ps
// tb_ackrace.v — CANDIDATE 1 ack-race probe.
// Drives jtnslasher_main's a23-facing wishbone bus DIRECTLY (a23 held in reset, signals forced),
// exactly like tb_romcache. Asserts a VBL IRQ (vbl_irq pulse) so irq_l latches high, then performs
// a STR to 0x140000 (the vbl ack) with the WB strobe raised at EVERY possible cen_arm phase.
// Verifies: does irq_l clear on the 0x140000 write regardless of where cen_arm lands?
//   - "single-clk WB write, NOT held until cen_arm" model -> reveals whether the gate misses.
//   - "WB write HELD until write_ack (real a23 behavior)" model -> reveals the real-HW outcome.
module tb_ackrace;
    localparam real CLK_NS = 20.8333;
    reg clk=0, rst=1; always #(CLK_NS/2.0) clk=~clk;

    // cen_arm frac accumulator (same as real)
    localparam [16:0] FC_N=17'd7753, FC_M=17'd52559;
    reg [16:0] fc_cnt=0; wire [16:0] fc_next=fc_cnt+FC_N; wire fc_over=fc_next>=FC_M;
    reg cen_arm=0;
    always @(posedge clk) begin
        cen_arm<=0;
        if(fc_cnt>=(FC_M+FC_N)) fc_cnt<=0;
        else if(fc_over) begin fc_cnt<=fc_next-FC_M; cen_arm<=1; end
        else fc_cnt<=fc_next;
    end

    // ROM/RAM stubs (unused here, but main needs them tied)
    wire [21:0] rom_addr; wire rom_cs; reg [31:0] rom_data=0; reg rom_ok=0;
    wire [16:2] ram_addr; wire ram_cs; wire [3:0] ram_we; wire [31:0] ram_dout;
    reg [31:0] ram_data=0; reg ram_ok=0;
    always @(posedge clk) begin rom_ok<=rom_cs; ram_ok<=ram_cs; end

    reg vbl=0, vbl_irq=0; wire vbl_ack;
    wire [7:0] snd_latch; wire snd_req;
    wire [23:0] cpu_addr; wire [31:0] cpu_dout; wire [3:0] cpu_we; wire [1:0] pri;
    wire [31:0] dbg_pc,dbg_romdec; wire [19:0] dbg_pcmax,dbg_pcnow; wire [23:0] dbg_poll_a;
    wire [31:0] dbg_poll_d; wire [15:0] dbg_virq_cnt,dbg_irq_cnt; wire [23:0] dbg_vid_a;
    wire [15:0] dbg_vidrd_cnt; wire [31:0] dbg_ctl; wire [15:0] dbg_vidwr_cnt,dbg_vidwr_d,dbg_sndwr_cnt;
    wire [23:0] dbg_vidwr_a; wire [15:0] dbg_pfnz_cnt,dbg_pfnz_d; wire [23:0] dbg_pfnz_a,dbg_anynz_a;
    wire [15:0] dbg_pal_cnt,dbg_pfbg_cnt,dbg_ctl_cnt,dbg_ctl12_5,dbg_ctl34_5;

    jtnslasher_main u_dut(
        .rst(rst), .clk(clk), .cen_arm(cen_arm),
        .in0(16'hffff), .in1(16'hffff), .vbl(vbl), .vbl_irq(vbl_irq), .vbl_ack(vbl_ack),
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

    wire irq_l = u_dut.irq_l;

    // Force the a23 wishbone-master nets (a23 kept in reset via rst)
    reg fwb_cyc=0, fwb_stb=0, fwb_we=0; reg [31:0] fwb_adr=0, fwb_wdat=0; reg [3:0] fwb_sel=0;
    reg drive=0;
    always @(*) if(drive) begin
        force u_dut.wb_cyc = fwb_cyc; force u_dut.wb_stb = fwb_stb; force u_dut.wb_we = fwb_we;
        force u_dut.wb_adr = fwb_adr; force u_dut.wb_wdat = fwb_wdat; force u_dut.wb_sel = fwb_sel;
    end else begin
        release u_dut.wb_cyc; release u_dut.wb_stb; release u_dut.wb_we;
        release u_dut.wb_adr; release u_dut.wb_wdat; release u_dut.wb_sel;
    end

    integer phase, missed=0, cleared=0;
    task do_vbl_ack_write(input integer holdmode);
        // holdmode=0: raise stb for exactly 1 clk (single-clk WB write)
        // holdmode=1: HOLD stb until cen_arm pulses (real a23: write_ack gates instruction retire)
        begin
            // 1) assert IRQ
            @(posedge clk); vbl_irq<=1; vbl<=1; @(posedge clk); vbl_irq<=0;
            // wait a couple clks; irq_l should be high
            repeat(3) @(posedge clk);
            if(!irq_l) $display("  [phase %0d] WARN irq_l not set before ack", phase);
            // 2) issue 0x140000 write
            fwb_adr<=32'h140000; fwb_wdat<=32'h0; fwb_sel<=4'hf; fwb_we<=1; fwb_cyc<=1; fwb_stb<=1;
            @(posedge clk);
            if(holdmode==0) begin
                // single clk then drop (mimics a WB master that does NOT hold across cen)
                fwb_stb<=0; fwb_cyc<=0; fwb_we<=0;
                @(posedge clk);
            end else begin
                // hold until a cen_arm pulse passes while stb&ack asserted, +1 clk margin
                while(!cen_arm) @(posedge clk);
                @(posedge clk);                 // let the registered clear take effect
                fwb_stb<=0; fwb_cyc<=0; fwb_we<=0;
                @(posedge clk);
            end
            // 3) check irq_l
            repeat(2) @(posedge clk);
            if(irq_l) begin missed=missed+1;  $display("  [phase %0d] holdmode=%0d -> irq_l STILL SET (ack MISSED)", phase, holdmode); end
            else      begin cleared=cleared+1; end
        end
    endtask

    integer k;
    initial begin
        rst=1; drive=0; repeat(20)@(posedge clk);
        rst=0; drive=1; repeat(5)@(posedge clk);

        $display("=== MODE 0: single-clk WB write (stb high 1 clk, NOT held) across cen phases ===");
        missed=0; cleared=0;
        for(phase=0; phase<14; phase=phase+1) begin
            // nudge alignment: insert `phase` filler clks so the write lands at a different cen offset
            for(k=0;k<phase;k=k+1) @(posedge clk);
            do_vbl_ack_write(0);
            repeat(4) @(posedge clk);
        end
        $display("MODE 0 RESULT: cleared=%0d  MISSED=%0d  (of %0d trials)", cleared, missed, cleared+missed);

        $display("=== MODE 1: WB write HELD until cen_arm (real a23 retire model) across cen phases ===");
        missed=0; cleared=0;
        for(phase=0; phase<14; phase=phase+1) begin
            for(k=0;k<phase;k=k+1) @(posedge clk);
            do_vbl_ack_write(1);
            repeat(4) @(posedge clk);
        end
        $display("MODE 1 RESULT: cleared=%0d  MISSED=%0d  (of %0d trials)", cleared, missed, cleared+missed);
        $finish;
    end
endmodule
