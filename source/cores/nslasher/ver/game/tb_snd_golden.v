`timescale 1ns/1ps
// Sound golden-compare (RTL side). Boots the real ARM through jtnslasher_game (incl. Z80 + jt51 + 2x jt6295)
// and traces the SOUND path so it can be diffed against the MAME golden (mame-dump/snd_golden/):
//   MAME golden: 1 soundlatch cmd (0x01) @boot; Z80 reads D000 exactly TWICE; ~5x OKI write 0x78 (stop);
//   YM init burst then ONLY timer-A reloads (regs 0x12/0x14); reg 0x1B never written -> banks stay 0/0; idle.
// If the RTL Z80 LOOPS (continuous D000 reads / OKI writes / bank flips) -> reproduces the cab bug in sim.
module tb_snd_golden;
    localparam GFX = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";
    reg clk=0, rst=1;
    always #10.416 clk = ~clk;                       // ~48 MHz

    // ---- clock enables (same as tb_game) ----
    reg [1:0] ph=0; reg pxl_cen=0, pxl2_cen=0;
    always @(posedge clk) begin ph<=ph+2'd1; pxl_cen<=(ph==2'd3); pxl2_cen<=ph[0]; end
    reg cen_arm=1; always @(posedge clk) cen_arm<=1'b1;
    reg [5:0] fmdiv=0; reg cen_fm=0, cen_fm2=0; reg ff2=0;
    always @(posedge clk) begin
        fmdiv<=fmdiv+1'd1; cen_fm<=(fmdiv==6'd12);
        if(fmdiv==6'd12) begin fmdiv<=0; ff2<=~ff2; cen_fm2<=ff2; end
    end
    reg [5:0] okdiv=0; reg cen_oki1=0, cen_oki2=0;
    always @(posedge clk) begin okdiv<=okdiv+1'd1;
        cen_oki1<=(okdiv==6'd47); cen_oki2<=(okdiv[4:0]==5'd23); if(okdiv==6'd47) okdiv<=0; end

    // ================= game-port nets =================
    wire [7:0] red, green, blue;  wire LHBL, LVBL, HS, VS, dip_flip;
    wire [7:0] st_dout, debug_view;
    wire signed [15:0] fm_l, fm_r;  wire signed [13:0] oki1, oki2;
    wire [21:0] post_addr;  wire [7:0] post_data;
    wire [1:0] dsn;  wire [31:0] main_dout;
    wire        ram_cs, ram_we;  wire [16:2] ram_addr;
    wire        main_cs;  wire [19:2] main_addr;  reg [31:0] main_data;  reg main_ok=0;
    wire        snd_cs;   wire [15:0] snd_addr;    reg [ 7:0] snd_data;  reg snd_ok=0;
    wire        oki1_cs;  wire [18:0] oki1_addr;   reg [ 7:0] oki1_data; reg oki1_ok=0;
    wire        oki2_cs;  wire [18:0] oki2_addr;   reg [ 7:0] oki2_data; reg oki2_ok=0;
    wire        gfx1a_cs,gfx1b_cs,gfx2a_cs,gfx2b_cs; wire [19:0] gfx1a_addr,gfx1b_addr,gfx2a_addr,gfx2b_addr;
    reg  [15:0] gfx1a_data,gfx1b_data,gfx2a_data,gfx2b_data; reg gfx1a_ok=0,gfx1b_ok=0,gfx2a_ok=0,gfx2b_ok=0;
    wire        obj0lo_cs,obj0hi_cs,obj1_cs;  wire [20:0] obj0lo_addr,obj0hi_addr; wire [17:0] obj1_addr;
    reg  [31:0] obj0lo_data,obj1_data; reg [7:0] obj0hi_data; reg obj0lo_ok=0,obj0hi_ok=0,obj1_ok=0;

    // ================= DUT =================
    jtnslasher_game u_dut(
        .rst(rst), .clk(clk), .rst24(rst), .clk24(clk), .rst96(rst), .clk96(clk),
        .pxl2_cen(pxl2_cen), .pxl_cen(pxl_cen),
        .red(red), .green(green), .blue(blue), .LHBL(LHBL), .LVBL(LVBL), .HS(HS), .VS(VS),
        .cab_1p(4'hf), .coin(4'hf),
        .joystick1(7'h7f), .joystick2(7'h7f), .joystick3(7'h7f), .joystick4(7'h7f),
        .dial_x(2'd0), .dial_y(2'd0),
        .joyana_l1(16'd0),.joyana_l2(16'd0),.joyana_l3(16'd0),.joyana_l4(16'd0),
        .joyana_r1(16'd0),.joyana_r2(16'd0),.joyana_r3(16'd0),.joyana_r4(16'd0),
        .snd_en(6'h3f), .snd_vol(8'hff),
        .status(32'd0), .dipsw(32'hffffffff), .dip_pause(1'b1), .dip_test(1'b1),
        .service(1'b1), .tilt(1'b0), .dip_flip(dip_flip), .dip_fxlevel(2'd0),
        .st_addr(8'd0), .st_dout(st_dout), .gfx_en(4'hf), .debug_bus(8'd0), .debug_view(debug_view),
        .cen_arm(cen_arm), .cen_fm(cen_fm), .cen_fm2(cen_fm2), .cen_oki1(cen_oki1), .cen_oki2(cen_oki2),
        .fm_l(fm_l), .fm_r(fm_r), .oki1(oki1), .oki2(oki2),
        .prog_addr(22'd0), .prog_data(8'd0), .prog_we(1'b0), .prog_ba(2'd0),
        .ioctl_addr(26'd0), .prom_we(1'b0), .post_addr(post_addr), .post_data(post_data),
        .ioctl_ram(1'b0), .ioctl_cart(1'b0), .dsn(dsn), .main_dout(main_dout),
        .ram_addr(ram_addr), .ram_cs(ram_cs), .ram_ok(1'b1), .ram_data(32'd0), .ram_we(ram_we),
        .main_addr(main_addr), .main_cs(main_cs), .main_ok(main_ok), .main_data(main_data),
        .snd_addr(snd_addr), .snd_cs(snd_cs), .snd_ok(snd_ok), .snd_data(snd_data),
        .oki1_addr(oki1_addr), .oki1_cs(oki1_cs), .oki1_ok(oki1_ok), .oki1_data(oki1_data),
        .oki2_addr(oki2_addr), .oki2_cs(oki2_cs), .oki2_ok(oki2_ok), .oki2_data(oki2_data),
        .gfx1a_addr(gfx1a_addr),.gfx1a_cs(gfx1a_cs),.gfx1a_ok(gfx1a_ok),.gfx1a_data(gfx1a_data),
        .gfx1b_addr(gfx1b_addr),.gfx1b_cs(gfx1b_cs),.gfx1b_ok(gfx1b_ok),.gfx1b_data(gfx1b_data),
        .gfx2a_addr(gfx2a_addr),.gfx2a_cs(gfx2a_cs),.gfx2a_ok(gfx2a_ok),.gfx2a_data(gfx2a_data),
        .gfx2b_addr(gfx2b_addr),.gfx2b_cs(gfx2b_cs),.gfx2b_ok(gfx2b_ok),.gfx2b_data(gfx2b_data),
        .obj0lo_addr(obj0lo_addr),.obj0lo_cs(obj0lo_cs),.obj0lo_ok(obj0lo_ok),.obj0lo_data(obj0lo_data),
        .obj0hi_addr(obj0hi_addr),.obj0hi_cs(obj0hi_cs),.obj0hi_ok(obj0hi_ok),.obj0hi_data(obj0hi_data),
        .obj1_addr(obj1_addr),.obj1_cs(obj1_cs),.obj1_ok(obj1_ok),.obj1_data(obj1_data) );

    // ================= behavioral SDRAM (same as tb_game) =================
    reg [31:0] rawrom [0:262143];
    reg [ 7:0] sndrom [0:65535];
    reg [ 7:0] okir1  [0:524287], okir2 [0:524287];
    reg [15:0] r1 [0:1048575], r2 [0:1048575];
    reg [31:0] obj0lo_n [0:2097151]; reg [7:0] obj0hi_n [0:2097151]; reg [31:0] obj1_n [0:262143];
    initial begin
        $readmemh("raw_rom.hex", rawrom);
        $readmemh("snd_rom.hex", sndrom); $readmemh("oki1.hex", okir1); $readmemh("oki2.hex", okir2);
        $readmemh({GFX,"r1_gfx1.hex"}, r1); $readmemh({GFX,"r2_gfx2.hex"}, r2);
        $readmemh({GFX,"obj0lo_native.hex"}, obj0lo_n); $readmemh({GFX,"obj0hi_native.hex"}, obj0hi_n);
        $readmemh({GFX,"obj1_native.hex"}, obj1_n);
    end
    always @(posedge clk) begin
        main_data<=rawrom[main_addr];        main_ok<=main_cs;
        snd_data <=sndrom[snd_addr];          snd_ok <=snd_cs;
        oki1_data<=okir1[oki1_addr];          oki1_ok<=oki1_cs;
        oki2_data<=okir2[oki2_addr];          oki2_ok<=oki2_cs;
        gfx1a_data<=r1[gfx1a_addr]; gfx1a_ok<=gfx1a_cs;  gfx1b_data<=r1[gfx1b_addr]; gfx1b_ok<=gfx1b_cs;
        gfx2a_data<=r2[gfx2a_addr]; gfx2a_ok<=gfx2a_cs;  gfx2b_data<=r2[gfx2b_addr]; gfx2b_ok<=gfx2b_cs;
        obj0lo_data<=obj0lo_n[obj0lo_addr]; obj0lo_ok<=obj0lo_cs;
        obj0hi_data<=obj0hi_n[obj0hi_addr]; obj0hi_ok<=obj0hi_cs;
        obj1_data  <=obj1_n[obj1_addr];     obj1_ok  <=obj1_cs;
    end

    // ================= SOUND MONITOR =================
    // frame counter from LVBL falling edges
    integer frame=0; reg lvbl_l=1;
    always @(posedge clk) begin lvbl_l<=LVBL; if(lvbl_l && !LVBL) frame<=frame+1; end

    // hierarchical sound taps
    wire        s_latch_cs = u_dut.u_snd.latch_cs;          // D000 read
    wire        s_wrn      = u_dut.u_snd.wr_n;
    wire        s_oki1cs   = u_dut.u_snd.oki1_io_cs;
    wire        s_oki2cs   = u_dut.u_snd.oki2_io_cs;
    wire        s_fmcs     = u_dut.u_snd.fm_cs;
    wire [7:0]  s_dout     = u_dut.u_snd.cpu_dout;
    wire [15:0] s_A        = u_dut.u_snd.A;
    wire        s_ct1      = u_dut.u_snd.ct1;
    wire        s_ct2      = u_dut.u_snd.ct2;
    wire        s_intn     = u_dut.u_snd.int_n;
    wire        s_cmdn     = u_dut.u_snd.irq_cmd_n;
    wire        s_fmirqn   = u_dut.u_snd.fm_irq_n;
    wire        s_sndreq   = u_dut.snd_req;
    wire [7:0]  s_sndlatch = u_dut.snd_latch;

    integer ym_wr=0, oki1_wr=0, oki2_wr=0, d000_rd=0, req_cnt=0, bank_chg=0;
    integer fh; integer ym1b_wr=0;   // count writes that target YM reg 0x1B (bank)
    reg p_latch=0, p_oki1w=0, p_oki2w=0, p_fmw=0, p_req=0;
    reg p_ct1=0, p_ct2=0;
    reg [7:0] ym_regsel=8'hxx;      // last value written to A000 (register index)

    // edge-detected strobes
    wire oki1w = s_oki1cs & ~s_wrn;
    wire oki2w = s_oki2cs & ~s_wrn;
    wire fmw   = s_fmcs   & ~s_wrn;

    initial fh = $fopen({GFX,"snd_rtl_trace.txt"},"w");

    always @(posedge clk) begin
        p_latch<=s_latch_cs; p_oki1w<=oki1w; p_oki2w<=oki2w; p_fmw<=fmw; p_req<=s_sndreq;
        p_ct1<=s_ct1; p_ct2<=s_ct2;
        // ARM -> soundlatch
        if(s_sndreq & ~p_req) begin req_cnt<=req_cnt+1;
            $fwrite(fh,"f%0d REQ  latch=%02x\n", frame, s_sndlatch);
            if(req_cnt<40) $display("[f%0d] ARM->latch cmd=%02x", frame, s_sndlatch); end
        // Z80 D000 read (latch_cs is a level over the read M-cycle; count rising)
        if(s_latch_cs & ~p_latch) begin d000_rd<=d000_rd+1;
            $fwrite(fh,"f%0d D000rd val=%02x\n", frame, s_sndlatch);
            if(d000_rd<40) $display("[f%0d] Z80 read D000 (val=%02x) #%0d", frame, s_sndlatch, d000_rd+1); end
        // Z80 -> OKI1/OKI2 writes
        if(oki1w & ~p_oki1w) begin oki1_wr<=oki1_wr+1;
            $fwrite(fh,"f%0d OKI1 <= %02x\n", frame, s_dout);
            if(oki1_wr<40) $display("[f%0d] Z80->OKI1 %02x #%0d", frame, s_dout, oki1_wr+1); end
        if(oki2w & ~p_oki2w) begin oki2_wr<=oki2_wr+1;
            $fwrite(fh,"f%0d OKI2 <= %02x\n", frame, s_dout);
            if(oki2_wr<40) $display("[f%0d] Z80->OKI2 %02x #%0d", frame, s_dout, oki2_wr+1); end
        // Z80 -> YM2151 writes: A0=0 -> register select, A0=1 -> data. Track reg 0x1B (bank).
        if(fmw & ~p_fmw) begin ym_wr<=ym_wr+1;
            if(!s_A[0]) ym_regsel<=s_dout;            // A000 = register index
            else begin                                 // A001 = data to ym_regsel
                if(ym_regsel==8'h1b) begin ym1b_wr<=ym1b_wr+1;
                    $fwrite(fh,"f%0d YM[1B]<= %02x (CT1=%0d CT2=%0d)\n", frame, s_dout, s_dout[6], s_dout[7]);
                    $display("[f%0d] *** YM reg 0x1B <= %02x  CT1=%0d CT2=%0d (OKI BANK WRITE)", frame, s_dout, s_dout[6], s_dout[7]);
                end
            end
        end
        // OKI bank change (ct1/ct2)
        if((s_ct1^p_ct1)||(s_ct2^p_ct2)) begin bank_chg<=bank_chg+1;
            $fwrite(fh,"f%0d BANK ct1=%0d ct2=%0d\n", frame, s_ct1, s_ct2);
            $display("[f%0d] OKI bank change -> ct1=%0d ct2=%0d", frame, s_ct1, s_ct2); end
    end

    // per-frame cumulative snapshot to see idle vs loop
    integer fprev=-1;
    always @(posedge clk) if(frame!=fprev) begin fprev<=frame;
        $display("--- frame %0d : cum req=%0d d000rd=%0d oki1=%0d oki2=%0d ym=%0d ym1b=%0d bankchg=%0d  intn=%0d cmdn=%0d fmirqn=%0d",
                 frame, req_cnt, d000_rd, oki1_wr, oki2_wr, ym_wr, ym1b_wr, bank_chg, s_intn, s_cmdn, s_fmirqn);
    end

    integer t;
    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- sound golden-compare: booting integrated jtnslasher_game ---");
        for(t=0;t<320;t=t+1) #500000;     // ~160 ms ~ 9-10 frames
        $display("==================== SOUND SUMMARY ====================");
        $display("frames=%0d", frame);
        $display("ARM->latch cmds (req)   = %0d", req_cnt);
        $display("Z80 D000 reads          = %0d   (MAME golden = 2)", d000_rd);
        $display("Z80->OKI1 writes        = %0d", oki1_wr);
        $display("Z80->OKI2 writes        = %0d   (MAME golden = ~5 total, all 0x78 stop)", oki1_wr+oki2_wr);
        $display("YM2151 writes           = %0d   (MAME: init burst then ONLY regs 12/14 idle ticks)", ym_wr);
        $display("YM reg 0x1B writes       = %0d   (MAME golden = 0 -> banks never change)", ym1b_wr);
        $display("OKI bank changes (ct)   = %0d   (MAME golden = 0)", bank_chg);
        $display("final: intn=%0d cmdn=%0d fmirqn=%0d", s_intn, s_cmdn, s_fmirqn);
        $display("trace -> ver/gfx/snd_rtl_trace.txt");
        $fclose(fh);
        $finish;
    end
endmodule
