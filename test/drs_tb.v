module drs_tb;

//--------------------------------------------------------------------------------------------------------------------
// Clock Synthesis
//--------------------------------------------------------------------------------------------------------------------

reg clock33=0;

always @(*) begin
    clock33     <= # 15.000 ~clock33;
end

//--------------------------------------------------------------------------------------------------------------------
// Hold Reset
//--------------------------------------------------------------------------------------------------------------------

parameter STARTUP_RESET_CNT_MAX = 2**7-1;
parameter STARTUP_RESET_BITS    = $clog2 (STARTUP_RESET_CNT_MAX);

reg [STARTUP_RESET_BITS-1:0] startup_reset_cnt = 0;

always @ (posedge clock33) begin
  if (startup_reset_cnt < STARTUP_RESET_CNT_MAX)
    startup_reset_cnt <= startup_reset_cnt + 1'b1;
  else
    startup_reset_cnt <= startup_reset_cnt;
end

wire reset_drs = (startup_reset_cnt < STARTUP_RESET_CNT_MAX);

//--------------------------------------------------------------------------------------------------------------------
// CONFIGURE
//--------------------------------------------------------------------------------------------------------------------

parameter CONFIGURE_CNT_MAX = 2**7-1;
parameter CONFIGURE_BITS    = $clog2 (CONFIGURE_CNT_MAX);

reg [CONFIGURE_BITS-1:0] configure_cnt = 0;

always @ (posedge clock33) begin
  if (reset_drs)
    configure_cnt <= 0;
  else if (configure_cnt < CONFIGURE_CNT_MAX)
    configure_cnt <= configure_cnt + 1'b1;
  else
    configure_cnt <= configure_cnt;
end

reg configured=0;
always @(*) if (configure) configured <= 1'b1;

wire configure = (configure_cnt == CONFIGURE_CNT_MAX-1);

//--------------------------------------------------------------------------------------------------------------------
// START
//--------------------------------------------------------------------------------------------------------------------

parameter STARTUP_CNT_MAX = 2**7-1;
parameter STARTUP_BITS    = $clog2 (STARTUP_CNT_MAX);

reg [STARTUP_BITS-1:0] startup_cnt = 0;

always @ (posedge clock33) begin
  if (!configured)
    startup_cnt <= 0;
  else if (startup_cnt < STARTUP_CNT_MAX)
    startup_cnt <= startup_cnt + 1'b1;
  else
    startup_cnt <= startup_cnt;
end

reg started=0;
always @(*) if (start) started <= 1'b1;

wire start = (startup_cnt == STARTUP_CNT_MAX-1);

//--------------------------------------------------------------------------------------------------------------------
// TRIGGER
//--------------------------------------------------------------------------------------------------------------------

parameter TRIGGER_CNT_MAX = 2**12-1;
parameter TRIGGER_BITS    = $clog2 (TRIGGER_CNT_MAX);

reg [TRIGGER_BITS-1:0] trigger_cnt = 0;

always @ (posedge clock33) begin
  if (!started)
    trigger_cnt <= 0;
  else if (!reset_drs)
    trigger_cnt <= trigger_cnt + 1'b1;
  else
    trigger_cnt <= 0;
end

wire trigger = &trigger_cnt;

//--------------------------------------------------------------------------------------------------------------------
// ADC DATA
//--------------------------------------------------------------------------------------------------------------------

wire [13:0] adc_data = 0;

//--------------------------------------------------------------------------------------------------------------------
// Config
//--------------------------------------------------------------------------------------------------------------------

wire       roi_mode = 1'b1; // 1=ROI
wire       dmode        = 1'b1; // 1=continuous
wire       reinit       = 1'b0;
wire [8:0] readout_mask = 9'b1;
wire       standby_mode = 1'b0;
wire       transp_mode  = 1'b0;
wire [7:0] drs_config   = 8'haa;
wire [7:0] chn_config   = 8'h55;


//--------------------------------------------------------------------------------------------------------------------
// DRS
//--------------------------------------------------------------------------------------------------------------------

// outputs
wire [3:0]  drs_addr_o;    // Address Bit Inputs
wire        drs_denable_o; // Domino Enable Input. A low-to-high transition starts the Domino Wave. Set-ting this input low stops the Domino Wave.
wire        drs_dwrite_o;  // Domino Write Input. Connects the Domino Wave Circuit to the Sampling Cells to enable sampling if high.
wire        drs_rsrload_o; // Read Shift Register Load Input
wire        drs_srclk_o;   // Multiplexed Shift Register Clock Input
wire        drs_srin_o;    // Shared Shift Register Input
wire        drs_wsrin_o;   // Write Shift Register Input. Connected to WSROUT of previous chip for chip daisy-chaining

// inputs
wire       drs_srout_i=1'b0;   // Multiplexed Shift Register Output
wire       drs_wsrout_i=1'b0;  // Double function: Write Shift Register Output if DWRITE=1, Read Shift Register Output if DWRITE=0.

drs drs (
  .clock                 ( clock33),
  .reset                 ( reset_drs),
  .trigger_i             ( trigger),
  .adc_data_i            ( adc_data),

  .drs_ctl_roi_mode      ( roi_mode),
  .drs_ctl_dmode         ( dmode),
  .drs_ctl_config        ( drs_config[7:0]),
  .drs_ctl_chn_config    ( chn_config[7:0]),
  .drs_ctl_standby_mode  ( standby_mode),
  .drs_ctl_transp_mode   ( transp_mode),

  .drs_ctl_start         ( start),
  .drs_ctl_reinit        ( reinit),
  .drs_ctl_configure_drs ( configure),
  .drs_ctl_readout_mask  ( readout_mask),

  .drs_addr_o            ( drs_addr_o),
  .drs_denable_o         ( drs_denable_o),
  .drs_dwrite_o          ( drs_dwrite_o),
  .drs_rsrload_o         ( drs_rsrload_o),
  .drs_srclk_o           ( drs_srclk_o),
  .drs_srout_i           ( drs_srout_i),
  .drs_srin_o            ( drs_srin_o),

  .rd_data               ( rd_data),
  .rd_enable             ( rd_enable),
  .rd_clock              ( rd_clock)

);



endmodule
