`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cen_arm, // 7080500 = 48000000*7753/52559 Hz 
    input cen_fm2, cen_fm, // 3580000 = 48000000*179/2400 Hz 
    input cen_oki2, // 2014000 = 48000000*1007/24000 Hz 
    input cen_oki1, // 1007000 = 48000000*1007/48000 Hz 

    // Audio channels
    output signed [15:0] fm_l,
    output signed [15:0] fm_r,
    output signed [13:0] oki1,
    output signed [13:0] oki2,
    // Memory ports
`ifdef JTFRAME_SDRAM_LARGE
    input   [22:0]  prog_addr,
`else
    input   [21:0]  prog_addr,
`endif
    input   [ 7:0]  prog_data,
    input           prog_we,
    input   [ 1:0]  prog_ba,
    input   [25:0]  ioctl_addr,
    input           prom_we,
`ifdef JTFRAME_SDRAM_LARGE
    output reg [22:0] post_addr,
`else
    output reg [21:0] post_addr,
`endif

    output reg [ 7:0] post_data,

`ifdef JTFRAME_HEADER
    input           header,
`endif
`ifdef JTFRAME_IOCTL_RD
    input           ioctl_wr,
    output   [ 7:0] ioctl_din,
    input    [ 7:0] ioctl_dout, `endif
    input           ioctl_ram,
    input           ioctl_cart,
    // Explicit ports
    output   [15:0] main_dout,
    output   [1:0] dsn,
    // Buses to BRAM

    // Buses to SDRAM
    input    [15:0] ram_data,
    output          ram_cs,
    output   [16:1] ram_addr,
    output          ram_we,
    input           ram_ok,

    input    [31:0] main_data,
    output          main_cs,
    output   [19:2] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [15:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] oki1_data,
    output          oki1_cs,
    output   [18:0] oki1_addr,
    input           oki1_ok,

    input    [ 7:0] oki2_data,
    output          oki2_cs,
    output   [18:0] oki2_addr,
    input           oki2_ok,

    input    [15:0] gfx1a_data,
    output          gfx1a_cs,
    output   [20:1] gfx1a_addr,
    input           gfx1a_ok,

    input    [15:0] gfx1b_data,
    output          gfx1b_cs,
    output   [20:1] gfx1b_addr,
    input           gfx1b_ok,

    input    [15:0] gfx2a_data,
    output          gfx2a_cs,
    output   [20:1] gfx2a_addr,
    input           gfx2a_ok,

    input    [15:0] gfx2b_data,
    output          gfx2b_cs,
    output   [20:1] gfx2b_addr,
    input           gfx2b_ok,

    input    [31:0] obj1_data,
    output          obj1_cs,
    output   [19:2] obj1_addr,
    input           obj1_ok,

    input    [31:0] obj0_data,
    output          obj0_cs,
    output   [23:2] obj0_addr,
    input           obj0_ok
