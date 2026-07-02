`timescale 1ns/1ps
// Sim-only behavioral replacements for the a23 cache SRAMs (the vendored
// amber/sram_*.v use Altera altsyncram, which iverilog can't elaborate).
// The cache is disabled at reset (cacheable_area=0 -> all accesses go to
// Wishbone), so these are never functionally exercised in the bring-up sim;
// they only need to elaborate. The real altsyncram versions are kept for synth.

module sram_byte_en #(parameter DATA_WIDTH=128, parameter ADDRESS_WIDTH=7)
(
    input                          i_clk,
    input      [DATA_WIDTH-1:0]    i_write_data,
    input                          i_write_enable,
    input      [ADDRESS_WIDTH-1:0] i_address,
    input      [DATA_WIDTH/8-1:0]  i_byte_enable,
    output reg [DATA_WIDTH-1:0]    o_read_data
);
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDRESS_WIDTH)-1];
    integer k;
    always @(posedge i_clk) begin
        if (i_write_enable)
            for (k = 0; k < DATA_WIDTH/8; k = k + 1)
                if (i_byte_enable[k]) mem[i_address][k*8 +: 8] <= i_write_data[k*8 +: 8];
        o_read_data <= mem[i_address];   // registered output (outdata_reg_a=CLOCK0)
    end
endmodule

module sram_line_en #(parameter DATA_WIDTH=128, parameter ADDRESS_WIDTH=7, parameter INITIALIZE_TO_ZERO=0)
(
    input                          i_clk,
    input      [ADDRESS_WIDTH-1:0] i_address,
    input      [DATA_WIDTH-1:0]    i_write_data,
    input                          i_write_enable,
    output reg [DATA_WIDTH-1:0]    o_read_data
);
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDRESS_WIDTH)-1];
    always @(posedge i_clk) begin
        if (i_write_enable) mem[i_address] <= i_write_data;
        o_read_data <= mem[i_address];
    end
endmodule
