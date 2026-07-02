`timescale 1ns/1ps
// Bit-exact unit test for jtnslasher_deco156 vs the MAME golden (gold.py).
// For every ARM word address a: read raw[dec_addr], feed it, compare dec to gold[a].
module tb_deco156;
    localparam N = 'h40000;                 // 256K words
    reg  [31:0] rawmem [0:N-1];
    reg  [31:0] gold   [0:N-1];
    reg  [17:0] a;
    reg  [31:0] rawin;
    wire [17:0] dec_addr;
    wire [31:0] dec;

    jtnslasher_deco156 dut(.a(a), .dec_addr(dec_addr), .raw(rawin), .dec(dec));

    integer i, err;
    initial begin
        $readmemh("raw.hex",  rawmem);
        $readmemh("gold.hex", gold);
        err = 0;
        for (i = 0; i < N; i = i + 1) begin
            a = i[17:0];           #1;       // -> dec_addr settles
            rawin = rawmem[dec_addr]; #1;    // feed raw word -> dec settles
            if (dec !== gold[i]) begin
                err = err + 1;
                if (err <= 10)
                    $display("MISMATCH a=%05x dec_addr=%05x  dec=%08x  gold=%08x", i, dec_addr, dec, gold[i]);
            end
        end
        $display("==== deco156 unit test: %0d words checked, %0d mismatches ====", N, err);
        if (err == 0) $display("PASS: RTL deco156 == MAME golden (bit-exact, full 256K-word coverage)");
        else          $display("FAIL: %0d mismatches", err);
        $finish;
    end
endmodule
