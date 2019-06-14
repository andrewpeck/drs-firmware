// TODO: ADC clock phase??
// TODO: ADC setup/hold constraints
// Data outputs are available one propagation delay (tPD = 2ns -- 6ns) after the rising edge of the clock signal.
`define IOB (*IOB="true"*)
module daq_board_top #(
  parameter READ_WIDTH = 16
) (

    // ~ 33MHz ADC clock
    input clock_i_p,
    input clock_i_n,

    // adc
    input [13:0] adc_data_i,

    // drs io
    input        drs_srout_i,   // Multiplexed Shift Register Output

    output [3:0] drs_addr_o,    // Address Bit Inputs
    output       drs_denable_o, // Domino Enable Input. A low-to-high transition starts the Domino Wave. Set-ting this input low stops the Domino Wave.
    output       drs_dwrite_o,  // Domino Write Input. Connects the Domino Wave Circuit to the Sampling Cells to enable sampling if high.
    output       drs_rsrload_o, // Read Shift Register Load Input
    output       drs_srclk_o,   // Multiplexed Shift Register Clock Input
    output       drs_srin_o,    // Shared Shift Register Input
    output       drs_reset_o,   //
    input        drs_plllock_i, //
    input        drs_dtap_i,    //

    inout [10:0] gpio_p,
    inout [10:0] gpio_n

);

//----------------------------------------------------------------------------------------------------------------------
// MMCM / PLL
//----------------------------------------------------------------------------------------------------------------------

wire clock;
wire locked;
wire reset = ~locked;

clock_wizard clocking (
  .clk_out(clock),
  .reset(1'b0),
  .locked(locked),
  .clk_in1_p(clock_i_p),
  .clk_in1_n(clock_i_n)
 );

//---------------------------------------------------------------------------------------------------------------------
// Trigger Input
//---------------------------------------------------------------------------------------------------------------------

wire trigger_i;
reg trigger;
IBUFDS #(
    .DIFF_TERM("TRUE"),    // Differential Termination
    .IBUF_LOW_PWR("TRUE"), // Low power="TRUE", Highest performance="FALSE"
    .IOSTANDARD("LVDS_25") // Specify the input I/O standard
) ibuftrigger (            //
    .O(trigger_i),           // Buffer output
    .I(gpio_p[0]),         // Diff_p buffer input (connect directly to top-level port)
    .IB(gpio_n[0])         // Diff_n buffer input (connect directly to top-level port)
);

always @ (posedge clock)
  trigger <= trigger_i;

//---------------------------------------------------------------------------------------------------------------------
// SRCLK ODDR
//---------------------------------------------------------------------------------------------------------------------

// put srclk on an oddr
ODDR #(                           //
  .DDR_CLK_EDGE("OPPOSITE_EDGE"), // "OPPOSITE_EDGE" or "SAME_EDGE"
  .INIT(1'b0),                    // Initial value of Q: 1'b0 or 1'b1
  .SRTYPE("SYNC")                 // Set/Reset type: "SYNC" or "ASYNC"
) drs_srclk_oddr (                //
  .Q(drs_srclk_o),                // 1-bit DDR output
  .C(clock),                      // 1-bit clock input
  .CE(1'b1),                      // 1-bit clock enable input
  .D1(1'b1),                      // 1-bit data input (positive edge)
  .D2(1'b0),                      // 1-bit data input (negative edge)
  .R(~drs_srclk_en),            // 1-bit reset
  .S(1'b0)                        // 1-bit set
);

//----------------------------------------------------------------------------------------------------------------------
// DRS inputs
//----------------------------------------------------------------------------------------------------------------------

reg drs_plllock=0;
reg drs_dtap=0;

always @(posedge clock) begin
  drs_plllock <= drs_plllock;
  drs_dtap    <= drs_dtap;
end

//----------------------------------------------------------------------------------------------------------------------
// DRS configuration (should be AXI + chipscope or something)
//----------------------------------------------------------------------------------------------------------------------

wire       resync;

wire busy;
wire       roi_mode         = 1'b1; // 1=ROI
wire       dmode            = 1'b1; // 1=continuous
wire       reinit           = 1'b0;
wire       configure        = 1'b0;
wire [8:0] readout_mask     = 9'b1;
wire       standby_mode     = 1'b0;
wire       transp_mode      = 1'b0;
wire [7:0] drs_config       = 7'h00;
wire [7:0] chn_config       = 7'h00;
wire [56:0] dna;
reg [5:0]  start_latency    = 0;
reg [10:0] sample_count_max = 1024;

//----------------------------------------------------------------------------------------------------------------------
// Read data (send to axi stream etc)
//----------------------------------------------------------------------------------------------------------------------

wire [15:0] rd_data;
wire rd_enable = 1'b1;
wire rd_clock = clock;

//----------------------------------------------------------------------------------------------------------------------
// Timestamp (or something like this to identify events
//----------------------------------------------------------------------------------------------------------------------

reg [47:0] timestamp=0;
always @(posedge clock) begin
  if (reset || resync)
    timestamp <= 0;
  else
    timestamp <= timestamp + 1'b1;
end

//----------------------------------------------------------------------------------------------------------------------
// Event counter to identify events
//----------------------------------------------------------------------------------------------------------------------

reg [31:0] event_counter=0;
always @(posedge clock) begin
  if (reset || resync)
    event_counter <= 0;
  else if (trigger)
    event_counter <= event_counter + 1'b1;
end

//----------------------------------------------------------------------------------------------------------------------
// Lost event counter due to deadtime
//----------------------------------------------------------------------------------------------------------------------

reg [15:0] lost_event_counter=0;
always @(posedge clock) begin
  if (reset || resync)
    lost_event_counter <= 0;
  else if (trigger && busy)
    lost_event_counter <= lost_event_counter + 1'b1;
end

//----------------------------------------------------------------------------------------------------------------------
// DRS Control Module
//----------------------------------------------------------------------------------------------------------------------

drs drs (

  .clock                     (clock),
  .reset                     (reset),
  .trigger_i                 (trigger),
  .timestamp_i               (timestamp),
  .dna_i                     (dna[15:0]),
  .event_counter_i           (event_counter),

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

  .drs_srout_i               (drs_srout_i),

  .drs_addr_o                (drs_addr_o[3:0]),
  .drs_nreset_o              (drs_nreset_o),
  .drs_denable_o             (drs_denable_o),
  .drs_dwrite_o              (drs_dwrite),
  .drs_rsrload_o             (drs_rsrload_o),
  .drs_srclk_en_o            (drs_srclk_en),
  .drs_srin_o                (drs_srin_o),

  .rd_data                   (rd_data[15:0]),
  .rd_enable                 (rd_enable),
  .rd_clock                  (rd_clock),

  .busy_o                    (busy)

);


//trigger_delay trigger_delay (
//.clock(clock),
//.coarse_delay(coarse_delay),
//.d (),
//.q ()
//);


//----------------------------------------------------------------------------------------------------------------------
// Soft Error Mitigation
//----------------------------------------------------------------------------------------------------------------------

// TODO add counters

sem_wrapper sem_wrapper (
  .clk_i            (clock),
  .correction_o     (sem_correction),
  .classification_o (sem_classification),
  .uncorrectable_o  (sem_uncorrectable_error),
  .heartbeat_o      (sem_heartbeat),
  .initialization_o (sem_initialization),
  .observation_o    (sem_observation),
  .essential_o      (sem_essential),
  .sump             (sump_sem)
);

counter #(
  .g_COUNTER_WIDTH (16)
) u_sem_correction_cnt (
  .clk_i (clock),
  .rst_i (reset),
  .en_i  (sem_correction),
  .count_o (sem_correction_cnt)
);

//----------------------------------------------------------------------------------------------------------------------
// Device DNA in case it is useful
//----------------------------------------------------------------------------------------------------------------------

device_dna device_dna (
.clock(clock),
.reset(reset),
.dna (dna)
);

//----------------------------------------------------------------------------------------------------------------------
//
//----------------------------------------------------------------------------------------------------------------------

assign sump = |rd_data | sump_sem;

endmodule

