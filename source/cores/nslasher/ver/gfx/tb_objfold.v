`timescale 1ns/1ps
`include "objfold_n.vh"
// Render-correctness sim for the obj0 BANDWIDTH FOLD: drives the REAL jtnslasher_sdram adapter's obj0
// 2-read FSM, feeds it the folded 8-byte-slot SDRAM image (packed_objfold.hex, HW byte-order) from a
// behavioral SDRAM, and checks the assembled 40-bit obj0_rom_data == golden (gfx3_spr) for EVERY tile.
// Proves: FSM handshake + plane_permute + hwswap16 + plane4 extraction == fold64_pass golden.
module tb_objfold;
    reg clk=0, rst=1;
    always #5 clk=~clk;

    // adapter obj0 port (engine side)
    reg         obj0_rom_cs=0;
    reg  [20:0] obj0_rom_addr=0;
    wire [39:0] obj0_rom_data;
    wire        obj0_rom_ok;
    // adapter obj0 framework side
    wire        obj0_cs;
    wire [21:0] obj0_addr;
    reg  [31:0] obj0_data=0;
    reg         obj0_ok=0;

    // behavioral SDRAM holding the folded image (1-clk latency + ok=cs)
    reg [31:0] packed_mem [0:'h27FFFF];
    initial $readmemh("packed_objfold.hex", packed_mem);
    always @(posedge clk) begin
        obj0_data <= packed_mem[obj0_addr];
        obj0_ok   <= obj0_cs;
    end

    jtnslasher_sdram u_dut(
        .rst(rst), .clk(clk),
        .pf1_rom_cs(1'b0), .pf1_rom_addr(19'd0), .pf1_rom_data(), .pf1_rom_ok(),
        .pf2_rom_cs(1'b0), .pf2_rom_addr(19'd0), .pf2_rom_data(), .pf2_rom_ok(),
        .pf3_rom_cs(1'b0), .pf3_rom_addr(19'd0), .pf3_rom_data(), .pf3_rom_ok(),
        .pf4_rom_cs(1'b0), .pf4_rom_addr(19'd0), .pf4_rom_data(), .pf4_rom_ok(),
        .obj0_rom_cs(obj0_rom_cs), .obj0_rom_addr(obj0_rom_addr),
        .obj0_rom_data(obj0_rom_data), .obj0_rom_ok(obj0_rom_ok),
        .obj1_rom_cs(1'b0), .obj1_rom_addr(21'd0), .obj1_rom_data(), .obj1_rom_ok(),
        .gfx1a_cs(), .gfx1a_addr(), .gfx1a_data(16'd0), .gfx1a_ok(1'b0),
        .gfx1b_cs(), .gfx1b_addr(), .gfx1b_data(16'd0), .gfx1b_ok(1'b0),
        .gfx2a_cs(), .gfx2a_addr(), .gfx2a_data(16'd0), .gfx2a_ok(1'b0),
        .gfx2b_cs(), .gfx2b_addr(), .gfx2b_data(16'd0), .gfx2b_ok(1'b0),
        .obj0_cs(obj0_cs), .obj0_addr(obj0_addr), .obj0_data(obj0_data), .obj0_ok(obj0_ok),
        .obj1_cs(), .obj1_addr(), .obj1_data(32'd0), .obj1_ok(1'b0)
    );

    reg [23:0] tv_hra  [0:8191];
    reg [39:0] tv_gold [0:8191];
    initial begin $readmemh("tv_hra.hex", tv_hra); $readmemh("tv_gold.hex", tv_gold); end

    integer i, errors=0;
    integer timeout;
    initial begin
        rst=1; repeat(8) @(posedge clk); rst=0; repeat(4) @(posedge clk);
        for( i=0; i<`OBJFOLD_N; i=i+1 ) begin
            @(posedge clk); #1; obj0_rom_addr = tv_hra[i][20:0]; obj0_rom_cs = 1;
            timeout=0;
            while( !obj0_rom_ok && timeout<200 ) begin @(posedge clk); timeout=timeout+1; end
            #1;
            if( obj0_rom_data !== tv_gold[i] ) begin
                errors = errors+1;
                if( errors<=12 )
                    $display("  MISMATCH i=%0d hra=%06x got=%010x gold=%010x%s",
                             i, tv_hra[i], obj0_rom_data, tv_gold[i], timeout>=200?" (TIMEOUT)":"");
            end
            obj0_rom_cs = 0; @(posedge clk); @(posedge clk);
        end
        $display("==================================================");
        $display("tb_objfold: %0d tiles, %0d mismatches -> %s",
                 `OBJFOLD_N, errors, errors==0 ? "FOLD RENDER BIT-EXACT (adapter == golden)" : "FAILED");
        $display("==================================================");
        $finish;
    end
    initial begin #50_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
