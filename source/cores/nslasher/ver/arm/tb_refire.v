`timescale 1ns/1ps
// tb_refire.v — prove the store re-fire livelock under cen pacing.
// Boots the real ROM; during the memset (PC<0xc04) counts:
//   write-ack events (o_wb_we & i_wb_ack)   vs   cen ticks   vs   arch-PC advances.
// At full cen (cen=1) a healthy store = 1 write-ack per pipeline step.
// Under REALCEN, if each cen-stall window re-issues the store, write-acks per
// cen tick climb and arch-PC advance per write-ack collapses -> livelock.
module tb_refire;
    reg         clk = 0, rst = 1;
    reg         cen_arm = 0;
    reg         vbl = 0, vbl_irq = 0;
    reg  [15:0] in0 = 16'hffff, in1 = 16'hffff;
    wire        vbl_ack;
    wire [21:0] rom_addr;  wire rom_cs;  reg [31:0] rom_data; reg rom_ok = 0;
    wire [16:2] ram_addr;  wire ram_cs;  wire [3:0] ram_we; wire [31:0] ram_dout;
    reg  [31:0] ram_data;  reg ram_ok = 0;
    wire [ 7:0] snd_latch; wire snd_req;
    wire [31:0] pc;
    wire [23:0] apc = u_dut.u_arm.u_execute.u_register_bank.r15;

    always #10.416 clk = ~clk;

`ifdef REALCEN
    localparam integer CEN_NUM = 7753, CEN_DEN = 52559;
    integer cen_acc = 0;
    initial cen_arm = 0;
    always @(posedge clk) begin
        if (cen_acc + CEN_NUM >= CEN_DEN) begin cen_acc <= cen_acc+CEN_NUM-CEN_DEN; cen_arm <= 1'b1; end
        else begin cen_acc <= cen_acc+CEN_NUM; cen_arm <= 1'b0; end
    end
`else
    initial cen_arm = 1;
    always @(posedge clk) cen_arm <= 1'b1;
`endif

    reg [31:0] rawrom [0:262143];
    initial $readmemh("raw_rom.hex", rawrom);
    always @(posedge clk) begin rom_data <= rawrom[rom_addr[17:0]]; rom_ok <= rom_cs; end

    reg [31:0] wram [0:32767];
    integer j; initial for (j=0;j<32768;j=j+1) wram[j]=0;
    always @(posedge clk) begin
        ram_ok <= ram_cs;
        if (ram_cs) begin
            if (ram_we[0]) wram[ram_addr][ 7: 0] <= ram_dout[ 7: 0];
            if (ram_we[1]) wram[ram_addr][15: 8] <= ram_dout[15: 8];
            if (ram_we[2]) wram[ram_addr][23:16] <= ram_dout[23:16];
            if (ram_we[3]) wram[ram_addr][31:24] <= ram_dout[31:24];
            ram_data <= wram[ram_addr];
        end
    end

    jtnslasher_main u_dut(
        .rst(rst), .clk(clk), .cen_arm(cen_arm),
        .in0(in0), .in1(in1), .vbl(vbl), .vbl_irq(vbl_irq), .vbl_ack(vbl_ack),
        .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_data(rom_data), .rom_ok(rom_ok),
        .ram_addr(ram_addr), .ram_cs(ram_cs), .ram_we(ram_we), .ram_dout(ram_dout),
        .ram_data(ram_data), .ram_ok(ram_ok),
        .snd_latch(snd_latch), .snd_req(snd_req), .dbg_pc_addr(pc));

    // taps into the a23 wishbone master
    wire wb_we   = u_dut.u_arm.o_wb_we;
    wire wb_stb  = u_dut.u_arm.o_wb_stb;
    wire wb_ack  = u_dut.wb_ack;
    wire wb_cyc  = u_dut.u_arm.o_wb_cyc;
    wire [23:0] wb_adr = u_dut.wb_adr[23:0];
    // a23-internal data-store select (held during cen stall?)
    wire sel_wb_we = u_dut.u_arm.u_fetch.sel_wb & u_dut.u_arm.write_enable;

    integer cen_ticks=0, write_acks=0, ramwrites=0, pc_adv=0;
    reg [23:0] apc_d=24'hffffff;
    integer selwb_clks=0;   // # of 48MHz clks with a write-select held (re-fire window)
    always @(posedge clk) begin
        if (cen_arm) cen_ticks <= cen_ticks+1;
        if (wb_we & wb_stb & wb_ack) write_acks <= write_acks+1;
        if (ram_cs & |ram_we) ramwrites <= ramwrites+1;
        if (sel_wb_we) selwb_clks <= selwb_clks+1;
        if (apc != apc_d) begin apc_d <= apc; pc_adv <= pc_adv+1; end
    end

    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- tb_refire (%s) ---", `ifdef REALCEN "REALCEN" `else "CEN=1" `endif);
        // run a fixed window and report (memset is PC<0xc04 the whole time)
        #2000000;  // 2 ms
        $display("[2ms] PC=%06x cen_ticks=%0d write_acks=%0d ramwrites=%0d pc_adv=%0d selwb_clks=%0d",
                 {apc,2'd0}, cen_ticks, write_acks, ramwrites, pc_adv, selwb_clks);
        $display("   write_acks/cen_tick = %0d.%03d   ramwrites/pc_adv = %0d.%03d",
                 write_acks/cen_ticks, (1000*write_acks/cen_ticks)%1000,
                 pc_adv>0?ramwrites/pc_adv:0, pc_adv>0?(1000*ramwrites/pc_adv)%1000:0);
        #6000000;  // +6 ms = 8 ms total
        $display("[8ms] PC=%06x cen_ticks=%0d write_acks=%0d ramwrites=%0d pc_adv=%0d selwb_clks=%0d",
                 {apc,2'd0}, cen_ticks, write_acks, ramwrites, pc_adv, selwb_clks);
        $finish;
    end
endmodule
