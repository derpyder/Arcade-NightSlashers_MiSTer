`timescale 1ns/1ps
// Drive the REAL jtnslasher_obj.v draw FSM with a controllable obj0 rom_ok model:
// ideal, delayed-then-ok, NEVER-ok (permanent stall), and ok-with-stale-prev-data.
// After the line, scan 16 columns of the sprite and count DISTINCT pen values written.
// Mechanism question: can a stall collapse all 16 columns to ONE pen (uniform) or only
// leave them blank (transparent)?

module tb_objstall;
  localparam BPP=5;
  reg clk=0, rst=1, pxl_cen=0;
  always #5 clk=~clk;

  reg HS=0, LVBL=1, LHBL=1;
  reg [8:0] vrender=9'd100, hdump=0;

  wire [9:0] dut_tbl_addr;
  reg  [15:0] tbl_mem [0:1023];
  reg  [15:0] tbl_dout;

  wire        rom_cs;
  wire [20:0] rom_addr;
  reg  [8*BPP-1:0] rom_data;
  reg         rom_ok;
  wire [15:0] pxl;

  integer ROM_MODE, DELAY;
  reg [8*BPP-1:0] rom_data_table [0:65535];
  integer ok_ctr;
  reg prev_cs;
  reg [8*BPP-1:0] last_data;

  always @(posedge clk) begin
    if(rst) begin rom_ok<=0; rom_data<=0; ok_ctr<=0; prev_cs<=0; last_data<=0; end
    else begin
      prev_cs <= rom_cs;
      if( rom_cs && !prev_cs ) ok_ctr <= 0;
      else if( rom_cs ) ok_ctr <= ok_ctr+1;
      if( !rom_cs ) begin rom_ok<=0; ok_ctr<=0; end
      else begin
        if(ROM_MODE==0) begin rom_ok<=1; rom_data <= rom_data_table[rom_addr[15:0]]; end
        else if(ROM_MODE==1) begin
          if(ok_ctr>=DELAY) begin rom_ok<=1; rom_data<=rom_data_table[rom_addr[15:0]]; end
          else rom_ok<=0;
        end
        else if(ROM_MODE==2) begin rom_ok<=0; rom_data<=0; end
        // MODE4: first half ok, second half (addr bit0==1) never ok -> half stall
        else if(ROM_MODE==4) begin
          if(rom_addr[0]==1'b1) rom_ok<=0; else begin rom_ok<=1; rom_data<=rom_data_table[rom_addr[15:0]]; end
        end
        else begin rom_ok<=1; rom_data<=last_data; end
      end
      if( rom_cs ) last_data<=rom_data_table[rom_addr[15:0]];
    end
  end

  always @(posedge clk) tbl_dout <= tbl_mem[dut_tbl_addr];

  jtnslasher_obj #(.BPP(BPP)) u_obj(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .HS(HS), .LVBL(LVBL), .LHBL(LHBL),
    .vrender(vrender), .hdump(hdump),
    .tbl_addr(dut_tbl_addr), .tbl_dout(tbl_dout),
    .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
    .pxl(pxl)
  );

  integer i, a, b;
  reg [7:0] penval [0:15];
  integer dc, nzc;
  reg found;

  task scan_tile(input [8:0] x0); begin
    for(i=0;i<16;i=i+1) begin
      hdump <= x0 + i[8:0];
      @(posedge clk);
      pxl_cen<=1; @(posedge clk); pxl_cen<=0; @(posedge clk);
      penval[i] = pxl[7:0];
    end
  end endtask

  task tally; begin
    dc=0; nzc=0;
    for(a=0;a<16;a=a+1) begin
      if(penval[a]!=0) nzc=nzc+1;
      found=0;
      for(b=0;b<a;b=b+1) if(penval[b]==penval[a]) found=1;
      if(!found) dc=dc+1;
    end
  end endtask

  task show(input [80*8-1:0] label); begin
    tally;
    $display("%0s distinct=%0d nonzero=%0d  c0..c15 = %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
      label, dc, nzc,
      penval[0],penval[1],penval[2],penval[3],penval[4],penval[5],penval[6],penval[7],
      penval[8],penval[9],penval[10],penval[11],penval[12],penval[13],penval[14],penval[15]);
  end endtask

  function [7:0] gen_plane(input integer plane); integer c; reg [7:0] v; begin
    v=0;
    for(c=0;c<8;c=c+1) if( ((c+1) >> plane) & 1 ) v[7-c]=1'b1;
    gen_plane=v;
  end endfunction

  task setup_table; integer k; begin
    tbl_mem[0] = 16'd92;          // y=92, vrender=100 -> veff=8, msz=0
    tbl_mem[1] = 16'h0010;        // code 0x10
    tbl_mem[2] = {7'h05, 9'h040}; // x=0x40, colour hi bits
    tbl_mem[3] = 16'h0000;
    for(k=4;k<1024;k=k+1) tbl_mem[k] = 16'h00ff;  // y=255 -> out of zone -> skip
  end endtask

  task run_one_line; begin
    HS<=1; @(posedge clk); @(posedge clk); HS<=0;
    repeat(2500) @(posedge clk);
  end endtask

  task clear_buf; integer z; begin
    for(z=0;z<4;z=z+1) begin LHBL<=0; repeat(20) @(posedge clk); LHBL<=1; repeat(20) @(posedge clk); end
  end endtask

  // capture EVERY OPAQUE write (pen!=0) the engine makes this run; tally distinct pens + count.
  integer wr_count, opaque_count;
  reg run_active=0;
  reg [7:0] wpen [0:511];
  reg [8:0] waddr_seen [0:511];
  always @(posedge clk) begin
    if(rst) begin wr_count<=0; opaque_count<=0; end
    else if(run_active && u_obj.buf_we) begin
      // is_opaque test mirrors the buffer: low-ALPHAW(8) bits != 0
      if( u_obj.buf_wdata[7:0]!=0 ) begin
        wpen[opaque_count] <= u_obj.buf_wdata[7:0];
        waddr_seen[opaque_count] <= u_obj.buf_waddr;
        opaque_count <= opaque_count+1;
      end
      wr_count <= wr_count+1;
    end
  end

  task report_writes(input [80*8-1:0] label); integer p,q; reg fnd; integer distinctw; begin
    distinctw=0;
    for(p=0;p<opaque_count;p=p+1) begin
      fnd=0;
      for(q=0;q<p;q=q+1) if(wpen[q]==wpen[p]) fnd=1;
      if(!fnd) distinctw=distinctw+1;
    end
    $display("%0s opaque_writes=%0d distinct_pens=%0d  first8: %02x %02x %02x %02x %02x %02x %02x %02x",
      label, opaque_count, distinctw,
      wpen[0],wpen[1],wpen[2],wpen[3],wpen[4],wpen[5],wpen[6],wpen[7]);
  end endtask

  task reset_capture; begin opaque_count=0; wr_count=0; end endtask

  integer t;
  initial begin
    for(t=0;t<65536;t=t+1)
      rom_data_table[t] = { gen_plane(4), gen_plane(3), gen_plane(2), gen_plane(1), gen_plane(0) };

    setup_table;
    rst=1; repeat(8) @(posedge clk); rst=0; repeat(4) @(posedge clk);

    run_active=1;
    reset_capture; ROM_MODE=0; DELAY=0;  run_one_line; report_writes("MODE0 ideal      :");
    reset_capture; ROM_MODE=1; DELAY=30; run_one_line; report_writes("MODE1 delayed30  :");
    reset_capture; ROM_MODE=2; DELAY=0;  run_one_line; report_writes("MODE2 never-ok   :");
    reset_capture; ROM_MODE=3; DELAY=0;  run_one_line; report_writes("MODE3 stale-data :");
    // MODE1 with a HUGE delay > the per-tile window but engine keeps waiting (true stall mid-draw)
    reset_capture; ROM_MODE=1; DELAY=5000; run_one_line; report_writes("MODE1 delay5000  :");
    reset_capture; ROM_MODE=4; DELAY=0;    run_one_line; report_writes("MODE4 half-stall :");

    $finish;
  end

  initial begin #50_000_000; $display("TIMEOUT"); $finish; end
endmodule
