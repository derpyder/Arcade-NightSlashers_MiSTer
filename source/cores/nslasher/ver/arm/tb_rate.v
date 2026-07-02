`timescale 1ns/1ps
// tb_rate.v — pure timing check: cen_arm rate, vbl rate, ARM cycles/frame. No ARM (fast).
module tb_rate;
    localparam real CLK_NS = 20.8333;     // 48 MHz
    reg clk=0; always #(CLK_NS/2.0) clk=~clk;

    // cen_arm = frac accumulator 7753/52559 (W=1 frac_cen equivalent)
    localparam [16:0] FC_N=17'd7753, FC_M=17'd52559;
    reg [16:0] fc_cnt=0;
    wire [16:0] fc_next = fc_cnt + FC_N;
    wire fc_over = fc_next >= FC_M;
    reg cen_arm=0;
    always @(posedge clk) begin
        cen_arm<=0;
        if(fc_cnt>=(FC_M+FC_N)) fc_cnt<=0;
        else if(fc_over) begin fc_cnt<=fc_next-FC_M; cen_arm<=1; end
        else fc_cnt<=fc_next;
    end

    // pxl_cen = 6 MHz = 48/8
    reg [2:0] pxdiv=0; reg pxl_cen=0;
    always @(posedge clk) begin pxdiv<=pxdiv+3'd1; pxl_cen<=(pxdiv==3'd7); end

    // vtimer model: 384 H x 264 V, vblank at line 240
    localparam [8:0] HTOTAL=9'd384, VTOTAL=9'd264, VB_START=9'd240;
    reg [8:0] hcnt=0, vcnt=0; reg LVBL=1;
    always @(posedge clk) if(pxl_cen) begin
        if(hcnt==HTOTAL-1) begin hcnt<=0; if(vcnt==VTOTAL-1) vcnt<=0; else vcnt<=vcnt+9'd1; end
        else hcnt<=hcnt+9'd1;
        LVBL <= (vcnt<VB_START);
    end
    reg LVBLl; reg vbl_irq;
    always @(posedge clk) begin LVBLl<=LVBL; vbl_irq<=LVBLl & ~LVBL; end

    // count cen_arm pulses per vbl_irq period; count clk per period
    integer cen_in_frame=0, clk_in_frame=0;
    integer frame=0;
    real t_prev=0, t_now;
    integer total_cen=0;
    always @(posedge clk) begin
        if(cen_arm) begin cen_in_frame<=cen_in_frame+1; total_cen<=total_cen+1; end
        clk_in_frame<=clk_in_frame+1;
        if(vbl_irq) begin
            t_now=$realtime;
            frame<=frame+1;
            if(frame>0 && frame<=12)
                $display("frame %0d: %0d cen_arm (ARM cycles) , %0d clk , period=%.1f us (%.3f Hz)",
                    frame, cen_in_frame, clk_in_frame, (t_now-t_prev)/1000.0, 1e9/(t_now-t_prev));
            t_prev=t_now; cen_in_frame<=0; clk_in_frame<=0;
        end
    end

    initial begin
        #60000000;   // 60 ms = ~3.5 frames... extend
        $finish;
    end
    initial #300000000 $finish;  // hard stop 300ms
endmodule
