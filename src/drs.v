`define IOB (*IOB="true"*)
// synthesis translate_off
`define SIMULATION
// synthesis translate_on

// TODO: implement ROI trigger delay
// TODO: figure out what roi old mode does and (possibly?) implement it
// TODO: tmr

module drs #(
  parameter TMR_INST = 0,
  parameter READ_WIDTH = 16
) (
    //------------------------------------------------------------------------------------------------------------------
    // system
    //------------------------------------------------------------------------------------------------------------------

    // ~ 33MHz ADC clock
    input clock,

    // module reset
    input reset,

    // timestamp counter
    input [47:0] timestamp_i,

    // event counter
    input [31:0] event_counter_i,

    // master trigger
    input trigger_i,

    //------------------------------------------------------------------------------------------------------------------
    // adc
    //------------------------------------------------------------------------------------------------------------------

    input [13:0] adc_data_i, // 14 bit adc data @ 33 MHz


    //------------------------------------------------------------------------------------------------------------------
    // drs control
    //------------------------------------------------------------------------------------------------------------------

    input        drs_ctl_roi_mode,                // set 1 for region of interest mode
    input        drs_ctl_dmode,                   // set 1 = continuous domino, 0=single shot
    input [5:0]  drs_ctl_start_latency,           // latency from first sr clock to when adc data should be valid
                                                  // correlates with ADC conversion latency
                                                  //
    input [10:0] drs_ctl_sample_count_max,        // number of samples to readout
                                                  //
    input [7:0]  drs_ctl_config,                  // configuration register
                                                  // Bit0  DMODE  Control Domino Mode. A 1 means continuous cycling, a 0 configures a single shot
                                                  // Bit1  PLLEN  Enable bit for the PLL. A 1 enables the operation of the internal PLL
                                                  // Bit2  WSRLOOP  Connect WSRIN internally to WSROUT if set to 1
                                                  // Bit3-7  Reserved  A 1 must always be written to these bit positions
                                                  //
    input       drs_ctl_standby_mode,             // set 1 = shutdown drs4
    input       drs_ctl_transp_mode,              // set 1 = transparent mode
    input       drs_ctl_start,                    // pulse 1 = take the state machine out of idle mode
    input       drs_ctl_reinit,                   // pulse 1 = re-initialize the state machine
    input       drs_ctl_configure_drs,            // pulse 1 = to configure the DRS
                                                  //
    input [7:0] drs_ctl_chn_config,               // Write Shift Register Configuration
                                                  // # of chn | # of cells per ch | bit pattern
                                                  // 8        | 1024              | 11111111 b
                                                  // 4        | 2048              | 01010101 b
                                                  // 2        | 4096              | 00010001 b
                                                  // 1        | 8192              | 00000001
                                                  //
    input [8:0] drs_ctl_readout_mask,             // set a bit to '1' to enable readout of its channel

    //------------------------------------------------------------------------------------------------------------------
    // drs io
    //------------------------------------------------------------------------------------------------------------------

    input             drs_srout_i,    // Multiplexed Shift Register Output
    output reg [3:0]  drs_addr_o,     // Address Bit Inputs
    output reg        drs_denable_o,  // Domino Enable Input. A low-to-high transition starts the Domino Wave. Set-ting this input low stops the Domino Wave.
    output reg        drs_dwrite_o,   // Domino Write Input. Connects the Domino Wave Circuit to the Sampling Cells to enable sampling if high.
    output reg        drs_rsrload_o,  // Read Shift Register Load Input
    output            drs_srclk_en_o, // Multiplexed Shift Register Clock Input
    output reg        drs_srin_o,     // Shared Shift Register Input
    output reg        drs_on_o   ,    //

    //------------------------------------------------------------------------------------------------------------------
    // output fifo
    //------------------------------------------------------------------------------------------------------------------

    output [READ_WIDTH-1:0] rd_data,
    input                   rd_enable,
    input                   rd_clock,

    //------------------------------------------------------------------------------------------------------------------
    // status
    //------------------------------------------------------------------------------------------------------------------
    output busy_o // drs is doing a readout
);

localparam ADR_TRANSPARENT = 4'b1010;
localparam ADR_READ_SR     = 4'b1011;
localparam ADR_WRITE_SR    = 4'b1101;
localparam ADR_CONFIG      = 4'b1100;
localparam ADR_STANDBY     = 4'b1111;

//----------------------------------------------------------------------------------------------------------------------
// Input flops
//----------------------------------------------------------------------------------------------------------------------

reg [13:0] adc_data;

always @(posedge clock) begin
  adc_data <= adc_data_i;
end

//----------------------------------------------------------------------------------------------------------------------
// Trigger + timestamp
//----------------------------------------------------------------------------------------------------------------------

reg [47:0] timestamp;
reg [31:0] event_counter;
reg trigger, domino_ready;
reg trigger_last;
always @(posedge clock) begin
  trigger <= (|drs_ctl_readout_mask && domino_ready) ? trigger_i : 0;

  // latch timestamp when there is a trigger
  if (trigger && !trigger_last) begin
    timestamp <= timestamp_i;
    event_counter <= event_counter_i;
  end
end

//----------------------------------------------------------------------------------------------------------------------
// First/Last/Next Channel Calculators for Mask Based Readout
//----------------------------------------------------------------------------------------------------------------------

reg [3:0] drs_ctl_first_chn;
reg [3:0] drs_ctl_last_chn;
reg [3:0] drs_ctl_next_chn;

reg [8:0] readout_mask_sr;

integer i,j,k;
always @(posedge clock) begin

  for( i = 8; i >= 0; i=i-1)
    if (readout_mask_sr[i])
        drs_ctl_next_chn=i;

  for( j = 8; j >= 0; j=j-1)
    if (drs_ctl_readout_mask[j])
        drs_ctl_first_chn=j;

  for( k = 0; k <= 8; k=k+1)
    if (drs_ctl_readout_mask[k])
        drs_ctl_last_chn=k;

end

//----------------------------------------------------------------------------------------------------------------------
// DRS DWrite
//----------------------------------------------------------------------------------------------------------------------

// i don't think these even makes sense
// why does initiating a trigger need to turn off d-write special here..? why not controlled by the sm
always @(posedge clock) begin
  if (trigger)
    drs_dwrite_o <= 1'b0;
  else
    drs_dwrite_o <= drs_dwrite_set;
end

//----------------------------------------------------------------------------------------------------------------------
// SRClk Forwarding
//----------------------------------------------------------------------------------------------------------------------

reg srclk_enable=1;
reg drs_srclk_enable=0;

//----------------------------------------------------------------------------------------------------------------------
// Other signals
//----------------------------------------------------------------------------------------------------------------------
reg [7:0]  drs_sr_reg;

// TODO: merge with the other counter
reg [6:0] drs_start_timer = 0; // startup timer to make sure the domino is running before allowing triggers

wire [21:0] crc;

//reg [7:0]  drs_stat_stop_wsr=0;
//reg        drs_stop_wsr=0;
reg [9:0]  drs_stop_cell=0;
reg [9:0]  drs_stat_stop_cell=0;
reg [10:0] drs_sample_count=0;
reg [12:0] drs_rd_tmp_count=0;
reg [10:0] drs_sr_count=0;

reg [3:0] drs_addr=0;

reg        drs_dwrite_set=0;
reg        drs_reinit_request=0;
//reg        drs_old_roi_mode=0;

reg [15:0] fifo_wdata=0;
reg        fifo_wen=0;
reg        fifo_wen_crc=0;
reg        fifo_reset=1;

reg drs_stat_busy=1;
assign busy_o = drs_stat_busy;

// wait ~120 us for VDD to stabilize
// wtf the math doesn't even make sense
// @ 33MHz (~30ns) 120 uS = count to 4000
// this is counting to 8191
wire wait_vdd_done = (drs_rd_tmp_count == 'h7ff);

wire shift_out_config_done = (drs_sr_count == 7);

//----------------------------------------------------------------------------------------------------------------------
// State machine parameters
//----------------------------------------------------------------------------------------------------------------------

localparam INIT          = 0;
localparam IDLE          = 1;
localparam START_RUNNING = 2;
localparam RUNNING       = 3;
localparam TRIGGER       = 4;
localparam WAIT_VDD      = 5;
localparam INIT_READOUT  = 6;
localparam LOAD_RSR      = 7;
localparam ADC_READOUT   = 8;
localparam STOP_CELL     = 9;
localparam TIMESTAMP     = 10;
localparam EVENT_CNT     = 11;
localparam DONE          = 13;
localparam CONF_SETUP    = 14;
localparam CONF_STROBE   = 15;
localparam WSR_ADDR      = 16;
localparam WSR_SETUP     = 17;
localparam WSR_STROBE    = 18;
localparam INIT_RSR      = 19;
localparam WR_CRC        = 20; // last

localparam MXSTATEBITS = $clog2(WR_CRC);


reg [MXSTATEBITS-1:0] drs_readout_state=0;

//----------------------------------------------------------------------------------------------------------------------
// State Machine
//----------------------------------------------------------------------------------------------------------------------

always @(posedge clock) begin

  if (reset) begin

  //------------------------------------------------------------------------------------------------------------
  // State
  //------------------------------------------------------------------------------------------------------------
  drs_readout_state <= INIT;

  //------------------------------------------------------------------------------------------------------------
  // Logic
  //------------------------------------------------------------------------------------------------------------

  // drs
  drs_denable_o        <= 0;     // domino waves disabled
  drs_srin_o           <= 0;
  drs_addr_o           <= ADR_STANDBY;  // standby
  drs_on_o             <= 1;
  drs_rsrload_o        <= 0;
  drs_dwrite_set       <= 0;
  drs_srclk_enable     <= 0;

  // fifo
  fifo_reset           <= 1;
  fifo_wdata           <= 0;
  fifo_wen             <= 0;
  fifo_wen_crc         <= 0;

  // internal
  drs_stat_busy        <= 0;
  drs_sample_count     <= 0;
  drs_rd_tmp_count     <= 0;
  drs_reinit_request   <= 1;
  domino_ready         <= 0;
  //drs_old_roi_mode <= 1;

  end

  else begin

  fifo_wen     <= 0;
  fifo_wen_crc <= 0;
  fifo_reset   <= 0;
  domino_ready <= 1;

  // Memorize a write access to the bit in the control register
  // that requests a reinitialisation of the DRS readout state
  // machine (drs_ctl_reinit goes high for only one cycle,
  // therefore this "trigger" is memorised).
  if (drs_ctl_reinit)
      drs_reinit_request <= 1;

  case (drs_readout_state)

    // INIT
    INIT: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state <= IDLE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          // disable clock
          drs_srclk_enable     <= 0;
          drs_rsrload_o        <= 0;
          drs_stat_busy        <= 0;
          drs_reinit_request   <= 0;
          drs_denable_o        <= 0;


    end // fini

    // IDLE
    IDLE: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
              drs_readout_state  <= INIT;
          else if (drs_ctl_start)
              drs_readout_state  <= START_RUNNING;

          // initialize
          if (drs_ctl_configure_drs)
              drs_readout_state  <= CONF_SETUP;

          // going out of region of interest mode
          //if (drs_old_roi_mode && ~drs_ctl_roi_mode)
          //    drs_readout_state  <= INIT_RSR;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          fifo_wen_crc         <= 0;
          drs_srclk_enable     <= 0; // disable clock
          drs_srin_o           <= 0;
          drs_rsrload_o        <= 0;
          drs_start_timer      <= 0;
          drs_stat_busy        <= 0;

          if (drs_ctl_standby_mode) begin
            drs_on_o   <= 0;           // DRS power off (test board)
            drs_addr_o <= ADR_STANDBY; // standby mode
          end
          else begin
            drs_on_o <= 1;
            if (drs_ctl_transp_mode)
              drs_addr_o <= ADR_TRANSPARENT;  // transparent mode
            else
              drs_addr_o <= ADR_READ_SR;  // address read shift register
          end

          if (~drs_reinit_request && drs_ctl_start)
            drs_stat_busy      <= 1;   // status reg. busy flag

          //  check high byte of drs_ctl_config register
          if (drs_ctl_configure_drs)
            drs_addr_o <= ADR_CONFIG;  // address config register

          // detect 1 to 0 transition of readout mode
          //drs_old_roi_mode <= drs_ctl_roi_mode;

          //if (drs_old_roi_mode && ~drs_ctl_roi_mode) begin
          //        drs_addr_o   <= ADR_READ_SR; // address read shift register
          //        drs_sr_count <= 0;
          //end

    end // fini

    // START RUNNING DOMINO
    START_RUNNING: begin


          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
              drs_readout_state  <= INIT;

          // do not go to running until at least 1.5 domino revolutions
          if (drs_start_timer == 105) // 105 * 30ns <= 3.15us
              drs_readout_state  <= RUNNING;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_denable_o    <= 1;   // enable and start domino wave
          domino_ready     <= 0;

          if (drs_start_timer==0)
            drs_dwrite_set <= 1;   // set drs_write_ff in proc_drs_write
          else
            drs_dwrite_set <= 0; // FIXME THIS MAKES NO SENSE WHY DOES IT GET SET TO 0 WTF??

          // do not go to running until at least 1.5 domino revolutions
          drs_start_timer  <= drs_start_timer + 1;
          if (drs_start_timer==105) // 105 * 30ns <= 3.15us
            domino_ready <= 1;  // arm trigger

    end // fini

    // WAIT FOR TRIGGER
    RUNNING: begin


          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
              drs_readout_state  <= INIT;
          if (drs_ctl_standby_mode)
              drs_readout_state  <= IDLE;

          // trigger received or DMODE <= 0? If so,
          // stop domino wave & start readout sequence
          // (DMODE=0 means single shot readout)

          if (trigger || drs_ctl_dmode == 1'b0)
              drs_readout_state  <= TRIGGER;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          // domino is running... waiting for trigger

    end // fini

    // STOP DOMINO
    TRIGGER: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state <= WAIT_VDD;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_addr             <= drs_ctl_first_chn;
          readout_mask_sr      <= drs_ctl_readout_mask;
          drs_addr_o           <= ADR_READ_SR;  // address write shift register for readout
          drs_sample_count     <= 0;
          drs_rd_tmp_count     <= 0;
          drs_stop_cell        <= 0;
          //drs_stop_wsr         <= 0;

    end // fini

    // WAIT FOR SUPPLY TO SETTLE BEFORE READOUT
    WAIT_VDD: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
            drs_readout_state <= INIT;

          if (drs_rd_tmp_count == 'h7ff)
            drs_readout_state <= INIT_READOUT;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_srclk_enable <= 0; // disable clock
          if (drs_rd_tmp_count == 'h7ff)
            drs_rd_tmp_count <= 0;
          else
            drs_rd_tmp_count <= drs_rd_tmp_count + 1'b1;

    end // fini

    // INITIATE READOUT
    INIT_READOUT: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
              drs_readout_state <= INIT;
          else
              drs_readout_state <= LOAD_RSR;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

    end // fini

    // LOAD THE STOP CELL INTO THE SHIFT REGISTER
    LOAD_RSR: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
              drs_readout_state <= INIT;
          else
              drs_readout_state <= ADC_READOUT;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_srclk_enable <= 0;    // disable clock
          drs_addr_o <= drs_addr; // select channel for readout

    end // fini

    // READOUT ADC
    ADC_READOUT: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_reinit_request)
              drs_readout_state <= INIT;

          // All cells & channels of DRS chips read ?
          if (drs_sample_count==drs_ctl_sample_count_max) begin
            if (drs_addr==drs_ctl_last_chn)
              drs_readout_state <= STOP_CELL;
          end

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          // It stores the cell number where the sampling has
          // been stopped and encodes this position in a 10 bit binary
          // number ranging from 0 to 1023. This encoded position is
          // clocked out to SROUT on the first ten readout clock cy-
          // cles, as can be seen in Figure 15. The rising edge of the
          // RSRLOAD signal outputs the MSB, while the falling
          // edges of the SRCLK signal reveal the following bits up
          // to the LSB.

          drs_srclk_enable <= 1; // enable clock

          // clock in the first 10 bits to get the stop cell
          if (drs_srclk_enable==1 && drs_rd_tmp_count < 11) begin
            drs_stop_cell[0]   <= drs_srout_i;
            drs_stop_cell[9:1] <= drs_stop_cell[8:0];
          end

          //if (drs_rd_tmp_count == 2 && (drs_addr == drs_ctl_first_chn))
          //  drs_stop_wsr <= drs_srout_i;   // sample last bit of WSR for first channel


          // ADC delivers data at its outputs with 7 clock cycles delay
          // with respect to its external clock pin
          if (drs_srclk_enable==1 && drs_rd_tmp_count > drs_ctl_start_latency) begin
            drs_sample_count  <= drs_sample_count + 1'b1;
            fifo_wdata[15:2]  <= adc_data[13:0];  // ADC data
            fifo_wdata[1:0]   <= 2'b00;
            fifo_wen          <= 1'b1;
          end

          // finished
          if (drs_sample_count == drs_ctl_sample_count_max) begin
            drs_sample_count   <= 0;
            drs_rd_tmp_count   <= 0;

            // write stop cell into register
            drs_stat_stop_cell <= drs_stop_cell;
            //drs_stat_stop_wsr  <= drs_stop_wsr;

            // increment channel address
            // change to mapping based "skip"

            if (drs_addr != drs_ctl_last_chn) begin
              drs_addr             <= drs_ctl_next_chn;
              readout_mask_sr[8:0] <= readout_mask_sr & ~(1'b1 << drs_ctl_next_chn);
            end
          end

    end // fini

    // APPEND THE STOP CELL
    STOP_CELL: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state <= TIMESTAMP;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          fifo_wdata[15:10] <= 5'b0;
          fifo_wdata[ 9: 0] <= drs_stop_cell;
          fifo_wen          <= 1;

    end // fini

    // APPEND A TIMESTAMP
    TIMESTAMP: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_rd_tmp_count == 2)
            drs_readout_state <= EVENT_CNT;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          if (drs_rd_tmp_count == 2)
            drs_rd_tmp_count <= 0;
          else
            drs_rd_tmp_count <= drs_rd_tmp_count + 1'b1;

          fifo_wdata[15:0]  <= timestamp[16*drs_rd_tmp_count+:16];
          fifo_wen          <= 1;

    end // fini

    // APPEND THE EVENT COUNT
    EVENT_CNT: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_rd_tmp_count == 1)
            drs_readout_state <= DONE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          if (drs_rd_tmp_count == 1)
            drs_rd_tmp_count <= 0;
          else
            drs_rd_tmp_count <= drs_rd_tmp_count + 1'b1;

          fifo_wdata[15:0]  <= event_counter[16*drs_rd_tmp_count+:16];
          fifo_wen          <= 1;

    end // fini


    // FINISH READOUT
    DONE: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state    <= WR_CRC;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_stat_busy        <= 0;
          fifo_wen             <= 0;
          drs_dwrite_set       <= 1; // to keep chip "warm"

    end // fini

    // APPEND A CRC TO THE DATA PACKET
    WR_CRC: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state    <= IDLE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          fifo_wdata[15:0]     <= crc[15:0];

    end // fini

    //----------------------------------------------------------------------------------------------------------------
    // Configure
    //----------------------------------------------------------------------------------------------------------------

    // set-up of configuration register
    CONF_SETUP: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state    <= CONF_STROBE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_srclk_enable <= 1;                      // enable clock
          drs_sr_count     <= 0;                      //
          drs_sr_reg       <= 8'hf8 | drs_ctl_config; // c.f. drs manual, The unused bits must but always be 1.
          drs_srin_o       <= 1;                      // shift out 7 bits MSB first; bit 7 must ALWAYS be 1

    end // fini


    // write configuration register to chip
    CONF_STROBE: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (shift_out_config_done)
              drs_readout_state <= WSR_ADDR;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_sr_count     <= drs_sr_count + 1; //
          drs_srclk_enable <= 1;                // enable clock
          drs_sr_reg[7:1]  <= drs_sr_reg[6:0];  // shift out 7 bits MSB first
          drs_srin_o       <= drs_sr_reg[7];    //

          if (shift_out_config_done)
              drs_srclk_enable <= 0; // disable clock

    end // fini

    // A Write Shift Register containing 8 bits is used to acti-
    // vate channel 0 to 7. Channel 8 is always active and can
    // be used to digitize an external reference clock. The bits
    // are shifted by one position on each revolution of the
    // domino wave. If this register is loaded with 1’s, all chan-
    // nels are active all the time, and the DRS4 works like hav-
    // ing 8 independent channels. The other extreme is a single
    // 1 loaded into the register. This 1 is clocked through all 8
    // positions consecutively. It then shows up at the
    // WSROUT output and can be fed back into the shift regis-
    // ter via the WSRIN input or internally by setting
    // WSRLOOP in the Configuration Register to 1 to form a
    // cyclic operation. This means that on the first domino
    // revolution the first channel is active; on the second dom-
    // ino revolution the second channel is active and so on. If
    // the input signal gets fanned out into each of the 8 chan-
    // nels, the DRS4 chip works like having a single channel
    // with 8 times the sampling depth.
    // set address to 1101 ("address write shift register"

    //----------------------------------------------------------------------------------------------------------------
    // Write to Shift register
    //----------------------------------------------------------------------------------------------------------------

    WSR_ADDR: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state    <= WSR_SETUP;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_addr_o  <= ADR_WRITE_SR;  // address write shift register

    end // fini

    // set-up of write shift register
    WSR_SETUP: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          drs_readout_state    <= WSR_STROBE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_srclk_enable <= 1; // enable clock
          drs_sr_count     <= 0;
          drs_sr_reg       <= drs_ctl_chn_config; // copy configuration into output shift register
          drs_srin_o       <= drs_ctl_chn_config[7]; // shift out 7 bits MSB first

    end // fini

    // write shift register to chip
    WSR_STROBE: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (shift_out_config_done)
              drs_readout_state <= IDLE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_sr_count     <= drs_sr_count + 1;
          drs_srclk_enable <= 1; // enable clock
          drs_sr_reg[7:1]  <= drs_sr_reg[6:0];
          drs_srin_o       <= drs_sr_reg[7];

          if (shift_out_config_done)
            drs_srclk_enable <= 0; // disable clock

    end // fini

    // initialize read shift register
    INIT_RSR: begin

          //------------------------------------------------------------------------------------------------------------
          // State
          //------------------------------------------------------------------------------------------------------------

          if (drs_sr_count == 1024)
              drs_readout_state  <= IDLE;

          //------------------------------------------------------------------------------------------------------------
          // Logic
          //------------------------------------------------------------------------------------------------------------

          drs_sr_count <= drs_sr_count + 1'b1;

          // enable clock
          drs_srclk_enable <= 1;

          if (drs_sr_count==1023)
            drs_srin_o <= 1;

          if (drs_sr_count==1024) begin
            drs_srin_o       <= 0;
            drs_srclk_enable <= 0; // disable clock
          end

    end // fini

    endcase
  end // end !reset
end // and always

//----------------------------------------------------------------------------------------------------------------------
// CRC
//----------------------------------------------------------------------------------------------------------------------

crc22a crc22a (
  .clock(clock),
  .data(fifo_wdata),
  .reset(fifo_wen),
  .crc(crc)
);

//----------------------------------------------------------------------------------------------------------------------
// Output FIFO
//----------------------------------------------------------------------------------------------------------------------

assign rd_data = fifo_wdata;

//drs_fifo #(
//  .READ_WIDTH(READ_WIDTH),
//  .WRITE_WIDTH(16),
//  .DEPTH(1024)
//) drs_fifo (
//  .reset   (fifo_reset),
//
//  .wr_clk  (clock),
//  .wr_data (fifo_wdata),
//  .wr_en   (fifo_wen || fifo_wen_crc),
//
//  .rd_clk  (rd_clock),
//  .rd_data (rd_data),
//  .rd_en   (rd_enable)
//);


`ifdef SIMULATION
    // Write-buffer auto-clear state machine display

    reg[15*8:0] state_disp;

    always @* begin
      case (drs_readout_state)
        INIT            : state_disp <= "INIT";
        IDLE            : state_disp <= "IDLE";
        START_RUNNING   : state_disp <= "START_RUNNING";
        RUNNING         : state_disp <= "RUNNING";
        TRIGGER         : state_disp <= "TRIGGER";
        WAIT_VDD        : state_disp <= "WAIT_VDD";
        INIT_READOUT    : state_disp <= "INIT_READOUT";
        LOAD_RSR        : state_disp <= "LOAD_RSR";
        ADC_READOUT     : state_disp <= "ADC_READOUT";
        STOP_CELL       : state_disp <= "STOP_CELL";
        TIMESTAMP       : state_disp <= "TIMESTAMP";
        EVENT_CNT       : state_disp <= "EVENT_CNT";
        DONE            : state_disp <= "DONE";
        CONF_SETUP      : state_disp <= "CONF_SETUP";
        CONF_STROBE     : state_disp <= "CONF_STROBE";
        WSR_ADDR        : state_disp <= "WSR_ADDR";
        WSR_SETUP       : state_disp <= "WSR_SETUP";
        WSR_STROBE      : state_disp <= "WSR_STROBE";
        INIT_RSR        : state_disp <= "INIT_RSR";
      endcase
    end
`endif

//----------------------------------------------------------------------------------------------------------------------
endmodule
//----------------------------------------------------------------------------------------------------------------------
