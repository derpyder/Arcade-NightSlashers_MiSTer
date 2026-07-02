`timescale 1ns/1ps
`define SIMULATION
`include "tf_cfg.vh"
module tb_resync_dbg;
    reg          clk=0, LVBL=1, pxl_cen=0, fade_trig=0, paldma=0;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk=~clk;

    reg [23:0] B0[0:2047], B1[0:2047];
    integer i, mShadow_b1, mB_b1;

    jtnslasher_colmix u_dut(
        .clk(clk), .pxl_cen(pxl_cen), .LVBL(LVBL),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_din(pal_din),
        .pf1_pxl(8'd0), .pf2_pxl(8'd0), .pf3_pxl(8'd0), .pf4_pxl(8'd0),
        .obj0_pxl(16'd0), .obj1_pxl(16'd0),
        .en1(1'b1), .en2(1'b1), .en3(1'b1), .en4(1'b1), .pri(3'd0), .ace_alpha(48'd0),
        .ace_fade(`ACE_FADE), .fade_mult(`FADE_MULT), .fade_trig(fade_trig), .paldma(paldma),
        .ace_tile(64'd0),
        .red(red), .green(green), .blue(blue) );

    task live_write(input [10:0] a, input [23:0] dv);
        begin @(posedge clk); pal_we<=1'b1; pal_waddr<=a; pal_din<=dv;
              @(posedge clk); pal_we<=1'b0; end
    endtask

    // trace state transitions
    reg [2:0] fstate_l;
    always @(posedge clk) begin
        fstate_l <= u_dut.fstate;
        if (u_dut.fstate != fstate_l)
            $display("  [t=%0t] fstate %0d -> %0d  fsm_idx=%0d freeze=%0b trig_pending=%0b",
                      $time, fstate_l, u_dut.fstate, u_dut.fsm_idx, u_dut.freeze, u_dut.trig_pending);
    end

    initial begin
        $readmemh("tf_buf.hex",  B0);
        $readmemh("tf_live.hex", B1);

        for(i=0;i<2048;i=i+1) live_write(i[10:0], B0[i]);

        LVBL = 1'b0;
        @(posedge clk); fade_trig<=1'b1;
        @(posedge clk); fade_trig<=1'b0;
        $display("[t=%0t] === fade_trig fired ===", $time);

        repeat(4800) @(posedge clk);
        $display("[t=%0t] === starting batch write of B1 ===", $time);

        for(i=0;i<2048;i=i+1) live_write(i[10:0], B1[i]);
        $display("[t=%0t] === batch write COMPLETE. fstate=%0d fsm_idx=%0d freeze=%0b ===",
                  $time, u_dut.fstate, u_dut.fsm_idx, u_dut.freeze);

        repeat(30000) @(posedge clk);
        $display("[t=%0t] === post-settle: fstate=%0d freeze=%0b fsm_idx=%0d trig_pending=%0b ===",
                  $time, u_dut.fstate, u_dut.freeze, u_dut.fsm_idx, u_dut.trig_pending);
        LVBL = 1'b1;
        repeat(20) @(posedge clk);

        mShadow_b1=0; mB_b1=0;
        for(i=0;i<2048;i=i+1) begin : chk
            if (u_dut.u_live_shadow.u_ram.mem[i] == B1[i]) mShadow_b1 = mShadow_b1 + 1;
            if (u_dut.u_buf.u_ram.mem[i]  == B1[i])        mB_b1 = mB_b1 + 1;
        end
        $display("u_live_shadow==B1: %0d/2048   pal_B(u_buf)==B1: %0d/2048", mShadow_b1, mB_b1);
        $display("---- first 20 pal_B entries: which match B0 vs B1 vs neither ----");
        for(i=0;i<20;i=i+1) begin : samp
            reg [23:0] v; v = u_dut.u_buf.u_ram.mem[i];
            $display("  pal_B[%0d]=%06x  B0=%06x(%s)  B1=%06x(%s)", i, v, B0[i],
                      (v==B0[i])?"MATCH":"    ", B1[i], (v==B1[i])?"MATCH":"    ");
        end

        $finish;
    end
endmodule
