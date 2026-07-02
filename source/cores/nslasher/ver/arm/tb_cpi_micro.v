`timescale 1ns/1ps
// ============================================================================
//  tb_cpi_micro.v — a23 per-class CPI floor (drives the REAL a23_core directly)
// ----------------------------------------------------------------------------
//  Bypasses jtnslasher_main; wires a23_core to a trivial IDEAL wishbone memory
//  (1-clk ack) so we measure ONLY the a23's structural cost. cen_arm = the real
//  7.0805 MHz fractional pace. Program = a long straight-line run of single-cycle
//  data-processing ops (MOV r0,r0) ending in a backward branch, looped. The
//  per-instruction cost of the straight-line body is the a23 best-case CPI.
//
//  ARM (v2a) encodings used:
//    MOV r0,r0   = 0xE1A00000   (data op, single execute cycle, no mem, no PC write)
//    B   target  = 0xEA<imm24>  (imm24 = (target - pc - 8)>>2, signed)
// ============================================================================
module tb_cpi_micro;
    reg  i_clk=0, i_reset=1;
    reg  cen_arm=0;

    always #10.41666667 i_clk = ~i_clk;   // 48 MHz

    // real 7.0805 MHz cen
    localparam integer CEN_NUM=7753, CEN_DEN=52559;
    integer cen_acc=0;
    always @(posedge i_clk) begin
        if (cen_acc + CEN_NUM >= CEN_DEN) begin cen_acc<=cen_acc+CEN_NUM-CEN_DEN; cen_arm<=1; end
        else                              begin cen_acc<=cen_acc+CEN_NUM;         cen_arm<=0; end
    end

    // a23 wishbone master
    wire [31:0] wb_adr, wb_dat_o;  wire [3:0] wb_sel;
    wire wb_we, wb_cyc, wb_stb, wb_tga;
    reg  [31:0] wb_dat_i;  reg wb_ack;

    // ---- IDEAL memory: 0..N-1 = MOV r0,r0 ; word N = B back to 0 ; ack next clk ----
    localparam integer NBODY = 1024;          // straight-line body length (words)
    reg [31:0] mem [0:2047];
    integer k;
    initial begin
        for (k=0;k<NBODY;k=k+1) mem[k] = 32'hE1A00000;     // MOV r0,r0
        // B 0  at word NBODY:  imm24 = (0 - (NBODY*4) - 8)>>2 = -(NBODY+2)
        mem[NBODY] = 32'hEA000000 | ((-(NBODY+2)) & 24'hFFFFFF);
        for (k=NBODY+1;k<2048;k=k+1) mem[k]=32'hE1A00000;
    end

    // single-word wishbone slave, 1-clk ack (models nf6 cache HIT / ideal mem)
    always @(posedge i_clk) begin
        if (i_reset) wb_ack <= 0;
        else begin
            wb_ack   <= wb_cyc & wb_stb & ~wb_ack;     // ack the cycle after stb (1-clk latency)
            wb_dat_i <= mem[wb_adr[12:2]];
        end
    end

    a23_core u_arm(
        .i_clk(i_clk), .i_reset(i_reset),
        .i_irq(1'b0), .i_firq(1'b0),
        .i_system_rdy(cen_arm),
        .o_wb_adr(wb_adr), .o_wb_sel(wb_sel), .o_wb_we(wb_we),
        .i_wb_dat(wb_dat_i), .o_wb_dat(wb_dat_o),
        .o_wb_cyc(wb_cyc), .o_wb_stb(wb_stb),
        .i_wb_ack(wb_ack), .i_wb_err(1'b0), .o_wb_tga(wb_tga)
    );

    // taps
    wire fetch_stall  = u_arm.fetch_stall;
    wire ivalid       = u_arm.u_decode.instruction_valid;
    wire instr_accept = (~fetch_stall) & ivalid;
    wire acc          = wb_cyc & wb_stb;

    integer clk_cnt=0, cen_cnt=0, retire=0, fetchack=0;
    always @(posedge i_clk) begin
        if (i_reset) begin clk_cnt<=0; cen_cnt<=0; retire<=0; fetchack<=0; end
        else begin
            clk_cnt <= clk_cnt+1;
            if (cen_arm) cen_cnt <= cen_cnt+1;
            if (instr_accept) retire <= retire+1;
            if (cen_arm & acc & wb_ack & ~wb_we) fetchack <= fetchack+1;
        end
    end

    integer t0c, t0cen, t0r, t0f;
    real cpi, mips, fcpi;
    initial begin
        i_reset=1; repeat(20) @(posedge i_clk); i_reset=0;
        repeat(50000) @(posedge i_clk);     // warmup
        t0c=clk_cnt; t0cen=cen_cnt; t0r=retire; t0f=fetchack;
        repeat(2000000) @(posedge i_clk);   // measure
        $display("================== a23 single-cycle ALU floor ==================");
        $display(" clk=%0d  cen=%0d  retired=%0d  fetchacks=%0d",
                 clk_cnt-t0c, cen_cnt-t0cen, retire-t0r, fetchack-t0f);
        cpi  = (1.0*(cen_cnt-t0cen))/(retire-t0r);
        mips = 7.0805/cpi;
        fcpi = (1.0*(cen_cnt-t0cen))/(fetchack-t0f);
        $display(" CPI (cen ticks / retired ALU instr) = %0.3f", cpi);
        $display("   -> a23 takes %0.2f cen ticks per single-cycle data op", cpi);
        $display(" effective MIPS                      = %0.3f", mips);
        $display(" cen ticks / fetch ack               = %0.3f", fcpi);
        $display(" cen freq = %0.4f MHz",
                 (1.0*(cen_cnt-t0cen))/((clk_cnt-t0c)*1.0/48e6)/1e6);
        $display("================================================================");
        $finish;
    end
    initial begin #80000000; $display("TIMEOUT"); $finish; end
endmodule
