`timescale 1ns/1ps
// Validate jtnslasher_gfxprobe: latches the gfx fetch at the LOWEST pf1 render-word address seen.
module tb_gfxprobe;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, pf1_cs=0, pf1_ok=0;
    reg [18:0] pf1_addr=0; reg [31:0] pf1_data=0;
    reg [19:0] gfx1a_addr=0; reg [15:0] gfx1a_data=0;
    wire [18:0] cap_addr; wire [31:0] cap_dec; wire [19:0] cap_sdaddr; wire [15:0] cap_sddata; wire captured;
    integer fail=0;

    jtnslasher_gfxprobe dut(
        .rst(rst), .clk(clk), .pf1_cs(pf1_cs), .pf1_ok(pf1_ok),
        .pf1_addr(pf1_addr), .pf1_data(pf1_data), .gfx1a_addr(gfx1a_addr), .gfx1a_data(gfx1a_data),
        .cap_addr(cap_addr), .cap_dec(cap_dec), .cap_sdaddr(cap_sdaddr), .cap_sddata(cap_sddata), .captured(captured) );

    // one completed fetch: cs+ok rise for 1 clk with addr/data/raw held
    task fetch(input [18:0] a, input [31:0] d, input [19:0] sa, input [15:0] sd);
        begin @(posedge clk); #1; pf1_addr=a; pf1_data=d; gfx1a_addr=sa; gfx1a_data=sd; pf1_cs=1; pf1_ok=1;
              @(posedge clk); #1; pf1_cs=0; pf1_ok=0; @(posedge clk); #1; end
    endtask
    task chk(input [127:0] nm, input [31:0] got, exp);
        begin if(got!==exp) begin $display("FAIL %0s got %08x exp %08x",nm,got,exp); fail=fail+1; end
              else $display("ok %0s=%08x",nm,got); end
    endtask

    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        // first fetch at addr 0x400 -> captured
        fetch(19'h00400, 32'hAABBCCDD, 20'h01234, 16'h5678);
        chk("cap_addr#1",  {13'd0,cap_addr}, 32'h00400);
        chk("cap_dec#1",   cap_dec,          32'hAABBCCDD);
        chk("captured#1",  {31'd0,captured}, 32'd1);
        // higher addr -> must NOT replace (we track the minimum)
        fetch(19'h05000, 32'h11112222, 20'h0aaaa, 16'h9999);
        chk("cap_addr#2",  {13'd0,cap_addr}, 32'h00400);   // unchanged
        chk("cap_dec#2",   cap_dec,          32'hAABBCCDD); // unchanged
        // lower addr -> replaces with new minimum + its raw SDRAM data
        fetch(19'h00010, 32'h0000019D, 20'h00021, 16'hC30F);
        chk("cap_addr#3",  {13'd0,cap_addr},   32'h00010);
        chk("cap_dec#3",   cap_dec,            32'h0000019D);
        chk("cap_sdaddr#3",{12'd0,cap_sdaddr}, 32'h00021);
        chk("cap_sddata#3",{16'd0,cap_sddata}, 32'h0000C30F);
        // lower addr but ZERO decrypted data (blank tile) -> must be SKIPPED (not captured)
        fetch(19'h00002, 32'h00000000, 20'h00007, 16'h0000);
        chk("cap_addr#4(skip0)", {13'd0,cap_addr}, 32'h00010);   // unchanged
        chk("cap_dec#4(skip0)",  cap_dec,          32'h0000019d); // unchanged
        if(fail==0) $display("=== GFXPROBE SIM PASS ==="); else $display("=== GFXPROBE SIM FAIL (%0d) ===", fail);
        $finish;
    end
    initial begin #50000; $display("TIMEOUT"); $finish; end
endmodule
