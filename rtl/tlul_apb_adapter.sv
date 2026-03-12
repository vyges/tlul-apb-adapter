// Copyright 2026 Vyges Inc.
// SPDX-License-Identifier: Apache-2.0
//
// TL-UL to APB Protocol Adapter
//
// Description:
//   Bridges a TileLink Uncached Lightweight (TL-UL) slave port to an APB
//   (AMBA Peripheral Bus) master port. Enables any APB-interfaced peripheral
//   to be connected to a TL-UL crossbar without modification to either side.
//
//   Supports:
//     - APB3 (PSEL, PENABLE, PWRITE, PADDR, PWDATA, PRDATA, PREADY)
//     - APB4 extensions: PSTRB (byte enables), PPROT, PSLVERR
//       (enabled via APB4_EN parameter)
//     - Single-outstanding transactions (TL-UL uncached constraint)
//     - Zero-wait-state and multi-cycle APB slaves (PREADY extension)
//     - Read (Get) and Write (PutFullData, PutPartialData) operations
//     - PSLVERR propagation to TL-UL d_error
//
//   Protocol timing (minimum-latency path, zero-wait APB slave):
//     Cycle 0: TL-UL A channel accepted (a_valid & a_ready)
//     Cycle 1: APB Setup phase (PSEL=1, PENABLE=0)
//     Cycle 2: APB Access phase (PSEL=1, PENABLE=1), PREADY=1 → capture
//     Cycle 3: TL-UL D channel presented (d_valid=1)
//
//   Latency: 3 cycles minimum (zero-wait APB). Additional cycles proportional
//   to APB slave PREADY extension cycles.
//
// Parameterization:
//   AW          : Address bus width (must match APB slave, default 32)
//   DW          : Data bus width (must be 32 for standard TL-UL and APB)
//   SOURCE_WIDTH: TL-UL source/sink ID width (default 8, echo to d_source)
//   APB4_EN     : 1 = include PSTRB/PPROT/PSLVERR (APB4), 0 = APB3 only

`ifndef TLUL_APB_ADAPTER_SV
`define TLUL_APB_ADAPTER_SV

module tlul_apb_adapter #(
  parameter int unsigned AW           = 32,  // Address width
  parameter int unsigned DW           = 32,  // Data width (must be 32)
  parameter int unsigned DBW          = DW/8, // Data byte width (4)
  parameter int unsigned SOURCE_WIDTH = 8,   // TL-UL source ID width
  parameter bit          APB4_EN      = 1'b1 // 1: APB4 (PSTRB/PPROT/PSLVERR)
                                              // 0: APB3 (no PSTRB, ignore PSLVERR)
) (
  input  logic clk_i,    // System clock
  input  logic rst_ni,   // Active-low synchronous reset

  // -------------------------------------------------------------------
  // TL-UL Slave Interface (device-facing; connects to crossbar host port)
  // -------------------------------------------------------------------

  // A channel (request: host -> device)
  input  logic                   tl_a_valid_i,
  input  logic [2:0]             tl_a_opcode_i,   // Get=4, PutFull=0, PutPartial=1
  input  logic [2:0]             tl_a_param_i,    // Must be 0 for TL-UL
  input  logic [1:0]             tl_a_size_i,     // 0=1B 1=2B 2=4B
  input  logic [SOURCE_WIDTH-1:0] tl_a_source_i,  // Transaction ID
  input  logic [AW-1:0]          tl_a_address_i,  // Target address
  input  logic [DBW-1:0]         tl_a_mask_i,     // Byte enables
  input  logic [DW-1:0]          tl_a_data_i,     // Write data
  output logic                   tl_a_ready_o,    // Adapter ready for new request

  // D channel (response: device -> host)
  output logic                   tl_d_valid_o,
  output logic [2:0]             tl_d_opcode_o,   // AccessAck=0, AccessAckData=1
  output logic [1:0]             tl_d_param_o,    // Always 0
  output logic [1:0]             tl_d_size_o,     // Echo of a_size
  output logic [SOURCE_WIDTH-1:0] tl_d_source_o,  // Echo of a_source
  output logic                   tl_d_error_o,    // Error (from PSLVERR or protocol)
  output logic [DW-1:0]          tl_d_data_o,     // Read data (0 for writes)
  input  logic                   tl_d_ready_i,    // Host ready for response

  // -------------------------------------------------------------------
  // APB Master Interface (peripheral-facing)
  // -------------------------------------------------------------------

  output logic                   apb_psel_o,      // Peripheral select
  output logic                   apb_penable_o,   // Enable (access phase)
  output logic                   apb_pwrite_o,    // Write enable
  output logic [AW-1:0]          apb_paddr_o,     // Address
  output logic [DW-1:0]          apb_pwdata_o,    // Write data
  output logic [DBW-1:0]         apb_pstrb_o,     // Write strobes (APB4, else 4'hf)
  output logic [2:0]             apb_pprot_o,     // Protection (APB4, else 3'b000)
  input  logic [DW-1:0]          apb_prdata_i,    // Read data
  input  logic                   apb_pready_i,    // Peripheral ready
  input  logic                   apb_pslverr_i    // Slave error (APB4, else tie 0)
);

  // -------------------------------------------------------------------------
  // Parameter validation
  // -------------------------------------------------------------------------

  // synthesis translate_off
  initial begin
    assert (DW == 32) else
      $fatal(1, "tlul_apb_adapter: DW must be 32 (TL-UL and APB constraint)");
    assert (AW <= 32) else
      $fatal(1, "tlul_apb_adapter: AW must be <= 32");
  end
  // synthesis translate_on

  // -------------------------------------------------------------------------
  // Local types and constants
  // -------------------------------------------------------------------------

  localparam logic [2:0] TL_OP_PUT_FULL    = 3'h0;
  localparam logic [2:0] TL_OP_PUT_PARTIAL = 3'h1;
  localparam logic [2:0] TL_OP_GET         = 3'h4;
  localparam logic [2:0] TL_D_ACCESSACK      = 3'h0;
  localparam logic [2:0] TL_D_ACCESSACKDATA  = 3'h1;

  typedef enum logic [1:0] {
    IDLE,        // Ready to accept new TL-UL request
    APB_SETUP,   // APB setup phase: PSEL=1, PENABLE=0 (one cycle)
    APB_ACCESS,  // APB access phase: PSEL=1, PENABLE=1, wait PREADY
    TL_RESP      // TL-UL D-channel response: d_valid=1, wait d_ready
  } state_e;

  state_e state_q, state_d;

  // -------------------------------------------------------------------------
  // Request capture registers
  // -------------------------------------------------------------------------

  logic                    req_write_q;
  logic [AW-1:0]           req_addr_q;
  logic [DW-1:0]           req_wdata_q;
  logic [DBW-1:0]          req_mask_q;
  logic [1:0]              req_size_q;
  logic [SOURCE_WIDTH-1:0] req_source_q;

  // -------------------------------------------------------------------------
  // Response capture registers
  // -------------------------------------------------------------------------

  logic [DW-1:0]           rsp_rdata_q;
  logic                    rsp_error_q;

  // -------------------------------------------------------------------------
  // Write detection
  // -------------------------------------------------------------------------

  logic is_write;
  assign is_write = (tl_a_opcode_i == TL_OP_PUT_FULL) ||
                    (tl_a_opcode_i == TL_OP_PUT_PARTIAL);

  // -------------------------------------------------------------------------
  // State register
  // -------------------------------------------------------------------------

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= IDLE;
    else         state_q <= state_d;
  end

  // -------------------------------------------------------------------------
  // Request capture register
  // -------------------------------------------------------------------------

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_write_q  <= 1'b0;
      req_addr_q   <= '0;
      req_wdata_q  <= '0;
      req_mask_q   <= '0;
      req_size_q   <= '0;
      req_source_q <= '0;
    end else if (state_q == IDLE && tl_a_valid_i) begin
      req_write_q  <= is_write;
      req_addr_q   <= tl_a_address_i;
      req_wdata_q  <= tl_a_data_i;
      req_mask_q   <= tl_a_mask_i;
      req_size_q   <= tl_a_size_i;
      req_source_q <= tl_a_source_i;
    end
  end

  // -------------------------------------------------------------------------
  // Response capture register
  // -------------------------------------------------------------------------

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_rdata_q <= '0;
      rsp_error_q <= 1'b0;
    end else if (state_q == APB_ACCESS && apb_pready_i) begin
      rsp_rdata_q <= apb_prdata_i;
      rsp_error_q <= APB4_EN ? apb_pslverr_i : 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // Next-state logic
  // -------------------------------------------------------------------------

  always_comb begin
    state_d = state_q;
    case (state_q)
      IDLE:       if (tl_a_valid_i)        state_d = APB_SETUP;
      APB_SETUP:                            state_d = APB_ACCESS;
      APB_ACCESS: if (apb_pready_i)        state_d = TL_RESP;
      TL_RESP:    if (tl_d_ready_i)        state_d = IDLE;
      default:                              state_d = IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // APB master drive
  // -------------------------------------------------------------------------

  always_comb begin
    apb_psel_o    = 1'b0;
    apb_penable_o = 1'b0;
    apb_pwrite_o  = 1'b0;
    apb_paddr_o   = '0;
    apb_pwdata_o  = '0;
    apb_pstrb_o   = APB4_EN ? '0 : {DBW{1'b1}};
    apb_pprot_o   = 3'b000;

    case (state_q)
      APB_SETUP: begin
        apb_psel_o   = 1'b1;
        apb_penable_o= 1'b0;
        apb_pwrite_o = req_write_q;
        apb_paddr_o  = req_addr_q;
        apb_pwdata_o = req_wdata_q;
        apb_pstrb_o  = APB4_EN ? req_mask_q : {DBW{1'b1}};
      end
      APB_ACCESS: begin
        apb_psel_o   = 1'b1;
        apb_penable_o= 1'b1;
        apb_pwrite_o = req_write_q;
        apb_paddr_o  = req_addr_q;
        apb_pwdata_o = req_wdata_q;
        apb_pstrb_o  = APB4_EN ? req_mask_q : {DBW{1'b1}};
      end
      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // TL-UL interface drive
  // -------------------------------------------------------------------------

  assign tl_a_ready_o  = (state_q == IDLE);

  assign tl_d_valid_o  = (state_q == TL_RESP);
  assign tl_d_opcode_o = req_write_q ? TL_D_ACCESSACK : TL_D_ACCESSACKDATA;
  assign tl_d_param_o  = 2'h0;
  assign tl_d_size_o   = req_size_q;
  assign tl_d_source_o = req_source_q;
  assign tl_d_error_o  = rsp_error_q;
  assign tl_d_data_o   = req_write_q ? '0 : rsp_rdata_q;

  // -------------------------------------------------------------------------
  // Unused input acknowledgement (suppress lint warnings)
  // -------------------------------------------------------------------------

  logic unused_ok;
  assign unused_ok = &{tl_a_param_i, 1'b0};

endmodule : tlul_apb_adapter

`endif // TLUL_APB_ADAPTER_SV
