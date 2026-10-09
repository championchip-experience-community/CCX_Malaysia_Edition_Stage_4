
//====================================================================================
// Top level module file for AWS FPGA
//====================================================================================

module top
    #(
      parameter EN_DDR = 0,
      parameter EN_HBM = 0
    )
    (
      `include "cl_ports.vh"
    );

`include "cl_id_defines.vh" // CL ID defines required for all examples
`include "top_defines.vh"

wire ocl_aclk    = clk_main_a0;
wire ocl_aresetn = rst_main_n;    // active-low from shell

//My Instances

wire [7:0] output_pins;
reg [7:0] input_pins;
reg [7:0] input_en;
logic riscv_nreset;
wire riscv_clk;
wire [7:0] io_Pins;
wire w_Tx;
wire w_Rx;
    
assign io_Pins[0] = !input_en[0] ? input_pins[0] : 1'bz;
assign io_Pins[1] = !input_en[1] ? input_pins[1] : 1'bz;
assign io_Pins[2] = !input_en[2] ? input_pins[2] : 1'bz;
assign io_Pins[3] = !input_en[3] ? input_pins[3] : 1'bz;
assign io_Pins[4] = !input_en[4] ? input_pins[4] : 1'bz;
assign io_Pins[5] = !input_en[5] ? input_pins[5] : 1'bz;
assign io_Pins[6] = !input_en[6] ? input_pins[6] : 1'bz;
assign io_Pins[7] = !input_en[7] ? input_pins[7] : 1'bz;

assign output_pins[0] = input_en[0] ? io_Pins[0] : 1'bz;
assign output_pins[1] = input_en[1] ? io_Pins[1] : 1'bz;
assign output_pins[2] = input_en[2] ? io_Pins[2] : 1'bz;
assign output_pins[3] = input_en[3] ? io_Pins[3] : 1'bz;
assign output_pins[4] = input_en[4] ? io_Pins[4] : 1'bz;
assign output_pins[5] = input_en[5] ? io_Pins[5] : 1'bz;
assign output_pins[6] = input_en[6] ? io_Pins[6] : 1'bz;
assign output_pins[7] = input_en[7] ? io_Pins[7] : 1'bz;

// tick_gen #(.DIV(250_000_000)) u_tick (
//   .clk   (ocl_aclk),
//   .rst_n (ocl_aresetn),
//   .tick  (riscv_clk)
// );

assign riscv_clk = ocl_aclk;

RISCV riscvtop (
  .i_Rx_Serial  ( w_Rx ),
  .i_Clk        (riscv_clk), 
  .i_nRst       (riscv_nreset), 
	.o_Tx_Serial  ( w_Tx ),
  .io_Pins      (io_Pins)
);

    reg r_Tx_Transmit;
    wire w_Tx_Done;
    reg [7:0] r_Tx_Data;
    wire w_Rx_Done;
    wire [7:0] w_Rx_Data;
    reg r_Rx_Done;

    Transmitter #(
        .p_CLKS_PER_BIT(2170)
    ) e_UART_TX (
        .i_Clk(riscv_clk),
        .i_Rst(~riscv_nreset),
        .i_Tx_Transmit(r_Tx_Transmit),
        .i_Tx_Byte(r_Tx_Data), 
        .o_Tx_Serial(w_Rx),
        .o_Tx_Done(w_Tx_Done)
    );

    Receiver #(
        .p_CLKS_PER_BIT(2170)
    ) e_UART_RX (
        .i_Clk(riscv_clk),
        .i_Rst(~riscv_nreset),   
        .i_Rx_Serial(w_Tx),
        .o_Rx_Done(w_Rx_Done),
        .o_Rx_Byte(w_Rx_Data)
    );

//=============================================================================
// OCL — AXI-Lite slave for RISC-V
//  - 0x00: RST          [bit0 | RW] (0 = hold core in reset)
//  - 0x04: IN           [bit15-8 (DIR); bit7-0 (DATA)  | RW]
//  - 0x08: OUT          [bit7-0 (DATA) | RW]
//  - 0x0C: TX           [bit7-0  | RW]
//  - 0x10: RX[3|2|1|0]  [bit31-0 | RO]
//  - 0x14: RX[7|6|5|4]  [bit31-0 | RO]
//  - 0x18: Current Byte [bit5-0  | RO]
//  - 0x1C: PC           [bit31-0 | RO]
//=============================================================================

// ---------------- Write Channel  -------------------------------------------
    reg [1:0] state_write, next_state_write;

    reg addr_done, data_done;
    reg [31:0] addr_reg_write, data_reg_write;
    reg [3:0] wstrb_reg;
    
    localparam W_IDLE = 2'b00, W_WAIT = 2'b01, W_WRITE = 2'b10, W_SEND_RESP = 2'b11;

    always @(*) begin
        next_state_write = state_write; 
        case (state_write)
            W_IDLE:       if (ocl_cl_awvalid || ocl_cl_wvalid) next_state_write = W_WAIT;
            W_WAIT: if (addr_done && data_done) next_state_write = W_WRITE;
            W_WRITE:  next_state_write = W_SEND_RESP;
            W_SEND_RESP:  if (cl_ocl_bvalid && ocl_cl_bready) next_state_write = W_IDLE;
            default:    next_state_write = W_IDLE;
        endcase
    end

    always @(posedge ocl_aclk or negedge ocl_aresetn) begin
        if (!ocl_aresetn) begin
            state_write <= W_IDLE;
            cl_ocl_awready <= 0; 
            cl_ocl_wready <= 0; 
            cl_ocl_bvalid <= 0; 
            cl_ocl_bresp <= 0;
            addr_done <= 0; 
            data_done <= 0;
            addr_reg_write <= 32'd0;
            data_reg_write <= 32'd0;
            wstrb_reg      <= 4'd0;

           
        end else begin
            state_write <= next_state_write; 
            case (state_write)
                W_IDLE: begin
                    cl_ocl_awready <= 0;
                    cl_ocl_wready  <= 0;
                    cl_ocl_bvalid <= 0;
                    cl_ocl_bresp   <= 2'b00;
                    addr_done <= 0;
                    data_done <= 0;
                end

                W_WAIT: begin
                    cl_ocl_awready <= !addr_done;
                    cl_ocl_wready  <= !data_done;

                    if (ocl_cl_awvalid && !addr_done) begin
                        addr_reg_write <=  ocl_cl_awaddr;
                        addr_done <= 1;
                    end
                    if (ocl_cl_wvalid && !data_done) begin
                        data_reg_write <= ocl_cl_wdata;
                        wstrb_reg <= ocl_cl_wstrb;
                        data_done <= 1;
                    end
                end
                W_WRITE: begin
                  cl_ocl_awready <= 0;
                  cl_ocl_wready  <= 0;
                  cl_ocl_bvalid  <= 0;
                  
                end
                W_SEND_RESP: begin
                    cl_ocl_bvalid  <= 1;
                    cl_ocl_bresp   <= 2'b00;                    
                end
            endcase
        end
    end

    always @(posedge ocl_aclk or negedge ocl_aresetn) begin
      if(!ocl_aresetn) begin
          riscv_nreset <= 1'b1;
          input_pins[7:0] <= 8'b0;
          input_en[7:0] <= 8'b0;
          r_Tx_Data <= 8'h0;
          r_Tx_Transmit <= 1'b0;
      end
      else begin 
        
      if(r_Tx_Transmit) r_Tx_Transmit <= 1'b0;

      if (state_write == W_WRITE) begin
          case (addr_reg_write[4:2])   // word index: 0x00->0, 0x04->1, ...
            3'b000: begin // 0x00 Reset (bit0) R/W, respect byte-enable
              if (wstrb_reg[0]) begin
                riscv_nreset <= data_reg_write[0];
              end
            end

            3'b001: begin // 0x04
              if (wstrb_reg[0]) begin
                input_pins[7:0] <= data_reg_write[7:0];
                input_en[7:0] <= data_reg_write[15:8];
              end
            end

            3'b011: begin // 0x0C
              if (wstrb_reg[0]) begin
                r_Tx_Data <= data_reg_write[7:0];
                r_Tx_Transmit <= 1'b1;
              end
            end
          endcase
      end
      end
  end

// ---------------- Read Channel  ------------

localparam R_IDLE = 1'b0, R_SEND_RESP = 1'b1;

reg state_read, next_state_read;
reg [31:0] addr_reg_read;

// P1: State Transition
always @(posedge ocl_aclk or negedge ocl_aresetn) begin
    if (!ocl_aresetn)
        state_read <= R_IDLE;
    else
        state_read <= next_state_read;
end

// P2: Next State Logic
always @(*) begin
    next_state_read = state_read;
    case (state_read)
        R_IDLE: begin
            if (ocl_cl_arvalid)
                next_state_read = R_SEND_RESP;
        end
        R_SEND_RESP: begin
            if (ocl_cl_rready)
                next_state_read = R_IDLE;
        end
    endcase
end

reg [5:0] r_UART_RX_FIFO_Walker;
reg [63:0] r_UART_RX_FIFO; 

// P3: Registered Outputs / Data Capture
always @(posedge ocl_aclk or negedge ocl_aresetn) begin
    if (!ocl_aresetn) begin
        cl_ocl_arready <= 1'b0;
        cl_ocl_rvalid  <= 1'b0;
        cl_ocl_rdata   <= 32'd0;
        cl_ocl_rresp   <= 2'b00;
        addr_reg_read  <= 32'd0;
        r_Rx_Done <= 1'b0;
        r_UART_RX_FIFO_Walker <= 6'h0;
        r_UART_RX_FIFO <= 64'h0; 
    end else begin
      
      // RESET
      if(!riscv_nreset) begin
        r_UART_RX_FIFO_Walker <= 6'h0;
        r_UART_RX_FIFO <= 64'h0; 
      end

      if(w_Rx_Done) begin
        r_UART_RX_FIFO_Walker <= r_UART_RX_FIFO_Walker + 8;
        r_UART_RX_FIFO[r_UART_RX_FIFO_Walker +: 8] <= w_Rx_Data;
        r_Rx_Done <= 1'b1;
      end

        case (state_read)
            R_IDLE: begin
                cl_ocl_arready <= 1'b1;
                cl_ocl_rvalid  <= 1'b0;
                cl_ocl_rresp   <= 2'b00;

                if (ocl_cl_arvalid)
                    addr_reg_read <= ocl_cl_araddr;
            end

            R_SEND_RESP: begin
                cl_ocl_arready <= 1'b0;
                cl_ocl_rvalid  <= 1'b1;
                cl_ocl_rresp   <= 2'b00;

                unique case (addr_reg_read[4:2])
                    3'b000: cl_ocl_rdata <= {31'b0, riscv_nreset};
                    3'b001: cl_ocl_rdata <= {16'b0, input_en, input_pins};
                    3'b010: cl_ocl_rdata <= {24'b0, output_pins};
                    3'b011: cl_ocl_rdata <= {23'b0, w_Tx_Done, r_Tx_Data};
                    3'b100: begin
                      // cl_ocl_rdata <= {23'b0, r_Rx_Done, w_Rx_Data};
                      cl_ocl_rdata <= r_UART_RX_FIFO[31:0];
                      // r_Rx_Done <= 1'b0;
                    end
                    3'b101: begin
                      // cl_ocl_rdata <= {23'b0, r_Rx_Done, w_Rx_Data};
                      cl_ocl_rdata <= r_UART_RX_FIFO[63:32];
                      // r_Rx_Done <= 1'b0;
                    end
                    3'b110: begin
                      // cl_ocl_rdata <= {23'b0, r_Rx_Done, w_Rx_Data};
                      cl_ocl_rdata <= {26'h0, r_UART_RX_FIFO_Walker};
                      // r_Rx_Done <= 1'b0;
                    end
                    3'b111: cl_ocl_rdata <= riscvtop.e_PROCESSOR.w_PC_Output;
                    default: cl_ocl_rdata <= 32'b0;
                endcase
            end
        endcase
    end
end

//=============================================================================
// GLOBALS
//=============================================================================

  always_comb begin
     cl_sh_flr_done    = 'b1;
     cl_sh_status0     = 'b0;
     cl_sh_status1     = 'b0;
     cl_sh_status2     = 'b0;
     cl_sh_id0         = `CL_SH_ID0;
     cl_sh_id1         = `CL_SH_ID1;
     cl_sh_status_vled = 'b0;
     cl_sh_dma_wr_full = 'b0;
     cl_sh_dma_rd_full = 'b0;
  end


//=============================================================================
// PCIM
//=============================================================================


//=============================================================================
// PCIS
//=============================================================================

  // Cause Protocol Violations
  always_comb begin
    cl_sh_dma_pcis_bresp   = 'b0;
    cl_sh_dma_pcis_rresp   = 'b0;
    cl_sh_dma_pcis_rvalid  = 'b0;
  end

  // Remaining CL Output Ports
  always_comb begin
    cl_sh_dma_pcis_awready = 'b0;

    cl_sh_dma_pcis_wready  = 'b0;

    cl_sh_dma_pcis_bid     = 'b0;
    cl_sh_dma_pcis_bvalid  = 'b0;

    cl_sh_dma_pcis_arready  = 'b0;

    cl_sh_dma_pcis_rid     = 'b0;
    cl_sh_dma_pcis_rdata   = 'b0;
    cl_sh_dma_pcis_rlast   = 'b0;
    cl_sh_dma_pcis_ruser   = 'b0;
  end

//=============================================================================
// OCL
//=============================================================================


//=============================================================================
// SDA
//=============================================================================

  // Cause Protocol Violations
  always_comb begin
    cl_sda_bresp   = 'b0;
    cl_sda_rresp   = 'b0;
    cl_sda_rvalid  = 'b0;
  end

  // Remaining CL Output Ports
  always_comb begin
    cl_sda_awready = 'b0;
    cl_sda_wready  = 'b0;

    cl_sda_bvalid = 'b0;

    cl_sda_arready = 'b0;

    cl_sda_rdata   = 'b0;
  end

//=============================================================================
// SH_DDR
//=============================================================================

   sh_ddr
     #(
       .DDR_PRESENT (EN_DDR)
       )
   SH_DDR
     (
      .clk                       (clk_main_a0 ),
      .rst_n                     (            ),
      .stat_clk                  (clk_main_a0 ),
      .stat_rst_n                (            ),
      .CLK_DIMM_DP               (CLK_DIMM_DP ),
      .CLK_DIMM_DN               (CLK_DIMM_DN ),
      .M_ACT_N                   (M_ACT_N     ),
      .M_MA                      (M_MA        ),
      .M_BA                      (M_BA        ),
      .M_BG                      (M_BG        ),
      .M_CKE                     (M_CKE       ),
      .M_ODT                     (M_ODT       ),
      .M_CS_N                    (M_CS_N      ),
      .M_CLK_DN                  (M_CLK_DN    ),
      .M_CLK_DP                  (M_CLK_DP    ),
      .M_PAR                     (M_PAR       ),
      .M_DQ                      (M_DQ        ),
      .M_ECC                     (M_ECC       ),
      .M_DQS_DP                  (M_DQS_DP    ),
      .M_DQS_DN                  (M_DQS_DN    ),
      .cl_RST_DIMM_N             (RST_DIMM_N  ),
      .cl_sh_ddr_axi_awid        (            ),
      .cl_sh_ddr_axi_awaddr      (            ),
      .cl_sh_ddr_axi_awlen       (            ),
      .cl_sh_ddr_axi_awsize      (            ),
      .cl_sh_ddr_axi_awvalid     (            ),
      .cl_sh_ddr_axi_awburst     (            ),
      .cl_sh_ddr_axi_awuser      (            ),
      .cl_sh_ddr_axi_awready     (            ),
      .cl_sh_ddr_axi_wdata       (            ),
      .cl_sh_ddr_axi_wstrb       (            ),
      .cl_sh_ddr_axi_wlast       (            ),
      .cl_sh_ddr_axi_wvalid      (            ),
      .cl_sh_ddr_axi_wready      (            ),
      .cl_sh_ddr_axi_bid         (            ),
      .cl_sh_ddr_axi_bresp       (            ),
      .cl_sh_ddr_axi_bvalid      (            ),
      .cl_sh_ddr_axi_bready      (            ),
      .cl_sh_ddr_axi_arid        (            ),
      .cl_sh_ddr_axi_araddr      (            ),
      .cl_sh_ddr_axi_arlen       (            ),
      .cl_sh_ddr_axi_arsize      (            ),
      .cl_sh_ddr_axi_arvalid     (            ),
      .cl_sh_ddr_axi_arburst     (            ),
      .cl_sh_ddr_axi_aruser      (            ),
      .cl_sh_ddr_axi_arready     (            ),
      .cl_sh_ddr_axi_rid         (            ),
      .cl_sh_ddr_axi_rdata       (            ),
      .cl_sh_ddr_axi_rresp       (            ),
      .cl_sh_ddr_axi_rlast       (            ),
      .cl_sh_ddr_axi_rvalid      (            ),
      .cl_sh_ddr_axi_rready      (            ),
      .sh_ddr_stat_bus_addr      (            ),
      .sh_ddr_stat_bus_wdata     (            ),
      .sh_ddr_stat_bus_wr        (            ),
      .sh_ddr_stat_bus_rd        (            ),
      .sh_ddr_stat_bus_ack       (            ),
      .sh_ddr_stat_bus_rdata     (            ),
      .ddr_sh_stat_int           (            ),
      .sh_cl_ddr_is_ready        (            )
      );

  always_comb begin
    cl_sh_ddr_stat_ack   = 'b0;
    cl_sh_ddr_stat_rdata = 'b0;
    cl_sh_ddr_stat_int   = 'b0;
  end

//=============================================================================
// USER-DEFIEND INTERRUPTS
//=============================================================================

  always_comb begin
    cl_sh_apppf_irq_req = 'b0;
  end

//=============================================================================
// VIRTUAL JTAG
//=============================================================================

  always_comb begin
    tdo = 'b0;
  end

//=============================================================================
// HBM MONITOR IO
//=============================================================================

  always_comb begin
    hbm_apb_paddr_1   = 'b0;
    hbm_apb_pprot_1   = 'b0;
    hbm_apb_psel_1    = 'b0;
    hbm_apb_penable_1 = 'b0;
    hbm_apb_pwrite_1  = 'b0;
    hbm_apb_pwdata_1  = 'b0;
    hbm_apb_pstrb_1   = 'b0;
    hbm_apb_pready_1  = 'b0;
    hbm_apb_prdata_1  = 'b0;
    hbm_apb_pslverr_1 = 'b0;

    hbm_apb_paddr_0   = 'b0;
    hbm_apb_pprot_0   = 'b0;
    hbm_apb_psel_0    = 'b0;
    hbm_apb_penable_0 = 'b0;
    hbm_apb_pwrite_0  = 'b0;
    hbm_apb_pwdata_0  = 'b0;
    hbm_apb_pstrb_0   = 'b0;
    hbm_apb_pready_0  = 'b0;
    hbm_apb_prdata_0  = 'b0;
    hbm_apb_pslverr_0 = 'b0;
  end

//=============================================================================
//
//=============================================================================

  always_comb begin
    PCIE_EP_TXP    = 'b0;
    PCIE_EP_TXN    = 'b0;

    PCIE_RP_PERSTN = 'b0;
    PCIE_RP_TXP    = 'b0;
    PCIE_RP_TXN    = 'b0;
  end

endmodule 
