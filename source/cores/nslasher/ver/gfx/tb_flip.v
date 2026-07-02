`timescale 1ns/1ps
// FIX C2 / task #9 gate: per-tile FLIP + colour&7 in jtnslasher_tilemap vs the gen_flip_test.py
// golden (derived from the MAME get_pfN_tile_info semantics + the reshuffle layout spec, NOT the
// RTL). Structure = tb_layer.v with in-tb comparison. flip_en=0 must equal the unflipped render
// (covered separately by the run_layer.sh cap regressions).
`include "flip_cfg.vh"
module tb_flip;
    reg          clk=0, rst=1, pxl_cen=1;
    reg  [ 8:0]  vrender=0, hdump=0;
    reg          HS=0, LHBL=1;

    wire         ram_cs;  wire [10:0] ram_addr; reg [15:0] ram_data; reg ram_ok=0;
    wire         rom_cs;  wire [18:0] rom_addr; reg [31:0] rom_data; reg rom_ok=0;
    wire [ 7:0]  pxl;

    always #5 clk = ~clk;

    reg [31:0] pf [0:2047];
    initial $readmemh("ft_pf.hex", pf);
    always @(posedge clk) begin ram_data <= pf[ram_addr][15:0]; ram_ok <= ram_cs; end

    reg [31:0] gfxrom [0:4095];
    initial $readmemh("ft_gfx.hex", gfxrom);
    always @(posedge clk) begin rom_data <= gfxrom[rom_addr[11:0]]; rom_ok <= rom_cs; end

    jtnslasher_tilemap u_dut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
        .tile8(`TILE8), .bank(2'b0), .flip_en(`FLIPEN),
        .vrender(vrender), .hdump(hdump), .HS(HS), .LHBL(LHBL),
        .scrx(`SCRX), .scry(`SCRY),
        .ram_cs(ram_cs), .ram_addr(ram_addr), .ram_data(ram_data), .ram_ok(ram_ok),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .pxl(pxl)
    );

    reg [7:0] fb [0:76799];
    reg [7:0] gold [0:76799];
    integer i;
    initial begin
        for (i=0;i<76800;i=i+1) fb[i]=8'h00;
        $readmemh("ft_golden.hex", gold);
    end
    always @(posedge clk)
        if (u_dut.buf_we && u_dut.buf_waddr < 9'd320 && vrender < 9'd240)
            fb[vrender*320 + u_dut.buf_waddr] <= u_dut.buf_wdata;

    integer ln, cyc, m;
    initial begin
        rst=1; repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);
        for (ln=0; ln<240; ln=ln+1) begin
            vrender = ln[8:0];
            @(posedge clk) HS=1;
            @(posedge clk) HS=0;
            for (cyc=0; cyc<1100; cyc=cyc+1) @(posedge clk);
        end
        m=0;
        for (i=0;i<76800;i=i+1) if (fb[i]==gold[i]) m=m+1;
        $display("tb_flip tile8=%0d flip_en=%0d: %0d/76800 match", `TILE8, `FLIPEN, m);
        for (i=0;i<76800;i=i+1) if (fb[i]!=gold[i]) begin
            $display("  first mismatch @%0d (x=%0d y=%0d): rtl=%02x golden=%02x",
                     i, i%320, i/320, fb[i], gold[i]); i=76800; end
        if (m==76800) $display("RESULT: PASS");
        else          $display("RESULT: FAIL");
        $finish;
    end
endmodule
