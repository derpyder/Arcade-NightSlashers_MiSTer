`timescale 1ns/1ps
// Validate jtnslasher_vidprobe (PROBE #1 = parked-vs-drawing): non-zero PF-write capture.
//   clear loop (zeros) -> nothing captured ; real tile -> captured ; palette/sprite -> anynz only ;
//   high-lane PF write -> lane-robust data capture. PASS = "=== VIDNZ SIM PASS ===".
module tb_vidnz;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [23:0] cpu_addr=0; reg [31:0] cpu_dout=0; reg [3:0] cpu_we=0;
    wire [15:0] pfnz_cnt, pfnz_d; wire [23:0] pfnz_a, anynz_a;
    wire [15:0] pal_cnt, pfbg_cnt, ctl_cnt, ctl12_5, ctl34_5;
    integer fail=0;

    jtnslasher_vidprobe dut(
        .rst(rst), .clk(clk), .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_we(cpu_we),
        .pfnz_cnt(pfnz_cnt), .pfnz_a(pfnz_a), .pfnz_d(pfnz_d), .anynz_a(anynz_a),
        .pal_cnt(pal_cnt), .pfbg_cnt(pfbg_cnt), .ctl_cnt(ctl_cnt), .ctl12_5(ctl12_5), .ctl34_5(ctl34_5) );

    // one write pulse: assert cpu_we for exactly one clk with addr/data held (matches main.v)
    task wr(input [23:0] a, input [31:0] d, input [3:0] we);
        begin @(posedge clk); #1; cpu_addr=a; cpu_dout=d; cpu_we=we;
              @(posedge clk); #1; cpu_we=4'd0; end
    endtask
    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin if(got!==exp) begin $display("FAIL %0s: got %08x exp %08x",name,got,exp); fail=fail+1; end
              else $display("ok   %0s = %08x",name,got); end
    endtask

    initial begin
        repeat(3) @(posedge clk); #1; rst=0;

        // 1) clear loop: zeros swept across PF1 -> nothing captured at all
        wr(24'h183000, 32'h0, 4'b0011);
        wr(24'h183002, 32'h0, 4'b0011);
        wr(24'h183ffe, 32'h0, 4'b0011);
        chk("clear pfnz_cnt", {16'd0,pfnz_cnt}, 32'd0);
        chk("clear pfnz_a",   {8'd0,pfnz_a},    32'd0);
        chk("clear anynz_a",  {8'd0,anynz_a},   32'd0);

        // 2) a real PF1 tile (content in low lane)
        wr(24'h182040, 32'h0000_1234, 4'b0011);
        chk("pf1 pfnz_cnt", {16'd0,pfnz_cnt}, 32'd1);
        chk("pf1 pfnz_a",   {8'd0,pfnz_a},    32'h182040);
        chk("pf1 pfnz_d",   {16'd0,pfnz_d},   32'h00001234);
        chk("pf1 anynz_a",  {8'd0,anynz_a},   32'h182040);

        // 3) palette write (non-zero, NOT a PF region) -> anynz updates, pfnz unchanged
        wr(24'h168000, 32'h00AB_CDEF, 4'b1111);
        chk("pal pfnz_cnt", {16'd0,pfnz_cnt}, 32'd1);
        chk("pal pfnz_a",   {8'd0,pfnz_a},    32'h182040);   // held
        chk("pal anynz_a",  {8'd0,anynz_a},   32'h168000);

        // 4) PF2 write with content in the HIGH lane -> lane-robust data capture
        wr(24'h184002, 32'h5678_0000, 4'b1100);
        chk("pf2hi pfnz_cnt", {16'd0,pfnz_cnt}, 32'd2);
        chk("pf2hi pfnz_a",   {8'd0,pfnz_a},    32'h184002);
        chk("pf2hi pfnz_d",   {16'd0,pfnz_d},   32'h00005678);

        // 5) PF3 write
        wr(24'h1c2010, 32'h0000_0009, 4'b0001);
        chk("pf3 pfnz_cnt", {16'd0,pfnz_cnt}, 32'd3);
        chk("pf3 pfnz_a",   {8'd0,pfnz_a},    32'h1c2010);
        chk("pf3 pfnz_d",   {16'd0,pfnz_d},   32'h00000009);

        // 6) zero write to PF with all byte-enables set -> still ignored (data is what matters)
        wr(24'h182000, 32'h0, 4'b1111);
        chk("pfzero pfnz_cnt", {16'd0,pfnz_cnt}, 32'd3);
        chk("pfzero pfnz_a",   {8'd0,pfnz_a},    32'h1c2010);  // held

        // 7) sprite-region non-zero write -> anynz only, pfnz unchanged
        wr(24'h170000, 32'h0000_4444, 4'b0011);
        chk("spr pfnz_cnt", {16'd0,pfnz_cnt}, 32'd3);
        chk("spr anynz_a",  {8'd0,anynz_a},   32'h170000);

        // ---- PROBE #2: per-region init counters (reset first to isolate from probe-#1 writes) ----
        @(posedge clk); #1; rst=1; @(posedge clk); #1; rst=0;
        // palette writes (0x168xxx)
        wr(24'h168000, 32'h0000_7C1F, 4'b0011);
        wr(24'h168010, 32'h0000_03E0, 4'b0011);
        chk("pal_cnt", {16'd0,pal_cnt}, 32'd2);
        // PF2/PF3/PF4 background writes (even zeros count = region touched)
        wr(24'h184000, 32'h0, 4'b0011);            // PF2
        wr(24'h1c2000, 32'h0000_0055, 4'b0011);    // PF3
        wr(24'h1c4000, 32'h0000_0066, 4'b0011);    // PF4
        chk("pfbg_cnt", {16'd0,pfbg_cnt}, 32'd3);
        // PF1 write must NOT bump pfbg
        wr(24'h182100, 32'h0000_0077, 4'b0011);
        chk("pfbg excl PF1", {16'd0,pfbg_cnt}, 32'd3);
        // layer-control writes + enable regs
        wr(24'h1a0014, 32'h0000_8080, 4'b0011);    // ctl12[5]: en1(b7)=1, en2(b15)=1
        wr(24'h1e0014, 32'h0000_0080, 4'b0011);    // ctl34[5]: en3(b7)=1, en4(b15)=0
        wr(24'h1a0000, 32'h0000_0001, 4'b0011);    // ctl12[0] (not reg5) -> bumps ctl_cnt only
        chk("ctl_cnt",  {16'd0,ctl_cnt},  32'd3);
        chk("ctl12_5",  {16'd0,ctl12_5},  32'h8080);
        chk("ctl34_5",  {16'd0,ctl34_5},  32'h0080);

        if(fail==0) $display("=== VIDNZ SIM PASS ==="); else $display("=== VIDNZ SIM FAIL (%0d) ===", fail);
        $finish;
    end
    initial begin #100000; $display("TIMEOUT"); $finish; end
endmodule
