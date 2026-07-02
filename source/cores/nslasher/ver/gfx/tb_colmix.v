`timescale 1ns/1ps
// Validate jtnslasher_colmix: preload the captured palette, feed the golden pxl stream,
// dump the RGB it produces -> compare vs the expected (golden) RGB in cmp_rgb.py.
module tb_colmix;
    localparam DIR = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";
    reg          clk=0, pxl_cen=1;
    reg          pal_we=0; reg [10:0] pal_waddr=0; reg [23:0] pal_din=0;
    reg  [ 7:0]  pf2_pxl=0;
    wire [ 7:0]  red, green, blue;
    always #5 clk = ~clk;

    jtnslasher_colmix u_dut(.clk(clk),.pxl_cen(pxl_cen),
        .pal_we(pal_we),.pal_waddr(pal_waddr),.pal_din(pal_din),
        .pf2_pxl(pf2_pxl),.red(red),.green(green),.blue(blue));

    reg [ 7:0] gp [0:76799];
    integer i, f;
    initial begin
        // load the palette RAM directly (low 24 bits of each 0x00BBGGRR word); the CPU pal_we
        // write path is exercised at game integration.
        $readmemh({DIR,"vram_pal.hex"},   u_dut.pal);
        $readmemh({DIR,"golden_pxl.hex"}, gp);
        @(posedge clk);
        $display("pal[103]=%06x [10f]=%06x [12f]=%06x [200]=%06x",
                 u_dut.pal[11'h103], u_dut.pal[11'h10f], u_dut.pal[11'h12f], u_dut.pal[11'h200]);
        f = $fopen({DIR,"frame_rgb.hex"},"w");
        for (i=0;i<76800;i=i+1) begin
            pf2_pxl = gp[i];
            @(posedge clk); #1;
            $fwrite(f,"%02x%02x%02x\n", red, green, blue);
        end
        $fclose(f);
        $display("colmix: 76800 px -> frame_rgb.hex");
        $finish;
    end
endmodule
