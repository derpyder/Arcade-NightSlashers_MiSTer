`timescale 1ns/1ps
// Night Slashers — Z80 SOUND-SUBSYSTEM golden-protocol sim (audio "loops forever" hunt).
// Boots jtnslasher_snd (Z80 + jt51 + 2x jt6295) standalone with the REAL sndprg ROM, sends the
// boot soundlatch cmd 0x01, and logs the sound-bus conversation for diff against the MAME golden
// (mame-dump/snd_golden/SND_GOLDEN_REPORT.md):
//   GOLDEN: Z80 reads D000 exactly TWICE (0x00 then 0x01); ~5 OKI writes all 0x78 (stop);
//           YM init burst then ONLY timer-A reloads (regs 0x12/0x14); then IDLE.
// Also logs every Z80 IO-space READ (the deco32 nslasher_io_sound full-ROM window) — the upper
// 32 KB of the sound ROM is ONLY reachable this way; the old RTL returned 8'hff for those.
module tb_sndsub;
    reg clk=0, rst=1;
    always #10.416 clk = ~clk;     // 48 MHz

    // cens (as tb_snd_golden): cen_fm ~3.7MHz, cen_fm2 = /2, OKIs
    reg [5:0] fmdiv=0; reg cen_fm=0, cen_fm2=0; reg ff2=0;
    always @(posedge clk) begin
        fmdiv<=fmdiv+1'd1; cen_fm<=(fmdiv==6'd12);
        if(fmdiv==6'd12) begin fmdiv<=0; ff2<=~ff2; cen_fm2<=ff2; end
    end
    reg [5:0] okdiv=0; reg cen_oki1=0, cen_oki2=0;
    always @(posedge clk) begin okdiv<=okdiv+1'd1;
        cen_oki1<=(okdiv==6'd47); cen_oki2<=(okdiv[4:0]==5'd23); if(okdiv==6'd47) okdiv<=0; end

    // ---- DUT ----
    reg         snd_req=0;  reg [7:0] snd_latch=0;
    wire [15:0] rom_addr;   wire rom_cs;   reg [7:0] rom_data;  reg rom_ok=0;
    wire [18:0] oki1_addr, oki2_addr;  wire oki1_cs, oki2_cs;
    reg  [ 7:0] oki1_data, oki2_data;  reg oki1_ok=0, oki2_ok=0;
    wire signed [15:0] fm_l, fm_r;  wire signed [13:0] pcm1, pcm2;

    jtnslasher_snd u_dut(
        .rst(rst), .clk(clk),
        .cen_fm(cen_fm), .cen_fm2(cen_fm2), .cen_oki1(cen_oki1), .cen_oki2(cen_oki2),
        .snd_req(snd_req), .snd_latch(snd_latch),
        .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_data(rom_data), .rom_ok(rom_ok),
        .oki1_addr(oki1_addr), .oki1_cs(oki1_cs), .oki1_data(oki1_data), .oki1_ok(oki1_ok),
        .oki2_addr(oki2_addr), .oki2_cs(oki2_cs), .oki2_data(oki2_data), .oki2_ok(oki2_ok),
        .fm_l(fm_l), .fm_r(fm_r), .pcm1(pcm1), .pcm2(pcm2) );

    // ---- behavioral ROMs (1-clk ok) ----
    reg [7:0] sndrom [0:65535];
    reg [7:0] okirom1[0:524287];
    reg [7:0] okirom2[0:524287];
    initial begin
        $readmemh("snd_rom.hex",  sndrom);
        $readmemh("oki1_rom.hex", okirom1);
        $readmemh("oki2_rom.hex", okirom2);
    end
    always @(posedge clk) begin
        rom_data <= sndrom[rom_addr];   rom_ok  <= rom_cs;
        oki1_data<= okirom1[oki1_addr]; oki1_ok <= oki1_cs;
        oki2_data<= okirom2[oki2_addr]; oki2_ok <= oki2_cs;
    end

    // ---- bus conversation logging ----
    integer d000_reads=0, oki1_wr=0, oki2_wr=0, ym_wr=0, ym_other=0, io_reads=0;
    reg lat_d=0, o1w_d=0, o2w_d=0, fmw_d=0, ior_d=0;
    reg [7:0] ym_reg=0;
    wire latch_rd = u_dut.latch_cs && !u_dut.rd_n;
    wire o1w = u_dut.oki1_io_cs && !u_dut.wr_n;
    wire o2w = u_dut.oki2_io_cs && !u_dut.wr_n;
    wire fmw = u_dut.fm_cs && !u_dut.wr_n;
    wire ior = u_dut.io_rom_rd;
    always @(posedge clk) begin
        lat_d<=latch_rd; o1w_d<=o1w; o2w_d<=o2w; fmw_d<=fmw; ior_d<=ior;
        if (latch_rd && !lat_d) begin
            d000_reads <= d000_reads+1;
            $display("[%0t] D000 read #%0d -> %02x", $time, d000_reads+1, u_dut.snd_latch);
        end
        if (o1w && !o1w_d) begin
            oki1_wr <= oki1_wr+1;
            $display("[%0t] OKI1 write %02x", $time, u_dut.cpu_dout);
        end
        if (o2w && !o2w_d) begin
            oki2_wr <= oki2_wr+1;
            $display("[%0t] OKI2 write %02x", $time, u_dut.cpu_dout);
        end
        if (fmw && !fmw_d) begin
            ym_wr <= ym_wr+1;
            if (!u_dut.A[0]) ym_reg <= u_dut.cpu_dout;
            else begin
                if (ym_reg!=8'h12 && ym_reg!=8'h14 && ym_wr>200)  // past init burst, non-timer regs
                    begin ym_other<=ym_other+1;
                    if (ym_other<30) $display("[%0t] YM post-init NON-TIMER write reg=%02x val=%02x", $time, ym_reg, u_dut.cpu_dout); end
            end
        end
        if (ior && !ior_d) begin
            io_reads <= io_reads+1;
            if (io_reads<40 || (io_reads%500)==0)
                $display("[%0t] IO-ROM read #%0d addr=%04x -> %02x", $time, io_reads+1, rom_addr, sndrom[rom_addr]);
        end
    end

    // ---- stimulus: boot, then cmd 0x01 at 3 ms ----
    initial begin
        rst=1; repeat(100) @(posedge clk); rst=0;
        $display("--- tb_sndsub: Z80 sound subsystem, real sndprg.17l ---");
        #3000000;
        snd_latch=8'h01; snd_req=1; @(posedge clk); @(posedge clk); snd_req=0;
        $display("[%0t] >>> soundlatch cmd 0x01 sent <<<", $time);
    end

    integer t;
    integer NSTEPS;
    initial begin
        if (!$value$plusargs("steps=%d", NSTEPS)) NSTEPS = 120;   // x 1ms
        for (t=0; t<NSTEPS; t=t+1) begin
            #1000000;
            if (t%10==0) $display("[HB %0dms] d000=%0d oki1w=%0d oki2w=%0d ymw=%0d ym_nonTimerPostInit=%0d ioRomReads=%0d zPC~%04x",
                t, d000_reads, oki1_wr, oki2_wr, ym_wr, ym_other, io_reads, u_dut.A);
        end
        $display("==================== SND SUBSYSTEM SUMMARY ====================");
        $display("D000 reads=%0d (golden 2)   OKI1 writes=%0d / OKI2 writes=%0d (golden 2/3, all 0x78)",
                 d000_reads, oki1_wr, oki2_wr);
        $display("YM writes=%0d   post-init non-timer YM writes=%0d (golden 0)", ym_wr, ym_other);
        $display("IO-ROM-window reads=%0d  (THE deco32 quirk; old RTL returned FF for all of these)", io_reads);
        $finish;
    end
endmodule
