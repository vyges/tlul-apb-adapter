// Copyright 2026 Vyges Inc.
// SPDX-License-Identifier: Apache-2.0
//
// FFT TL-UL Wrapper — Example Integration
//
// Description:
//   Example wrapper that connects the Vyges FFT Accelerator IP
//   (vyges/fast-fourier-transform-ip) to a TL-UL crossbar using
//   the tlul_apb_adapter.
//
//   The FFT IP provides both an APB interface (32-bit, preferred for
//   TL-UL integration) and an AXI4 interface (64-bit). This wrapper
//   uses the APB path, which aligns naturally with TL-UL's 32-bit
//   data width.
//
//   AXI4 ports of the FFT IP are left unconnected (tied off) in this
//   wrapper. If DMA-style bulk data transfer is needed, connect the
//   AXI4 port directly to an AXI4-compatible bus master instead.
//
// FFT IP reference: https://github.com/vyges/fast-fourier-transform-ip
// Adapter reference: https://github.com/vyges/tlul-apb-adapter

`ifndef FFT_TLUL_WRAPPER_SV
`define FFT_TLUL_WRAPPER_SV

module fft_tlul_wrapper #(
  // FFT configuration
  parameter int FFT_MAX_LENGTH_LOG2 = 12,  // log2(4096) = 12
  parameter int FFT_DATA_WIDTH      = 16,  // 16-bit fixed-point
  parameter int FFT_TWIDDLE_WIDTH   = 16,
  parameter int FFT_APB_ADDR_WIDTH  = 16,

  // TL-UL adapter configuration
  parameter int AW                  = 32,
  parameter int DW                  = 32,
  parameter int SOURCE_WIDTH        = 8,
  parameter bit APB4_EN             = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  // -------------------------------------------------------------------
  // TL-UL Slave Interface (connects to SoC crossbar device port)
  // -------------------------------------------------------------------

  // A channel
  input  logic                   tl_a_valid_i,
  input  logic [2:0]             tl_a_opcode_i,
  input  logic [2:0]             tl_a_param_i,
  input  logic [1:0]             tl_a_size_i,
  input  logic [SOURCE_WIDTH-1:0] tl_a_source_i,
  input  logic [AW-1:0]          tl_a_address_i,
  input  logic [DW/8-1:0]        tl_a_mask_i,
  input  logic [DW-1:0]          tl_a_data_i,
  output logic                   tl_a_ready_o,

  // D channel
  output logic                   tl_d_valid_o,
  output logic [2:0]             tl_d_opcode_o,
  output logic [1:0]             tl_d_param_o,
  output logic [1:0]             tl_d_size_o,
  output logic [SOURCE_WIDTH-1:0] tl_d_source_o,
  output logic                   tl_d_error_o,
  output logic [DW-1:0]          tl_d_data_o,
  input  logic                   tl_d_ready_i,

  // -------------------------------------------------------------------
  // FFT Interrupt outputs
  // -------------------------------------------------------------------
  output logic fft_done_o,
  output logic fft_error_o
);

  // -------------------------------------------------------------------------
  // Internal APB wires (adapter → FFT IP)
  // -------------------------------------------------------------------------

  logic                        apb_psel;
  logic                        apb_penable;
  logic                        apb_pwrite;
  logic [AW-1:0]               apb_paddr;
  logic [DW-1:0]               apb_pwdata;
  logic [DW/8-1:0]             apb_pstrb;
  logic [2:0]                  apb_pprot;
  logic [31:0]                 apb_prdata;
  logic                        apb_pready;

  // AXI tie-offs (FFT AXI port not used in this integration path)
  logic unused_axi_ok;

  // -------------------------------------------------------------------------
  // TL-UL to APB adapter
  // -------------------------------------------------------------------------

  tlul_apb_adapter #(
    .AW          (AW),
    .DW          (DW),
    .DBW         (DW/8),
    .SOURCE_WIDTH(SOURCE_WIDTH),
    .APB4_EN     (APB4_EN)
  ) u_tlul_apb_adapter (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .tl_a_valid_i  (tl_a_valid_i),
    .tl_a_opcode_i (tl_a_opcode_i),
    .tl_a_param_i  (tl_a_param_i),
    .tl_a_size_i   (tl_a_size_i),
    .tl_a_source_i (tl_a_source_i),
    .tl_a_address_i(tl_a_address_i),
    .tl_a_mask_i   (tl_a_mask_i),
    .tl_a_data_i   (tl_a_data_i),
    .tl_a_ready_o  (tl_a_ready_o),
    .tl_d_valid_o  (tl_d_valid_o),
    .tl_d_opcode_o (tl_d_opcode_o),
    .tl_d_param_o  (tl_d_param_o),
    .tl_d_size_o   (tl_d_size_o),
    .tl_d_source_o (tl_d_source_o),
    .tl_d_error_o  (tl_d_error_o),
    .tl_d_data_o   (tl_d_data_o),
    .tl_d_ready_i  (tl_d_ready_i),
    .apb_psel_o    (apb_psel),
    .apb_penable_o (apb_penable),
    .apb_pwrite_o  (apb_pwrite),
    .apb_paddr_o   (apb_paddr),
    .apb_pwdata_o  (apb_pwdata),
    .apb_pstrb_o   (apb_pstrb),
    .apb_pprot_o   (apb_pprot),
    .apb_prdata_i  (apb_prdata),
    .apb_pready_i  (apb_pready),
    .apb_pslverr_i (1'b0)         // FFT IP does not implement PSLVERR
  );

  // -------------------------------------------------------------------------
  // Vyges FFT Accelerator IP
  // (vyges/fast-fourier-transform-ip)
  // -------------------------------------------------------------------------

  fft_top #(
    .FFT_MAX_LENGTH_LOG2(FFT_MAX_LENGTH_LOG2),
    .FFT_DATA_WIDTH     (FFT_DATA_WIDTH),
    .FFT_TWIDDLE_WIDTH  (FFT_TWIDDLE_WIDTH),
    .FFT_APB_ADDR_WIDTH (FFT_APB_ADDR_WIDTH),
    .FFT_AXI_ADDR_WIDTH (32),
    .FFT_AXI_DATA_WIDTH (64)
  ) u_fft (
    // System clock/reset
    .clk_i          (clk_i),
    .reset_n_i      (rst_ni),

    // APB interface (connected to adapter)
    .pclk_i         (clk_i),
    .preset_n_i     (rst_ni),
    .psel_i         (apb_psel),
    .penable_i      (apb_penable),
    .pwrite_i       (apb_pwrite),
    .paddr_i        (apb_paddr[FFT_APB_ADDR_WIDTH-1:0]),
    .pwdata_i       (apb_pwdata),
    .prdata_o       (apb_prdata),
    .pready_o       (apb_pready),

    // AXI interface — tied off (not used in TL-UL integration path)
    .axi_aclk_i     (clk_i),
    .axi_areset_n_i (rst_ni),
    .axi_awaddr_i   ('0),
    .axi_awvalid_i  (1'b0),
    .axi_awready_o  (/* unconnected */),
    .axi_wdata_i    ('0),
    .axi_wvalid_i   (1'b0),
    .axi_wready_o   (/* unconnected */),
    .axi_araddr_i   ('0),
    .axi_arvalid_i  (1'b0),
    .axi_arready_o  (/* unconnected */),
    .axi_rdata_o    (/* unconnected */),
    .axi_rvalid_o   (/* unconnected */),
    .axi_rready_i   (1'b0),

    // Interrupt outputs
    .fft_done_o     (fft_done_o),
    .fft_error_o    (fft_error_o)
  );

  // Suppress unused lint warnings for APB4 signals not consumed by FFT APB3
  assign unused_axi_ok = &{apb_pstrb, apb_pprot, 1'b0};

endmodule : fft_tlul_wrapper

`endif // FFT_TLUL_WRAPPER_SV
