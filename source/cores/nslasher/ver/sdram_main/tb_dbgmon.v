`timescale 1ns/1ps
// Validate jtnslasher_dbgmon BIG/readable layout: decode grid + self-classifying VERDICT block + value rows.
module tb_dbgmon;
    reg clk=0; always #5 clk=~clk;
    reg [23:0] dbg_pc=0; reg main_cs=0, main_ok=0; reg [31:0] main_data=0, rom_dec=0;
    reg [19:0] pcmax=0, pcnow=0; reg [23:0] poll_a=0; reg [31:0] poll_d=0, snd=0;
    reg [8:0] hdump=0, vdump=0;
    wire [7:0] red,green,blue;

    jtnslasher_dbgmon dut(
        .clk(clk), .dbg_pc(dbg_pc), .main_cs(main_cs), .main_ok(main_ok),
        .main_data(main_data), .rom_dec(rom_dec),
        .dbg_pcmax(pcmax), .dbg_pcnow(pcnow), .dbg_poll_a(poll_a), .dbg_poll_d(poll_d), .dbg_snd(snd),
        .dbg_virq_cnt(16'h1234), .dbg_irq_cnt(16'h0000),
        .hdump(hdump), .vdump(vdump), .LHBL(1'b1), .LVBL(1'b1),
        .vmem_r(8'd0), .vmem_g(8'd0), .vmem_b(8'd0), .red(red), .green(green), .blue(blue) );

    `include "dbg_golden.vh"
    function [31:0] bsw(input [31:0] v); bsw={v[7:0],v[15:8],v[23:16],v[31:24]}; endfunction
    integer fail=0;

    task rd(input integer i, input [31:0] raw, input [31:0] dec);
        begin @(posedge clk); #1; dbg_pc={dbg_aw[i],2'b0}; main_data=raw; rom_dec=dec;
              main_cs=1; main_ok=1; @(posedge clk); #1; main_cs=0; main_ok=0; end
    endtask
    task chkgrid(input integer i, input [1:0] ev);
        begin if(dut.verd[i]!==ev) begin $display("FAIL grid %0d: %0d exp %0d",i,dut.verd[i],ev); fail=fail+1; end
              else $display("ok grid %0d=%0d",i,dut.verd[i]); end
    endtask
    // sample the bit a value row shows at a given bar (bar 0=MSB). value rows: row r center vdump = 80+r*32+12.
    task chkbar(input integer row, input integer bar, input expbit);
        reg got;
        begin hdump=bar*8+1; vdump=9'd80+row*32+12; #1; got = (red==8'hff && green==8'hff && blue==8'hff);
              if(got!==expbit) begin $display("FAIL row%0d bar%0d: got %b exp %b (rgb %02x%02x%02x)",row,bar,got,expbit,red,green,blue); fail=fail+1; end
              else $display("ok row%0d bar%0d=%b",row,bar,got); end
    endtask
    // check the big verdict block color (sample mid-block: vdump 50, hdump 40)
    task chkverd(input [7:0] er,eg,eb, input [127:0] tag);
        begin hdump=9'd40; vdump=9'd50; #1;
              if(red!==er||green!==eg||blue!==eb) begin $display("FAIL verdict %0s: rgb %02x%02x%02x exp %02x%02x%02x",tag,red,green,blue,er,eg,eb); fail=fail+1; end
              else $display("ok verdict %0s = %02x%02x%02x",tag,red,green,blue); end
    endtask

    initial begin
        repeat(4) @(posedge clk);
        // decode grid: fix on (dec=golden) -> green ; bug (dec garbage) -> red
        rd(0, bsw(dbg_graw[0]), dbg_gdec[0]); chkgrid(0,2'd1);
        rd(12, bsw(dbg_graw[12]), 32'hDEADBEEF); chkgrid(12,2'd2);

        // VERDICT block: pf_draw (pcnow!=0) -> GREEN ; parked+anyvid (snd[31:8]!=0) -> YELLOW ; both 0 -> RED
        pcnow=20'h00010; snd=32'h0;            #1; chkverd(8'h00,8'hff,8'h00,"DRAWING(green)");
        pcnow=20'h00000; snd=32'h00168000<<8;  #1; chkverd(8'hff,8'hff,8'h00,"PARKED+vid(yellow)");
        pcnow=20'h00000; snd=32'h0;            #1; chkverd(8'hff,8'h00,8'h00,"PARKED idle(red)");

        // value row0 = pcmax. 0x0A5A5A -> 24-bit 0x0A5A5A: bar0=MSB(bit23)=0, bar4=bit19=1, bar23=bit0=0
        pcmax=20'hA5A5A; #1;
        chkbar(0, 0, 1'b0); chkbar(0, 4, 1'b1); chkbar(0, 23, 1'b0);
        // value row1 = pfnz count (pcnow). set 0x00C0DE -> bit pattern check
        pcnow=20'hC0DE; #1;  // 24-bit value {4'd0,0xC0DE}=0x00C0DE
        // 0x00C0DE = 0000 0000 1100 0000 1101 1110 ; bar0=bit23=0, bar8=bit15=1, bar9=bit14=1, bar10=bit13=0
        chkbar(1, 0, 1'b0); chkbar(1, 8, 1'b1); chkbar(1, 10, 1'b0);

        if(fail==0) $display("=== DBGMON SIM PASS ==="); else $display("=== DBGMON SIM FAIL (%0d) ===", fail);
        $finish;
    end
endmodule
