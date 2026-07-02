/*  Night Slashers — main CPU (Data East 156 = encrypted 26-bit ARM, 7.08 MHz)
    Wraps the Amber a23 core (OpenCores, LGPL) and bridges its Wishbone master to
    the deco32 memory map. The ARM ROM is descrambled (deco156) during download
    (see jtnslasher_sdram / the download post pass) — this module sees plain code.

    Pacing: a23 has no clock-enable input, but i_system_rdy freezes the whole
    pipeline (a23_fetch.v: o_fetch_stall = !i_system_rdy || ...). So we run a23 on
    the 48 MHz clk and gate it with cen_arm via i_system_rdy → effective 7.08 MHz.

    M2-int scope: ROM + work RAM + the 104 I/O mux (IN0/IN1/EEPROM reads) + 93C46
    EEPROM (jt9346) + soundlatch-out + VBlank IRQ. IN1 bit4 = live VBLANK (active-
    HIGH) — the boot polls it. Palette/'Ace'/sprite/PF video regs remain M3; those
    unmapped writes are still ack'd and ignored so the ARM never hangs. deco32 map
    (nslasher_map):
      000000-0FFFFF ROM     100000-11FFFF work RAM   140000 VBL ack
      150000 EEPROM/pri     163000 Ace RAM           168000 palette
      170000/178000 sprite  182000.. PF data         200000-200FFF 104 prot
    104 reads (nslasher_prot_r, offset<<1): IN0@0x500, IN1@0x988, EEPROM@0x6b4,
    soundlatch write @0x700; each input read = (val<<16)|0xffff.
*/
module jtnslasher_main(
    input             rst,
    input             clk,
    input             cen_arm,        // 7.08 MHz pace

    // Player/cabinet inputs — deco32 native bit order, ACTIVE-LOW, idle = 16'hffff.
    //   IN0: P1/P2 joysticks+buttons+starts (deco32.c IN0)
    //   IN1: coins/service/P3 (deco32.c IN1); bit4 is overridden internally by `vbl`.
    // (The JTFRAME-port -> deco32-bit remap happens in jtnslasher_game at integration.)
    input      [15:0] in0,
    input      [15:0] in1,

    // interrupt
    input             vbl,            // vblank LEVEL, ACTIVE-HIGH -> IN1[4] (boot polls it)
    input             vbl_irq,        // 1-clk pulse at start of vblank
    output reg        vbl_ack,        // pulses on write to 0x140000 (debug/visibility)

    // Program/data ROM (32-bit). addr is a 32-bit-word address into the 1 MB region.
    output     [21:0] rom_addr,       // ARM addr[23:2]
    output reg        rom_cs,
    input      [31:0] rom_data,
    input             rom_ok,

    // Work RAM (128 KB, 32-bit words, per-byte write enables)
    output     [16:2] ram_addr,
    output reg        ram_cs,
    output     [ 3:0] ram_we,
    output     [31:0] ram_dout,
    input      [31:0] ram_data,
    input             ram_ok,

    // Sound latch (to jtnslasher_snd)
    output reg [ 7:0] snd_latch,
    output reg        snd_req,

    // CPU video bus -> jtnslasher_game (deco32 video map: Ace/palette/spriteram/PF-data/ctl + DMA
    //   triggers). Registered one-pulse write transaction; the game decodes cpu_addr into the regions
    //   (0x160000-0x1FFFFF). cpu_we is the per-byte write strobe, valid the clk it pulses with
    //   cpu_addr/cpu_dout held. (CPU read-back of video RAM is deferred — boot init needs writes only.)
    output reg [23:0] cpu_addr,
    output reg [31:0] cpu_dout,
    output reg [ 3:0] cpu_we,
    output reg [ 2:0] pri,            // deco32_pri latch: bit0 PF2/3 pri swap, bit1 PF3/4 8bpp join. bit2 (the m_pri&4 raw/faded coloffs, deco32_v.cpp:352) FORCED 0 — nslasher's ONLY pri write is nslasher_eeprom_w=deco32_pri_w(data&0x3) (deco32.c:650; full nslasher_map verified, NO other pri write), so m_pri&4 is structurally always 0 -> obj0 always RAW. The 0x150000 byte is SHARED with the EEPROM bit-bang (0x10 data/0x20 clk/0x40 cs) so its bit2 is garbage and must NOT leak into pri (= the bio-monochrome bug). Only tattass uses bit2.

    // debug
    output     [31:0] dbg_pc_addr,
    output     [31:0] dbg_romdec,    // DIAG: decrypted ROM word at the current fetch (overlay probe)
    output reg [19:0] dbg_pcmax,     // DIAG: highest ROM address reached (boot progress)
    output reg [19:0] dbg_pcnow,     // DIAG: most recent ROM access (loop location when frozen)
    output reg [23:0] dbg_poll_a,    // DIAG: last non-ROM read address (what a wait-loop polls)
    output reg [31:0] dbg_poll_d,    // DIAG: value returned by that read (what it's waiting for)
    output reg [15:0] dbg_virq_cnt,  // DIAG: # of VBL IRQ pulses generated (IRQ source firing?)
    output reg [15:0] dbg_irq_cnt,   // DIAG: # of IRQ-vector (0x18) entries taken by the ARM (IRQ delivered?)
    output reg [19:0] dbg_chits_f,   // DIAG: ARM ROM-cache HITS in the last frame (per-vbl delta)
    output reg [19:0] dbg_cmiss_f,   // DIAG: ARM ROM-cache MISSES in the last frame (high = bus-starved)
    output reg [23:0] dbg_vid_a,     // DIAG: last VIDEO-region read addr (a read-back our core stubs to 0?)
    output reg [15:0] dbg_vidrd_cnt, // DIAG: # of VIDEO-region reads (is the game reading video back at all?)
    output reg [31:0] dbg_ctl,       // DIAG: work-RAM control word @0x100000 (the IRQ handler's gate bytes)
    output reg [15:0] dbg_vidwr_cnt, // DIAG: # of VIDEO writes (is the game DRAWING at all?)
    output reg [23:0] dbg_vidwr_a,   // DIAG: last video-write addr (what region it draws to)
    output reg [15:0] dbg_vidwr_d,   // DIAG: last video-write data (real content vs zeros?)
    output reg [15:0] dbg_sndwr_cnt, // DIAG: # of soundlatch writes (is the ARM sending sound commands?)
    // DIAG probe #1 (parked-vs-drawing) — see hdl/jtnslasher_vidprobe.v
    output     [15:0] dbg_pfnz_cnt,  // DIAG: # of NON-ZERO PF-tilemap writes (0 = parked, >0 = drawing)
    output     [23:0] dbg_pfnz_a,    // DIAG: last non-zero PF write addr (which PF + offset)
    output     [15:0] dbg_pfnz_d,    // DIAG: last non-zero PF write data (the tile code)
    output     [23:0] dbg_anynz_a,   // DIAG: last non-zero ANY-video write addr (region discriminator)
    // DIAG probe #2 (per-region init breakdown)
    output     [15:0] dbg_pal_cnt,   // DIAG: # palette writes (0x168xxx)
    output     [15:0] dbg_pfbg_cnt,  // DIAG: # PF2/3/4 background tile writes
    output     [15:0] dbg_ctl_cnt,   // DIAG: # layer-control reg writes (0x1a/0x1e)
    output     [15:0] dbg_ctl12_5,   // DIAG: ctl12[5] (en1=bit7, en2=bit15)
    output     [15:0] dbg_ctl34_5    // DIAG: ctl34[5] (en3=bit7, en4=bit15)
);

// ---- a23 Wishbone master ----
wire [31:0] wb_adr, wb_wdat;
reg  [31:0] wb_rdat;
wire [ 3:0] wb_sel;
wire        wb_we, wb_cyc, wb_stb, wb_tga;
reg         wb_ack;

// ---- interrupt latch (level to a23, set on vbl, cleared on vbl-ack write) ----
reg  irq_l;
wire is_rom   = wb_adr[23:20] == 4'h0;                       // 000000-0FFFFF
wire is_ram   = wb_adr[23:20] == 4'h1 && wb_adr[19:17]==3'b000; // 100000-11FFFF (128 KB)
wire is_vbl   = wb_adr[23:0] >= 24'h140000 && wb_adr[23:0] < 24'h140004;
wire is_eeprom= wb_adr[23:0] >= 24'h150000 && wb_adr[23:0] < 24'h150004; // EEPROM/pri (nslasher_eeprom_w)
wire is_video = wb_adr[23:0] >= 24'h160000 && wb_adr[23:0] < 24'h200000; // Ace/palette/spr/PF/ctl/DMA
wire is_prot  = wb_adr[23:12] == 12'h200;                    // 200000-200FFF
wire acc    = wb_cyc & wb_stb;
wire wr     = acc & wb_we;
wire rd     = acc & ~wb_we;

// IN1 with the live vblank forced into bit4 (deco32.c: IPT_VBLANK, IP_ACTIVE_HIGH).
// Same `vbl` that triggers the IRQ, so the poll and the IRQ stay coherent.
wire [15:0] in1_eff = { in1[15:5], vbl, in1[3:0] };

// ---- 93C46 EEPROM (jt9346) — bit-banged via the 0x150000 write (nslasher_eeprom_w) ----
// POWER-UP PRELOAD (2026-06-09): the synthesized jt9346 RAM powers up BLANK (M10K init = 0; the
// all-1s fill is sim-only), and the dump/NVRAM port was tied off — so the cab ran with a GARBAGE
// config (sound/coinage/etc. diverge from the MAME golden runs, which used a valid eeprom image).
// Preload the MAME golden image (mame-dump/nvram/nslashers/eeprom -> eeprom_golden.hex, 64x16
// big-endian words) through the dump port once at power-up (64 clks, runs during reset; the done
// bit survives soft resets so in-session service-menu writes persist like real NVRAM).
reg        eeprom_sclk, eeprom_sdi, eeprom_scs;
wire       eeprom_sdo;
reg  [15:0] eegold [0:63];
initial $readmemh("eeprom_golden.hex", eegold);
reg  [ 6:0] eeld = 7'd0;                 // [6] = done (BRAM-init 0 -> loads once at config)
always @(posedge clk) if( !eeld[6] ) eeld <= eeld + 7'd1;
jt9346 #(.AW(6),.DW(16)) u_eeprom(   // 93C46 = 64 x 16-bit
    .rst      ( rst         ),
    .clk      ( clk         ),
    .sclk     ( eeprom_sclk ),
    .sdi      ( eeprom_sdi  ),
    .sdo      ( eeprom_sdo  ),
    .scs      ( eeprom_scs  ),    // active-HIGH; low between instructions
    // dump port = power-up golden preload (true NVRAM save/load = future work)
    .dump_clk ( clk         ),
    .dump_addr( eeld[5:0]   ),
    .dump_we  ( ~eeld[6]    ),
    .dump_din ( eegold[eeld[5:0]] ),
    .dump_dout(             ),
    .dump_clr ( 1'b1        ),
    .dump_flag(             )
);

// deco156 ARM ROM descramble at fetch: the raw (encrypted) ROM stays in SDRAM;
// we fetch SDRAM[scramble(a)] and transform the word for address a.
wire [17:0] arm_word = wb_adr[19:2];   // 1 MB region = 256K 32-bit words
wire [17:0] dec_saddr;
wire [31:0] rom_dec;
// HW FIX (2026-06-06): the BA1 32-bit main ROM is delivered/stored BYTE-REVERSED on hardware (the on-cab
// debugger read every word, incl. the reset vector, as byteswap32(golden) -> deterministic, universal). The
// SDRAM read/write/cache LOGIC is byte-correct (faithful RTL sim), so the reversal is in the download/MRA byte
// order for this unusual 32-bit ROM. Undo it at the deco156 input (exact inverse of an exact full reversal).
wire [31:0] rom_data_fix = { rom_data[7:0], rom_data[15:8], rom_data[23:16], rom_data[31:24] };
jtnslasher_deco156 u_dec156(
    .a        ( arm_word     ),
    .dec_addr ( dec_saddr    ),
    .raw      ( rom_data_fix ),
    .dec      ( rom_dec      )
);
assign rom_addr = { 4'd0, dec_saddr };
assign ram_addr = wb_adr[16:2];
assign ram_dout = wb_wdat;
assign ram_we   = (is_ram & wr) ? wb_sel : 4'd0;
assign dbg_pc_addr = wb_adr;
assign dbg_romdec  = rom_dec;   // DIAG

// ============================================================================
// ARM-ADDRESS-keyed DECRYPTED-ROM CACHE  (the game-speed fix)
// ----------------------------------------------------------------------------
// The deco156 descramble is done AT FETCH (rom_dec = DataXform(SDRAM[scramble(a)],a)).
// The address scramble destroys all spatial locality in SDRAM space, so the 64-bit
// jtframe bcache (keyed by SDRAM addr) MISSES on essentially every sequential ARM
// fetch -> the a23 stalls on full SDRAM latency every instruction -> ~2.5-3 MHz
// effective instead of 7.08 MHz (slow-motion game logic, smooth video).
//
// FIX: memoize the pure function rom_dec(arm_word) over the read-only ROM in a
// direct-mapped BRAM keyed by arm_word, sitting IN FRONT of u_dec156. ROM never
// changes -> no invalidation, no coherency. HIT returns the decrypted word in
// ~1-2 clk (well under the 6.78-clk cen_arm period) -> ARM paced at full 7.08 MHz.
// MISS drives the EXISTING deco156/SDRAM path, fills the line, then returns.
//
// SIZE: 16 KB data = 4096 lines x 32-bit. arm_word[17:0] (1 MB = 256K words):
//   index = arm_word[11:0]  (4096 lines)   tag = arm_word[17:12]  (6 bits)
// BRAM: cache_data[index]=rom_dec(32b), cache_tagv[index]={valid(1),tag(6)}=7b.
// Power-up valid=0 (M10K init 0 / jtframe_dual_ram sim init 0) -> all-miss until
// warmed, no clear needed (read-only ROM). rst clears valid for safety.
// ============================================================================
localparam CACHE_AW  = 12;                  // 4096 lines (16 KB of 32-bit data)
localparam CACHE_TAGW= 18-CACHE_AW;         // 6-bit tag (arm_word is 18 bits)

wire [CACHE_AW-1:0]   c_index   = arm_word[CACHE_AW-1:0];
wire [CACHE_TAGW-1:0] c_tag     = arm_word[17:CACHE_AW];

// Cache RAM read (lookup) — registered 1-clk read via port1 of jtframe_dual_ram.
wire [31:0]            c_data_q;             // cache_data[index]   registered
wire [CACHE_TAGW:0]    c_tagv_q;             // {valid, tag}        registered

// ---- transaction tracking ----------------------------------------------------
// The a23 holds wb_adr/wb_stb across the whole stall (WB_WAIT_ACK) and keeps stb
// high for one extra clk on the ack cycle. To deliver EXACTLY ONE ack per fetch,
// carrying the CURRENT address's data, we:
//   * detect a NEW rom access  (is_rom&rd & ~served)
//   * pipeline the looked-up arm_word by 1 clk (aw_d) to align with the registered
//     BRAM read, and require aw_d==arm_word so a stale lookup can't ack a new addr
//   * latch `served` when we ack, clear it when the bus access drops (acc low)
reg                   served;               // the CURRENT (held) ROM fetch already acked
reg  [17:0]           served_aw;            // arm_word that `served` refers to
reg                   c_acc_d;              // a valid lookup was issued last clk
reg  [17:0]           aw_d;                 // arm_word delayed 1 clk (the line looked up)
wire rom_req          = is_rom & rd;        // a ROM read is on the bus
// `served` marks "the current held ROM address has already been acked". It is set
// on ack and CLEARED (below, in the FSM) whenever the bus access drops (a23 WB_IDLE
// between fetches) OR the address moves (each a23 burst beat, adr[3:2]++ -> new
// arm_word). So a genuine re-fetch of the same word — or the next burst beat — is
// served again, but a held address is never double-acked.
wire served_clr       = ~acc | (served_aw!=arm_word);
wire new_rom_req      = rom_req & ~served;

// FSM
localparam C_LOOKUP=2'd0, C_FILL=2'd1;
reg                   cstate;
reg  [CACHE_AW-1:0]   index_l;              // line latched at miss
reg  [CACHE_TAGW-1:0] tag_l;
reg  [31:0]           dec_l;                // decrypted word captured at fill (registered, stable for the BRAM write)
reg                   c_we;                 // cache line write strobe (1 clk on fill complete)

// Lookup result aligns 1 clk after the index was presented. Only valid if the
// looked-up address still matches the address on the bus (same transaction).
wire lookup_for_cur = c_acc_d & (aw_d==arm_word);
wire c_hit          = lookup_for_cur & c_tagv_q[CACHE_TAGW] &
                      (c_tagv_q[CACHE_TAGW-1:0]==arm_word[17:CACHE_AW]);

// ROM read result presented to the a23 mux. rom_ack is a clean 1-shot per fetch.
reg         rom_ack;
reg  [31:0] rom_word;

always @(posedge clk) begin
    if( rst ) begin
        cstate    <= C_LOOKUP;
        served    <= 1'b0; served_aw <= 18'd0;
        c_acc_d   <= 1'b0; aw_d <= 18'd0;
        index_l   <= 0; tag_l <= 0; dec_l <= 32'h0;
        c_we      <= 1'b0;
        rom_ack   <= 1'b0; rom_word <= 32'h0;
    end else begin
        c_we    <= 1'b0;          // default: no cache write
        rom_ack <= 1'b0;          // default: no ack (1-shot)
        // release the per-address ack guard when the access drops or the address moves
        if( served_clr ) served <= 1'b0;
        // pipeline the lookup address (BRAM read latency = 1 clk). Only track a NEW,
        // not-yet-served request while in C_LOOKUP.
        c_acc_d <= new_rom_req & (cstate==C_LOOKUP);
        aw_d    <= arm_word;
        case( cstate )
        C_LOOKUP: begin
            if( c_hit & ~served ) begin
                // HIT: serve from cache, ack once for this held address
                rom_word  <= c_data_q;
                rom_ack   <= 1'b1;
                served    <= 1'b1;
                served_aw <= arm_word;
            end else if( lookup_for_cur & ~served ) begin
                // MISS: latch the line, hand off to the deco156/SDRAM fill path
                index_l <= arm_word[CACHE_AW-1:0];
                tag_l   <= arm_word[17:CACHE_AW];
                cstate  <= C_FILL;
            end
        end
        C_FILL: begin
            // rom_cs drives the SDRAM slot; rom_dec is the live decrypted word for the
            // held wb_adr. On rom_ok: CAPTURE rom_dec into dec_l (registered, so the BRAM
            // write next clk is immune to wb_adr moving off this fetch), ack once.
            if( rom_ok ) begin
                dec_l     <= rom_dec;        // stable copy for the cache fill write
                c_we      <= 1'b1;           // write cache_data[index_l]=dec_l, tagv={1,tag_l} next clk
                rom_word  <= rom_dec;        // deliver to a23 this ack
                rom_ack   <= 1'b1;
                served    <= 1'b1;
                served_aw <= arm_word;
                cstate    <= C_LOOKUP;
            end
        end
        endcase
    end
end

// Drive the SDRAM ROM slot ONLY during a miss/fill (cuts ~100x SDRAM traffic and
// prevents a stale slot transaction from double-acking a later hit).
wire rom_fetch = (cstate==C_FILL);

// Cache data RAM: port0 = fill write (from the REGISTERED dec_l), port1 = lookup read.
jtframe_dual_ram #(.DW(32), .AW(CACHE_AW)) u_cache_data(
    .clk0 ( clk          ), .data0( dec_l       ), .addr0( index_l ), .we0( c_we ), .q0(           ),
    .clk1 ( clk          ), .data1( 32'd0       ), .addr1( c_index ), .we1( 1'b0 ), .q1( c_data_q )
);
// Tag+valid RAM: {valid, tag}. Fill writes {1'b1, tag_l}; power-up valid=0 (BRAM init
// 0 / jtframe_dual_ram sim init 0) -> all-miss until warmed, no clear needed (read-only ROM).
jtframe_dual_ram #(.DW(CACHE_TAGW+1), .AW(CACHE_AW)) u_cache_tagv(
    .clk0 ( clk          ), .data0({1'b1,tag_l}), .addr0( index_l ), .we0( c_we ), .q0(           ),
    .clk1 ( clk          ), .data1({(CACHE_TAGW+1){1'b0}}), .addr1( c_index ), .we1( 1'b0 ), .q1( c_tagv_q )
);

// cache hit/miss counters (DIAG / verification handle). Count once per served fetch.
reg [31:0] c_hits, c_misses;
always @(posedge clk) begin
    if( rst ) begin c_hits<=0; c_misses<=0; end
    else begin
        if( cstate==C_LOOKUP & c_hit & ~served )                  c_hits   <= c_hits   + 32'd1;
        if( cstate==C_FILL   & rom_ok )                            c_misses <= c_misses + 32'd1;
    end
end
// PER-FRAME deltas for the on-cab diagnostic overlay: latch hits/misses since the last vblank, then
// reset the running accumulators. dbg_cmiss_f high (thousands) => the ARM is bus-starving on misses;
// low (tens) => the cache is doing its job (-> the bottleneck is the VBLANK/IRQ path or a23 CPI).
reg [19:0] hits_acc, miss_acc;
always @(posedge clk) begin
    if( rst ) begin hits_acc<=0; miss_acc<=0; dbg_chits_f<=0; dbg_cmiss_f<=0; end
    else begin
        if( vbl_irq ) begin                                   // frame boundary: snapshot + restart
            dbg_chits_f <= hits_acc;  dbg_cmiss_f <= miss_acc;
            hits_acc <= 20'd0;        miss_acc <= 20'd0;
        end else begin
            if( cstate==C_LOOKUP & c_hit & ~served ) hits_acc <= hits_acc + 20'd1;
            if( cstate==C_FILL   & rom_ok )          miss_acc <= miss_acc + 20'd1;
        end
    end
end

// DIAG: boot-progress + I/O-poll capture (find the post-fix hang). pcmax/pcnow track ROM accesses;
// poll_a/poll_d latch the last NON-ROM read = whatever a stuck wait-loop is polling.
initial begin dbg_pcmax=0; dbg_pcnow=0; dbg_poll_a=0; dbg_poll_d=0; dbg_virq_cnt=0; dbg_irq_cnt=0;
              dbg_vid_a=0; dbg_vidrd_cnt=0; dbg_ctl=0;
              dbg_vidwr_cnt=0; dbg_vidwr_a=0; dbg_vidwr_d=0; dbg_sndwr_cnt=0; end
reg at18_d=0;
always @(posedge clk) begin
    if( rst ) begin dbg_pcmax<=0; dbg_pcnow<=0; dbg_poll_a<=0; dbg_poll_d<=0; dbg_virq_cnt<=0; dbg_irq_cnt<=0; at18_d<=0;
                    dbg_vid_a<=0; dbg_vidrd_cnt<=0; dbg_ctl<=0;
                    dbg_vidwr_cnt<=0; dbg_vidwr_a<=0; dbg_vidwr_d<=0; dbg_sndwr_cnt<=0; end
    else begin
        // video-WRITE + sound-command probes (is the game actually drawing / playing?)
        if( |cpu_we ) begin dbg_vidwr_cnt<=dbg_vidwr_cnt+16'd1; dbg_vidwr_a<=cpu_addr; dbg_vidwr_d<=cpu_dout[15:0]; end
        if( snd_req ) dbg_sndwr_cnt <= dbg_sndwr_cnt + 16'd1;
        if( acc & wb_ack ) begin
            if( is_rom ) begin
                dbg_pcnow <= wb_adr[19:0];
                if( wb_adr[19:0] > dbg_pcmax ) dbg_pcmax <= wb_adr[19:0];
            end else if( ~wb_we ) begin   // non-ROM read -> the poll target
                dbg_poll_a <= wb_adr[23:0];
                dbg_poll_d <= wb_rdat;
                if( is_video ) begin                       // VIDEO read-back (our core returns 0)
                    dbg_vid_a     <= wb_adr[23:0];
                    dbg_vidrd_cnt <= dbg_vidrd_cnt + 16'd1;
                end
                if( is_ram & wb_adr[23:2]==22'h04_0000 )    // work-RAM control word @0x100000
                    dbg_ctl <= wb_rdat;
            end
        end
        // IRQ chain probes: count VBL IRQ pulses (source) and ARM IRQ-vector(0x18) entries (delivered)
        if( vbl_irq ) dbg_virq_cnt <= dbg_virq_cnt + 16'd1;
        at18_d <= (acc & wb_adr[23:0]==24'h000018);
        if( (acc & wb_adr[23:0]==24'h000018) & ~at18_d ) dbg_irq_cnt <= dbg_irq_cnt + 16'd1;
    end
end

always @(*) begin
    rom_cs = rom_fetch;          // SDRAM ROM slot driven ONLY on a cache miss/fill
    ram_cs = is_ram & acc;
end

// ---- read-data mux + Wishbone ack ----
//  ROM/RAM ack when the SDRAM slot returns ok; everything else acks in 1 cycle.
always @(*) begin
    wb_rdat = 32'h0;
    wb_ack  = 1'b0;
    if (acc) begin
        if (is_rom)       begin wb_rdat = rom_word; wb_ack = rom_ack; end // cached deco156-decrypted
        else if (is_ram)  begin wb_rdat = ram_data; wb_ack = ram_ok; end
        else if (is_prot) begin                                          // 104 I/O mux (nslasher_prot_r)
            wb_ack = 1'b1;
            case (wb_adr[11:0])
                12'h500: wb_rdat = { in0,    16'hffff };              // IN0    (offset<<1 = 0x280)
                12'h988: wb_rdat = { in1_eff, 16'hffff };             // IN1    (offset<<1 = 0x4c4)
                12'h6b4: wb_rdat = { 15'd0, eeprom_sdo, 16'hffff };   // EEPROM (offset<<1 = 0x35a)
                default: wb_rdat = 32'hffff_ffff;                     // unmapped prot
            endcase
        end
        else              begin wb_rdat = 32'h0;         wb_ack = 1'b1; end // unmapped: ack+ignore
    end
end

// ---- soundlatch + vbl-ack + irq latch (registered, paced) ----
always @(posedge clk) begin
    if (rst) begin
        snd_latch <= 8'd0; snd_req <= 1'b0; vbl_ack <= 1'b0; irq_l <= 1'b0;
        eeprom_sclk <= 1'b0; eeprom_sdi <= 1'b0; eeprom_scs <= 1'b0; pri <= 3'b0;
        cpu_we <= 4'd0; cpu_addr <= 24'd0; cpu_dout <= 32'd0;
    end else begin
        snd_req <= 1'b0;
        vbl_ack <= 1'b0;
        cpu_we  <= 4'd0;                  // default: one-clk write pulse
        if (vbl_irq) irq_l <= 1'b1;
        if (wr & wb_ack) begin       // UNGATED a23: capture every acked write (was cen_arm-gated for the 7.08MHz a23)
            // video-space write -> surface a clean transaction to jtnslasher_game's video map
            if (is_video) begin cpu_we <= wb_sel; cpu_addr <= wb_adr[23:0]; cpu_dout <= wb_wdat; end
            // soundlatch: 32-bit write to 0x200700, command in bits [23:16] (MAME data>>16)
            if (is_prot & (wb_adr[11:0]==12'h700)) begin
                snd_latch <= wb_wdat[23:16];
                snd_req   <= 1'b1;
            end
            // VBlank acknowledge clears the IRQ
            if (is_vbl) begin
                irq_l   <= 1'b0;
                vbl_ack <= 1'b1;
            end
            // EEPROM / priority (nslasher_eeprom_w @ 0x150000, ACCESSING_BITS_0_7 = low byte)
            if (is_eeprom & wb_sel[0]) begin
                eeprom_sclk <= wb_wdat[5];    // 0x20 -> serial clock  (eeprom_set_clock_line)
                eeprom_sdi  <= wb_wdat[4];    // 0x10 -> serial data   (eeprom_write_bit)
                // 0x40: MAME eeprom_set_cs_line((data&0x40)?CLEAR:ASSERT). In the old MAME eeprom
                // device CS is a reset-when-ASSERT line: the chip is ACTIVE when the line is CLEAR,
                // i.e. selected when data&0x40 is SET. jt9346 scs is active-high -> scs = data[6].
                eeprom_scs  <= wb_wdat[6];
                pri         <= {1'b0, wb_wdat[1:0]};  // nslasher_eeprom_w = deco32_pri_w(data&0x3) (deco32.c:650); bit2 forced 0 (NOT from the shared EEPROM byte) -> obj0 always RAW/full-colour, matching MAME (m_pri&4 never set)
            end
        end
    end
end

a23_core u_arm(
    .i_clk        ( clk        ),
    .i_reset      ( rst        ),
    .i_irq        ( irq_l      ),
    .i_firq       ( 1'b0       ),
    .i_system_rdy ( 1'b1       ),   // UNGATED: run a23 at full 48MHz (~6.8x). The Amber a23's L1 cache is
                                    // CP15-disabled on this bare ARM binary -> ~10.4 CPI -> ~6x slower than the
                                    // real deco156. The game is vblank-synced (IRQ proven 1:1) so it stays at
                                    // 60Hz; the overclock just lets the per-frame logic finish. Was cen_arm(7.08MHz).
    .o_wb_adr     ( wb_adr     ),
    .o_wb_sel     ( wb_sel     ),
    .o_wb_we      ( wb_we      ),
    .i_wb_dat     ( wb_rdat    ),
    .o_wb_dat     ( wb_wdat    ),
    .o_wb_cyc     ( wb_cyc     ),
    .o_wb_stb     ( wb_stb     ),
    .i_wb_ack     ( wb_ack     ),
    .i_wb_err     ( 1'b0       ),
    .o_wb_tga     ( wb_tga     )
);

// DIAG probe #1: non-zero PF-write capture (settle parked-vs-drawing). cpu_we is the registered
// one-clk video-write pulse, cpu_addr/cpu_dout held alongside it. See hdl/jtnslasher_vidprobe.v.
jtnslasher_vidprobe u_vidprobe(
    .rst      ( rst          ),
    .clk      ( clk          ),
    .cpu_addr ( cpu_addr     ),
    .cpu_dout ( cpu_dout     ),
    .cpu_we   ( cpu_we       ),
    .pfnz_cnt ( dbg_pfnz_cnt ),
    .pfnz_a   ( dbg_pfnz_a   ),
    .pfnz_d   ( dbg_pfnz_d   ),
    .anynz_a  ( dbg_anynz_a  ),
    .pal_cnt  ( dbg_pal_cnt  ),
    .pfbg_cnt ( dbg_pfbg_cnt ),
    .ctl_cnt  ( dbg_ctl_cnt  ),
    .ctl12_5  ( dbg_ctl12_5  ),
    .ctl34_5  ( dbg_ctl34_5  )
);

endmodule
