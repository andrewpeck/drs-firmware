module daq_board_top #(
  parameter READ_WIDTH = 16
) (

    // ~ 33MHz ADC clock
    input clock_i_p,
    input clock_i_n,

    // master trigger
    input trigger_i_p,
    input trigger_i_n,

    // adc
    input [13:0] adc_data_i,

    // drs io
    input             drs_srout_i,   // Multiplexed Shift Register Output

    output [3:0]  drs_addr_o, // Address Bit Inputs
    output drs_denable_o,     // Domino Enable Input. A low-to-high transition starts the Domino Wave. Set-ting this input low stops the Domino Wave.
    output drs_dwrite_o,      // Domino Write Input. Connects the Domino Wave Circuit to the Sampling Cells to enable sampling if high.
    output drs_rsrload_o,     // Read Shift Register Load Input
    output drs_srclk_o,       // Multiplexed Shift Register Clock Input
    output drs_srin_o,        // Shared Shift Register Input
    output drs_reset_o   ,    //
    input  drs_plllock_i   ,   //
    input  drs_dtap_i   ,      //

    output [10:0] gpio_p,
    output [10:0] gpio_n,

    output sump

);

assign gpio_p = {11{drs_reset_o}};
assign gpio_n = {11{drs_reset_o}};

wire clock;
wire locked;
clock_wizard clocking (
  .clk_out(clock),
  .reset(1'b0),
  .locked(locked),
  .clk_in1_p(clock_i_p),
  .clk_in1_n(clock_i_n)
 );

wire trigger;

IBUFDS #(
	.DIFF_TERM("FALSE"),       // Differential Termination
	.IBUF_LOW_PWR("TRUE"),     // Low power="TRUE", Highest performance="FALSE"
	.IOSTANDARD("DEFAULT")     // Specify the input I/O standard
) ibuftrigger (
	.O(trigger),  // Buffer output
	.I(trigger_i_p),  // Diff_p buffer input (connect directly to top-level port)
	.IB(trigger_i_n) // Diff_n buffer input (connect directly to top-level port)
);

wire       roi_mode     = 1'b1; // 1=ROI
wire       dmode        = 1'b1; // 1=continuous
wire       reinit       = 1'b0;
wire       configure    = 1'b0;
wire [8:0] readout_mask = 9'b1;
wire       standby_mode = 1'b0;
wire       transp_mode  = 1'b0;
wire [7:0] drs_config   = 7'h00;
wire [7:0] chn_config   = 7'h00;


wire [15:0] rd_data;
wire rd_enable = 1'b1;
wire rd_clock = clock;

reg [47:0] timestamp=0;
always @(posedge clock) begin
  timestamp <= timestamp + 1'b1;
end

reg [5:0]  start_latency=0;
reg [10:0] sample_count_max=1024;

drs drs (

  .clock                     (clock),
  .reset                     (~locked),
  .trigger_i                 (trigger),
  .timestamp_i               (timestamp),
  .adc_data_i                (adc_data_i),
  .drs_ctl_roi_mode          (roi_mode),
  .drs_ctl_dmode             (dmode),
  .drs_ctl_config            (drs_config[7:0]),
  .drs_ctl_standby_mode      (standby_mode),
  .drs_ctl_transp_mode       (transp_mode),
  .drs_ctl_start             (start),
  .drs_ctl_start_latency     (start_latency),
  .drs_ctl_sample_count_max  (sample_count_max),
  .drs_ctl_reinit            (reinit),
  .drs_ctl_configure_drs     (configure),
  .drs_ctl_chn_config        (chn_config[7:0]),
  .drs_ctl_readout_mask      (readout_mask[8:0]),
  .drs_addr_o                (drs_addr_o[3:0]),
  .drs_denable_o             (drs_denable_o),
  .drs_dwrite_o              (drs_dwrite_o),
  .drs_rsrload_o             (drs_rsrload_o),
  .drs_srclk_o               (drs_srclk_o),
  .drs_srout_i               (drs_srout_i),
  .drs_srin_o                (drs_srin_o),
  .rd_data                   (rd_data[15:0]),
  .rd_enable                 (rd_enable),
  .rd_clock                  (rd_clock)

);

assign sump = |rd_data;

endmodule

