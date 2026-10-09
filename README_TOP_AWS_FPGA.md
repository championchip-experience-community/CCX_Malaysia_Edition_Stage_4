# Processor Integration with `top.sv`

## Project files

This integration uses the following file structure:

```text
files added to the project/
├── top.sv       # integration between the processor and AWS FPGA
├── riscv.sv     # complete processor, including GPIO and UART
└── README.md    # this document

file already provided by the AWS FPGA project/
└── cl_ports.vh
```

The `riscv.sv` file must contain the group's complete processor and all modules that are part of it. GPIO, UART, and other components do not need to be placed in separate files, as long as every required module is declared in `riscv.sv` and included in synthesis.

The `cl_ports.vh` file is provided by the AWS FPGA HDK base project when the Custom Logic project is created. It declares the communication ports of the AWS Shell and must not be modified.

### Processor clock

The processor directly uses the main clock provided by AWS FPGA. In `top.sv`, `clk_main_a0` is assigned the internal name `ocl_aclk` and is then connected to `riscv_clk`:

```systemverilog
wire ocl_aclk = clk_main_a0;
assign riscv_clk = ocl_aclk;
```

In the processor instance, `riscv_clk` must be connected to the corresponding clock port:

```systemverilog
.i_Clk(riscv_clk)
```

If the group's processor uses a different port name, only the name on the left must be changed. The `riscv_clk` signal on the right must be preserved.

## Required changes for each group

Before reviewing the other sections of the file, each group must locate the following instance near the beginning of `top.sv`:

```systemverilog
RISCV riscvtop (
    .i_Rx_Serial (w_Rx),
    .i_Clk       (riscv_clk),
    .i_nRst      (riscv_nreset),
    .o_Tx_Serial (w_Tx),
    .io_Pins     (io_Pins)
);
```

This is the main section that must be adapted. Each group must change:

1. `RISCV`: the name of the main processor module declared in `riscv.sv`;
2. the port names on the left: they must match the names used by the group's processor;
3. the hierarchical PC reference shown below, if the processor has a different internal hierarchy.

The instance name `riscvtop` and the signals on the right must be preserved. For example:

```systemverilog
GroupProcessor riscvtop (
    .uart_rx (w_Rx),
    .clock   (riscv_clk),
    .reset_n (riscv_nreset),
    .uart_tx (w_Tx),
    .gpio    (io_Pins)
);
```

Only the module name and the processor-side interface are changed:

| Processor connection | Signal that must remain in `top.sv` |
|---|---|
| Serial input | `w_Rx` |
| Clock | `riscv_clk` |
| Active-low reset | `riscv_nreset` |
| Serial output | `w_Tx` |
| 8-bit bidirectional port | `io_Pins` |

If the processor reset is active high, the connection must perform the required inversion, for example `.reset(~riscv_nreset)`.

### Internal PC reference

The read channel contains the following reference to the original processor:

```systemverilog
3'b111: cl_ocl_rdata <= riscvtop.e_PROCESSOR.w_PC_Output;
```

Because `e_PROCESSOR.w_PC_Output` is an internal hierarchy specific to the reference processor, each group must point this expression to the corresponding PC signal in its own design. If the PC is not accessible, this read can be disabled:

```systemverilog
3'b111: cl_ocl_rdata <= 32'b0;
```

All other sections of `top.sv` must remain unchanged.

## Overview of `top.sv`

The `top.sv` file is the top-level module used to integrate the RISC-V processor with the AWS FPGA infrastructure. It contains:

- the ports provided by the AWS Shell;
- clock and reset connections;
- the group's processor instance;
- the OCL AXI-Lite interface;
- registers accessible by the host software;
- mandatory or unused AWS Shell connections.

Groups should not rewrite this file. The following sections explain its organization.

## AWS module declaration

The beginning of the file declares the `top` module and includes the standard AWS ports:

```systemverilog
module top
    #(
      parameter EN_DDR = 0,
      parameter EN_HBM = 0
    )
    (
      `include "cl_ports.vh"
    );
```

The included file is provided by the AWS FPGA HDK. This section must not be modified by the groups.

## Integration clock and reset

The main clock and reset from the AWS Shell are used by the `top.sv` logic:

```systemverilog
wire ocl_aclk    = clk_main_a0;
wire ocl_aresetn = rst_main_n;

assign riscv_clk = ocl_aclk;
```

`ocl_aclk` drives the AXI-Lite interface and, in this version, is also connected to the processor through `riscv_clk`.

The `riscv_nreset` signal is the reset provided to the processor. It is active low.

## Auxiliary serial communication block

After the processor instance, `top.sv` contains two auxiliary instances:

```systemverilog
Transmitter #(
    .p_CLKS_PER_BIT(2170)
) e_UART_TX (
    // connections omitted
);

Receiver #(
    .p_CLKS_PER_BIT(2170)
) e_UART_RX (
    // connections omitted
);
```

These instances connect the registers in `top.sv` to the serial signals connected to the processor. In this project structure, the `Transmitter` and `Receiver` module declarations must be present in `riscv.sv` together with the other processor modules.

## OCL register map

The OCL interface is an AXI-Lite slave that provides access to the registers defined in `top.sv`:

```systemverilog
//=============================================================================
// OCL — AXI-Lite slave for RISC-V
//  - 0x00: RST          [bit0 | RW] (0 = hold core in reset)
//  - 0x04: IN           [bit15-8 (DIR); bit7-0 (DATA) | RW]
//  - 0x08: OUT          [bit7-0 (DATA) | RW]
//  - 0x0C: TX           [bit7-0 | RW]
//  - 0x10: RX[3|2|1|0]  [bit31-0 | RO]
//  - 0x14: RX[7|6|5|4]  [bit31-0 | RO]
//  - 0x18: Current Byte [bit5-0 | RO]
//  - 0x1C: PC           [bit31-0 | RO]
//=============================================================================
```

This map is part of the external contract of `top.sv` and must not be changed by the groups.

## AXI-Lite write channel

The write channel receives the address and data sent by the AWS Shell through separate AXI-Lite channels.

Its state machine uses four states:

```systemverilog
localparam W_IDLE      = 2'b00;
localparam W_WAIT      = 2'b01;
localparam W_WRITE     = 2'b10;
localparam W_SEND_RESP = 2'b11;
```

The general flow is:

```text
W_IDLE
   ↓ address or data arrives
W_WAIT
   ↓ both address and data have been received
W_WRITE
   ↓ the selected register is updated
W_SEND_RESP
   ↓ the response is accepted by the AWS Shell
W_IDLE
```

During `W_WAIT`, the address, data, and byte-enable values are stored:

```systemverilog
addr_reg_write <= ocl_cl_awaddr;
data_reg_write <= ocl_cl_wdata;
wstrb_reg      <= ocl_cl_wstrb;
```

During `W_WRITE`, the address bits select the register to be updated:

```systemverilog
case (addr_reg_write[4:2])
    3'b000: begin
        // register 0x00
    end

    3'b001: begin
        // register 0x04
    end

    3'b011: begin
        // register 0x0C
    end
endcase
```

This block belongs to the AWS interface and normally does not need to be modified when integrating another processor.

## AXI-Lite read channel

The read channel uses two states:

```systemverilog
localparam R_IDLE      = 1'b0;
localparam R_SEND_RESP = 1'b1;
```

In `R_IDLE`, the requested address is stored:

```systemverilog
if (ocl_cl_arvalid)
    addr_reg_read <= ocl_cl_araddr;
```

In `R_SEND_RESP`, the address selects the value returned to the AWS Shell:

```systemverilog
unique case (addr_reg_read[4:2])
    3'b000: cl_ocl_rdata <= {31'b0, riscv_nreset};
    3'b001: cl_ocl_rdata <= {16'b0, input_en, input_pins};
    3'b010: cl_ocl_rdata <= {24'b0, output_pins};
    3'b011: cl_ocl_rdata <= {23'b0, w_Tx_Done, r_Tx_Data};
    3'b100: cl_ocl_rdata <= r_UART_RX_FIFO[31:0];
    3'b101: cl_ocl_rdata <= r_UART_RX_FIFO[63:32];
    3'b110: cl_ocl_rdata <= {26'h0, r_UART_RX_FIFO_Walker};
    3'b111: cl_ocl_rdata <= riscvtop.e_PROCESSOR.w_PC_Output;
endcase
```

The last line directly accesses an internal signal of the reference processor:

```systemverilog
riscvtop.e_PROCESSOR.w_PC_Output
```

This hierarchy may be different in each group's project. If the processor does not contain an `e_PROCESSOR` instance and a `w_PC_Output` signal at that exact hierarchy, the group must adapt this line.

If PC readback is not required, it can be disabled:

```systemverilog
3'b111: cl_ocl_rdata <= 32'b0;
```

This is the only adaptation outside the main processor instance that may be required because of the internal structure of each processor.

## Read FIFO

`top.sv` maintains a 64-bit register to store received data:

```systemverilog
reg [5:0]  r_UART_RX_FIFO_Walker;
reg [63:0] r_UART_RX_FIFO;
```

When `w_Rx_Done` is asserted, the received byte is placed in the next available position:

```systemverilog
if (w_Rx_Done) begin
    r_UART_RX_FIFO_Walker <= r_UART_RX_FIFO_Walker + 8;
    r_UART_RX_FIFO[r_UART_RX_FIFO_Walker +: 8] <= w_Rx_Data;
end
```

This block is internal to `top.sv` and does not depend on the processor's internal architecture.

## AWS Shell global signals

The `GLOBALS` block provides the identifiers and status values required by the AWS Shell:

```systemverilog
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
```

This section must not be modified.

## Unused interfaces

The remainder of the file connects or disables mandatory AWS Shell interfaces:

- `PCIM`: interface for transactions initiated by the Custom Logic;
- `PCIS`: interface used to access the Custom Logic;
- `SDA`: auxiliary control interface;
- `SH_DDR`: connection to the Shell DDR block;
- user interrupts;
- Virtual JTAG;
- HBM monitoring;
- additional PCIe ports.

When one of these interfaces is not used by the project, its outputs are tied to zero or connected to the block required by the HDK. Groups do not need to modify these sections to adapt their processor.
