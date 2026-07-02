`timescale 1ns/1ps
// 7e — FULL-GAME sim. Boots the real ARM through the integrated jtnslasher_game (vtimer + main + vmem +
// sdram adapter + snd + dwnld). A behavioral multi-bank SDRAM holds the actual ROMs in the at-fetch
// layout the engines expect (main raw deco156-enc; gfx1/2 = reorder(raw); gfx3/4 = native). The ARM
// boots and POPULATES the real video RAMs; the real video core renders them; we capture an RGB frame.
// This proves ROM -> ARM -> video -> RGB functions as a unit (lint proved connection; this proves it runs).
module tb_game;
    localparam GFX = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx/";
    reg clk=0, rst=1;
    always #10.416 clk = ~clk;                       // ~48 MHz

    // ---- clock enables ----
    reg [1:0] ph=0; reg pxl_cen=0, pxl2_cen=0;
    always @(posedge clk) begin ph<=ph+2'd1; pxl_cen<=(ph==2'd3); pxl2_cen<=ph[0]; end
    reg cen_arm=1; always @(posedge clk) cen_arm<=1'b1;          // full-speed ARM (memory-paced)
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
    // SDRAM bus nets
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
        // mem ports
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

    // ================= behavioral SDRAM (1-clk, the engines tolerate any latency) =================
    reg [31:0] rawrom [0:262143];           // main ARM ROM (raw, deco156-enc)
    reg [ 7:0] sndrom [0:65535];            // Z80
    reg [ 7:0] okir1  [0:524287], okir2 [0:524287];
    reg [15:0] r1 [0:1048575], r2 [0:1048575];          // gfx1/gfx2 reorder(raw)
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

    // ================= frame capture (vdump/hdump tapped from the game's vtimer; ph==3 phase) =================
    localparam HW=384;
    reg [23:0] fb [0:240*HW-1];
    integer i; initial for(i=0;i<240*HW;i=i+1) fb[i]=24'h0;
    wire [8:0] vd = u_dut.vdump, hd = u_dut.hdump;
    integer rgb_active=0;
    always @(posedge clk) if(ph==2'd3 && vd<9'd240 && hd<9'd384) begin
        fb[vd*HW + hd] <= {blue,green,red};
        if({blue,green,red}!=24'd0) rgb_active<=rgb_active+1;   // did the video EVER output a non-black pixel?
    end

    // ================= boot monitor =================
    integer vidwr=0, palwr=0, pfwr=0, sprwr=0, irqs=0, nonblack=0;
    integer protrd=0, in0rd=0, in1rd=0, eerd=0, eepwr=0, vbledge=0, ramwr=0;
    reg [31:0] pc; assign pc = u_dut.u_main.dbg_pc_addr;
    reg [23:0] pcmin=24'hffffff, pcmax=0;
    wire mrd=u_dut.u_main.rd, mwr=u_dut.u_main.wr, mack=u_dut.u_main.wb_ack, mprot=u_dut.u_main.is_prot;
    wire [23:0] madr=u_dut.u_main.wb_adr[23:0];
    reg rcd=0, vbl_l=0, irqmask_ever=0;
    reg [6:0] ee_st_l=7'h7f; integer ee_dumps=0;
    reg lateon=0, lacc_d=0; integer latek=0; reg [27:0] lastbus=28'hfffffff;
    always @(posedge clk) begin
        if(u_dut.u_main.rom_cs) begin if(pc[23:0]>pcmax) pcmax<=pc[23:0]; if(pc[23:0]<pcmin) pcmin<=pc[23:0]; end
        if(!u_dut.u_main.u_arm.execute_status_bits[27]) irqmask_ever<=1;   // IRQ ever unmasked
        // prot reads (what the boot polls), deduped on read-commit edge
        rcd <= (mrd & mack & mprot);
        if((mrd & mack & mprot) && !rcd) begin protrd<=protrd+1;
            if(madr[11:0]==12'h500) in0rd<=in0rd+1;
            else if(madr[11:0]==12'h988) in1rd<=in1rd+1;
            else if(madr[11:0]==12'h6b4) eerd<=eerd+1;
        end
        if(|u_dut.u_main.cpu_we) begin vidwr<=vidwr+1;
            if(u_dut.u_main.cpu_addr[23:12]==12'h168) palwr<=palwr+1;
            if(u_dut.u_main.cpu_addr[23:16]==8'h18||u_dut.u_main.cpu_addr[23:16]==8'h1c) pfwr<=pfwr+1;
            if(u_dut.u_main.cpu_addr[23:12]==12'h170||u_dut.u_main.cpu_addr[23:12]==12'h178) sprwr<=sprwr+1;
        end
        // jt9346 FSM trace: dump state transitions during the first EEPROM transaction
        ee_st_l <= u_dut.u_main.u_eeprom.st;
        if(u_dut.u_main.u_eeprom.st !== ee_st_l && ee_dumps<60) begin ee_dumps<=ee_dumps+1;
            $display("[%0t] EE st %02x->%02x sclk=%0d sdi=%0d scs=%0d sdo=%0d sdi_l=%0d rx=%04x", $time,
                ee_st_l, u_dut.u_main.u_eeprom.st, u_dut.u_main.eeprom_sclk, u_dut.u_main.eeprom_sdi,
                u_dut.u_main.eeprom_scs, u_dut.u_main.u_eeprom.sdo, u_dut.u_main.u_eeprom.sdi_l,
                u_dut.u_main.u_eeprom.rx_cnt);
        end
        if(mwr & mack & u_dut.u_main.is_eeprom) begin eepwr<=eepwr+1;
            if(eepwr<40) $display("[%0t] EE wr=%04x scs=%0d clk=%0d di=%0d  sdo=%0d  (sel=%b)", $time,
                u_dut.u_main.wb_wdat[15:0], u_dut.u_main.wb_wdat[6], u_dut.u_main.wb_wdat[5],
                u_dut.u_main.wb_wdat[4], u_dut.u_main.eeprom_sdo, u_dut.u_main.wb_sel);
        end
        if(u_dut.ram_cs && |u_dut.ram_we) ramwr<=ramwr+1;
        if(u_dut.u_main.vbl_ack) irqs<=irqs+1;
        vbl_l<=u_dut.vbl; if(u_dut.vbl & ~vbl_l) vbledge<=vbledge+1;
        // late stall-bus trace (after 25 ms): distinct accesses to find the stuck loop
        if($time>9000000 && !lateon) lateon<=1;
        lacc_d <= (u_dut.u_main.wb_cyc & u_dut.u_main.wb_stb & mack);
        if(lateon && latek<40 && (u_dut.u_main.wb_cyc & u_dut.u_main.wb_stb & mack) && !lacc_d
           && {u_dut.u_main.wb_we, u_dut.u_main.u_arm.data_access, madr} != lastbus) begin
            latek<=latek+1; lastbus<={u_dut.u_main.wb_we,u_dut.u_main.u_arm.data_access,madr};
            $display("[%0t] BUS %s %s adr=%06x dat=%08x sdo=%0d", $time, u_dut.u_main.wb_we?"WR":"RD",
                u_dut.u_main.u_arm.data_access?"data ":"FETCH", madr,
                u_dut.u_main.wb_we?u_dut.u_main.wb_wdat:u_dut.u_main.wb_rdat, u_dut.u_main.eeprom_sdo);
        end
    end

    integer f, t;
    initial begin
        rst=1; repeat(100)@(posedge clk); rst=0;
        $display("--- 7e: booting integrated jtnslasher_game ---");
        for(t=0;t<260;t=t+1) begin   // ~130 ms: clear EEPROM + many IRQ frames so the ARM completes the display list
            #500000;   // 0.5 ms steps
            if(t%4==0 || pcmax>24'h039c00)
                $display("[t=%0d] PCmax=%06x vidwr=%0d (pal=%0d pf=%0d spr=%0d) irqs=%0d eepwr=%0d", t, pcmax, vidwr, palwr, pfwr, sprwr, irqs, eepwr);
        end
        // count non-black pixels in the captured frame
        nonblack=0; for(i=0;i<240*HW;i=i+1) if(fb[i]!=24'h0 && (i%HW)<320) nonblack=nonblack+1;
        $display("==================== 7e SUMMARY ====================");
        $display("PC range=%06x..%06x  RAMwr=%0d  video writes=%0d (pal=%0d pf=%0d spr=%0d)  IRQs=%0d", pcmin, pcmax, ramwr, vidwr, palwr, pfwr, sprwr, irqs);
        $display("prot reads=%0d (IN0=%0d IN1=%0d EEPROM=%0d)  EEPROM bitbang writes=%0d  vbl edges=%0d  IRQ ever unmasked=%0d",
                 protrd, in0rd, in1rd, eerd, eepwr, vbledge, irqmask_ever);
        $display("captured frame: %0d non-black pixels (of 76800 visible)  | RGB ever active = %0d clks", nonblack, rgb_active);
        f=$fopen({GFX,"frame_game.hex"},"w");
        for(i=0;i<240*HW;i=i+1) $fwrite(f,"%06x\n", fb[i]);
        $fclose(f);
        $display("frame -> ver/gfx/frame_game.hex  %s", nonblack>100 ? "(RENDERED CONTENT)" : "(blank/sparse — inspect)");
        // ---- dump the integrated DUT's REAL video RAMs for the offline cross-check (render_frame.py) ----
        // PF2 tile RAM (2048x16) + palette RAM (2048x24, 0x00BBGGRR) feed render_frame.py directly;
        // PF1/3/4 dumped too for layer diagnosis. _game.hex suffix preserves tb_boot's vram_*.hex reference.
        // jtframe_dual_ram wraps jtframe_dual_ram_cen u_ram (which holds `mem`), so tap .u_ram.mem
        $writememh({GFX,"vram_pf1_game.hex"}, u_dut.u_vmem.u_pf1ram.u_ram.mem);
        $writememh({GFX,"vram_pf2_game.hex"}, u_dut.u_vmem.u_pf2ram.u_ram.mem);
        $writememh({GFX,"vram_pf3_game.hex"}, u_dut.u_vmem.u_pf3ram.u_ram.mem);
        $writememh({GFX,"vram_pf4_game.hex"}, u_dut.u_vmem.u_pf4ram.u_ram.mem);
        $writememh({GFX,"vram_pal_game.hex"}, u_dut.u_vmem.u_video.u_colmix.u_pal.u_ram.mem);
        $display("DUT video RAMs dumped -> ver/gfx/vram_{pf1..pf4,pal}_game.hex (offline cross-check ready)");
        $finish;
    end
endmodule
