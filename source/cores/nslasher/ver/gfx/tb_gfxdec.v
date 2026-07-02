`timescale 1ns/1ps
// 7c-3b — at-fetch gfx decrypt+reshuffle wrapper unit sim. Feeds jtnslasher_gfxdec a behavioral 16-bit
// SDRAM holding reorder(raw) gfx (the encrypted SDRAM contents) + decrypt tables, drives render-word
// fetches, and checks rom_data == the render-format golden (gfx1_tiles16/chars8 or gfx2_tiles16).
// Config via +define (run_gfxdec.sh runs all 3 layers). Proves the RTL matches the Python-proven spec.
module tb_gfxdec;
    reg clk=0, rst=1;
    always #5 clk = ~clk;

    // behavioral 16-bit SDRAM = reorder(raw) gfx, with a few-cycle latency + proper cs/ok hold
    reg [15:0] sdr [0:`SDRW-1];
    initial $readmemh(`REORDFILE, sdr);
    wire        sdr_cs;
    wire [19:0] sdr_addr;
    reg  [15:0] sdr_data;
    reg         sdr_ok=0;
    reg  [2:0]  lat=0;
    // +define+HWSWAP models the HARDWARE reality measured by probe #3: the 16-bit gfx SDRAM word reads
    // back byte-swapped. With the gfxdec byteswap16 fix in place, the FIXED gfxdec must recover the golden.
    always @(posedge clk) begin
        if( sdr_cs && !sdr_ok ) begin
`ifdef HWSWAP
            if( lat >= `LAT ) begin sdr_data <= {sdr[sdr_addr][7:0],sdr[sdr_addr][15:8]}; sdr_ok <= 1; end
`else
            if( lat >= `LAT ) begin sdr_data <= sdr[sdr_addr]; sdr_ok <= 1; end
`endif
            else lat <= lat + 3'd1;
        end
        if( !sdr_cs ) begin sdr_ok <= 0; lat <= 0; end
    end

    // render-format golden (32-bit words)
    reg [31:0] gold [0:`NTEST-1];
    initial $readmemh(`GOLDFILE, gold);

    reg         rom_cs=0;
    reg  [18:0] rom_addr=0;
    wire [31:0] rom_data;
    wire        rom_ok;

    jtnslasher_gfxdec #(.CHARS8(`CHARS8), .ADDRFILE(`ADDRF), .XORFILE(`XORF), .SWAPFILE(`SWAPF)) dut(
        .rst(rst), .clk(clk),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .sdr_cs(sdr_cs), .sdr_addr(sdr_addr), .sdr_data(sdr_data), .sdr_ok(sdr_ok) );

    integer i, bad;
    reg [31:0] got;
    task fetch(input [18:0] a);
    begin
        @(posedge clk); rom_addr<=a; rom_cs<=1;
        wait(rom_ok); got = rom_data;
        @(posedge clk); rom_cs<=0;
        wait(!rom_ok);
    end endtask

    initial begin
        rst=1; repeat(6) @(posedge clk); rst=0; repeat(2) @(posedge clk);
        bad=0;
        for(i=0;i<`NTEST;i=i+1) begin
            fetch(i[18:0]);
            if( got !== gold[i] ) begin
                bad = bad + 1;
                if( bad <= 4 ) $display("  mismatch a=%0d got=%08x ref=%08x", i, got, gold[i]);
            end
        end
        $display("gfxdec %s: %0d/%0d match  %s", `LABEL, `NTEST-bad, `NTEST, bad==0 ? "BIT-EXACT" : "*** FAIL ***");
        $finish;
    end
endmodule
