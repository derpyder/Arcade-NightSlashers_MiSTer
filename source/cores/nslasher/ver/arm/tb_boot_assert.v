`timescale 1ns/1ps
// ============================================================================
//  tb_boot_assert.v  —  REAL-ARM boot, BYTE-EXACT assertion on the cache.
//  Boots the actual encrypted ROM on the a23 through jtnslasher_main (cache in
//  front of deco156) and, on EVERY ROM word the a23 receives (is_rom & wb_ack),
//  recomputes the golden decrypted word from dec.bin and $fatal-style flags any
//  mismatch. Proves the ARM observes byte-identical instruction/data words with
//  the cache in place, across thousands of real boot fetches (incl. hot loops
//  that exercise the HIT path and cold code that exercises the FILL path).
//
//  Zero-latency ROM model (same as tb_boot) — we only care about DATA here, not
//  timing; the timing/speed proof is tb_romcache.v.
// ============================================================================
module tb_boot_assert;
    reg clk=0, rst=1;
    reg cen_arm=0;
    reg vbl=0, vbl_irq=0;
    reg [15:0] in0=16'hffff, in1=16'hffff;
    wire vbl_ack;
    wire [21:0] rom_addr; wire rom_cs; reg [31:0] rom_data; reg rom_ok=0;
    wire [16:2] ram_addr; wire ram_cs; wire [3:0] ram_we; wire [31:0] ram_dout;
    reg [31:0] ram_data; reg ram_ok=0;
    wire [7:0] snd_latch; wire snd_req; wire [31:0] pc;

    always #10.416 clk=~clk;             // 48 MHz
    // run a23 at full speed (cen=1) so we cram maximum fetches into the run
    initial cen_arm=1; always @(posedge clk) cen_arm<=1'b1;

    // raw encrypted ROM (HW-orientation) — same as tb_boot
    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin
        rom_data <= rawrom[rom_addr[17:0]];
        rom_ok   <= rom_cs;
    end

    // golden decrypted reference (byte array)
    reg [7:0] decmem [0:1048575];
    initial $readmemh("dec.hex", decmem);
    function [31:0] gold; input [17:0] w; begin
        gold = { decmem[{w,2'b11}], decmem[{w,2'b10}], decmem[{w,2'b01}], decmem[{w,2'b00}] };
    end endfunction

    // 128 KB work RAM
    reg [31:0] wram [0:32767]; integer j;
    initial for(j=0;j<32768;j=j+1) wram[j]=0;
    always @(posedge clk) begin
        ram_ok <= ram_cs;
        if (ram_cs) begin
            if (ram_we[0]) wram[ram_addr][ 7: 0]<=ram_dout[ 7: 0];
            if (ram_we[1]) wram[ram_addr][15: 8]<=ram_dout[15: 8];
            if (ram_we[2]) wram[ram_addr][23:16]<=ram_dout[23:16];
            if (ram_we[3]) wram[ram_addr][31:24]<=ram_dout[31:24];
            ram_data <= wram[ram_addr];
        end
    end

    jtnslasher_main u_dut(
        .rst(rst),.clk(clk),.cen_arm(cen_arm),
        .in0(in0),.in1(in1),.vbl(vbl),.vbl_irq(vbl_irq),.vbl_ack(vbl_ack),
        .rom_addr(rom_addr),.rom_cs(rom_cs),.rom_data(rom_data),.rom_ok(rom_ok),
        .ram_addr(ram_addr),.ram_cs(ram_cs),.ram_we(ram_we),.ram_dout(ram_dout),
        .ram_data(ram_data),.ram_ok(ram_ok),
        .snd_latch(snd_latch),.snd_req(snd_req),.dbg_pc_addr(pc)
    );

    // ---- BYTE-EXACT assertion: every ROM word the a23 accepts must be golden ----
    wire        wb_ack  = u_dut.wb_ack;
    wire        is_rom  = u_dut.is_rom;
    wire        wb_we   = u_dut.wb_we;
    wire        wb_cyc  = u_dut.wb_cyc;
    wire        wb_stb  = u_dut.wb_stb;
    wire [31:0] wb_rdat = u_dut.wb_rdat;
    wire [17:0] aw      = u_dut.arm_word;
    integer chk=0, bad=0, hits_seen=0; reg [31:0] g;
    integer prev_hits=0, prev_miss=0;
    always @(posedge clk) if(!rst) begin
        if( is_rom & ~wb_we & wb_cyc & wb_stb & wb_ack ) begin
            g = gold(aw);
            chk = chk + 1;
            if( wb_rdat !== g ) begin
                bad = bad + 1;
                if( bad<=20 )
                    $display(">>> [BOOT-ASSERT MISMATCH #%0d] t=%0t aw=%05x got=%08x golden=%08x",
                             bad, $time, aw, wb_rdat, g);
            end
        end
    end

    integer t;
    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        // periodic VBL like tb_boot, so the boot can progress
        fork
            begin
                #180000 vbl=1; vbl_irq=1; repeat(3)@(posedge clk); vbl_irq=0;
                forever begin #16000 vbl=~vbl; if(vbl) begin vbl_irq=1; repeat(3)@(posedge clk); vbl_irq=0; end end
            end
        join_none
        // run ~8 ms sim time (plenty: baseline did ~50k fetches in 7ms)
        for( t=0; t<160; t=t+1 ) begin
            #50000;
            if( t%20==0 )
                $display("[t=%0dus] rom-words checked=%0d mismatches=%0d  cache_hits=%0d cache_miss=%0d pcmax=%05x",
                         $time/1000, chk, bad, u_dut.c_hits, u_dut.c_misses, u_dut.dbg_pcmax);
        end
        $display("");
        $display("==================== BOOT BYTE-EXACT ASSERTION ====================");
        $display("  ROM words the a23 accepted (cache-served) = %0d", chk);
        $display("  mismatches vs golden dec.bin              = %0d", bad);
        $display("  cache hits=%0d misses=%0d (hit-rate=%0.2f%%)",
                 u_dut.c_hits, u_dut.c_misses,
                 u_dut.c_hits*100.0/((u_dut.c_hits+u_dut.c_misses)==0?1:(u_dut.c_hits+u_dut.c_misses)));
        $display("  %s", bad==0 ? "PASS: every cache-served word is byte-identical to deco156/golden"
                                : "FAIL: cache delivered a wrong word");
        $display("==================================================================");
        $finish;
    end
    initial begin #500_000_000; $display("TIMEOUT"); $finish; end
endmodule
