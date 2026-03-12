// Copyright 2026 Vyges Inc.
// SPDX-License-Identifier: Apache-2.0
//
// SystemVerilog Testbench: tlul_apb_adapter
//
// Compatible with: Icarus Verilog (iverilog -g2012), Verilator, ModelSim
//
// APB slave model uses a synchronous always block (no race conditions).
// Each test configures apb_prdata/apb_pslverr/apb_wait_n before the
// transaction, then calls the TL-UL host task.
//
// Tests covered:
//   TC01: Single read (Get), zero-wait APB slave
//   TC02: Single write (PutFullData), zero-wait APB slave
//   TC03: Partial write (PutPartialData) with byte mask
//   TC04: Multi-cycle APB slave (3 wait states)
//   TC05: Back-to-back transactions (write then read)
//   TC06: PSLVERR propagation to TL-UL d_error
//   TC07: d_ready back-pressure
//   TC08: Reset mid-transaction

`timescale 1ns/1ps

module tb_tlul_apb_adapter;

  // -------------------------------------------------------------------------
  // Parameters
  // -------------------------------------------------------------------------

  localparam int AW           = 32;
  localparam int DW           = 32;
  localparam int DBW          = DW/8;
  localparam int SOURCE_WIDTH = 8;
  localparam bit APB4_EN      = 1'b1;

  localparam time CLK_PERIOD  = 10;   // ns
  localparam int  TIMEOUT     = 200;

  // -------------------------------------------------------------------------
  // DUT signals — driven by testbench (reg)
  // -------------------------------------------------------------------------

  reg clk, rst_n;

  reg                      tl_a_valid;
  reg [2:0]                tl_a_opcode;
  reg [2:0]                tl_a_param;
  reg [1:0]                tl_a_size;
  reg [SOURCE_WIDTH-1:0]   tl_a_source;
  reg [AW-1:0]             tl_a_address;
  reg [DBW-1:0]            tl_a_mask;
  reg [DW-1:0]             tl_a_data;
  reg                      tl_d_ready;

  // DUT outputs — wire
  wire                     tl_a_ready;
  wire                     tl_d_valid;
  wire [2:0]               tl_d_opcode;
  wire [1:0]               tl_d_param;
  wire [1:0]               tl_d_size;
  wire [SOURCE_WIDTH-1:0]  tl_d_source;
  wire                     tl_d_error;
  wire [DW-1:0]            tl_d_data;
  wire                     apb_psel;
  wire                     apb_penable;
  wire                     apb_pwrite;
  wire [AW-1:0]            apb_paddr;
  wire [DW-1:0]            apb_pwdata;
  wire [DBW-1:0]           apb_pstrb;
  wire [2:0]               apb_pprot;

  // APB slave registers (driven by always block below)
  reg [DW-1:0] apb_prdata;
  reg          apb_pready;
  reg          apb_pslverr;

  // -------------------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------------------

  tlul_apb_adapter #(
    .AW(AW), .DW(DW), .DBW(DBW),
    .SOURCE_WIDTH(SOURCE_WIDTH), .APB4_EN(APB4_EN)
  ) dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .tl_a_valid_i  (tl_a_valid),
    .tl_a_opcode_i (tl_a_opcode),
    .tl_a_param_i  (tl_a_param),
    .tl_a_size_i   (tl_a_size),
    .tl_a_source_i (tl_a_source),
    .tl_a_address_i(tl_a_address),
    .tl_a_mask_i   (tl_a_mask),
    .tl_a_data_i   (tl_a_data),
    .tl_a_ready_o  (tl_a_ready),
    .tl_d_valid_o  (tl_d_valid),
    .tl_d_opcode_o (tl_d_opcode),
    .tl_d_param_o  (tl_d_param),
    .tl_d_size_o   (tl_d_size),
    .tl_d_source_o (tl_d_source),
    .tl_d_error_o  (tl_d_error),
    .tl_d_data_o   (tl_d_data),
    .tl_d_ready_i  (tl_d_ready),
    .apb_psel_o    (apb_psel),
    .apb_penable_o (apb_penable),
    .apb_pwrite_o  (apb_pwrite),
    .apb_paddr_o   (apb_paddr),
    .apb_pwdata_o  (apb_pwdata),
    .apb_pstrb_o   (apb_pstrb),
    .apb_pprot_o   (apb_pprot),
    .apb_prdata_i  (apb_prdata),
    .apb_pready_i  (apb_pready),
    .apb_pslverr_i (apb_pslverr)
  );

  // -------------------------------------------------------------------------
  // Clock generation
  // -------------------------------------------------------------------------

  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // -------------------------------------------------------------------------
  // APB slave model (synchronous)
  //
  // Configuration variables (set BEFORE issuing a TL-UL transaction):
  //   apb_slv_rdata     : read data to return
  //   apb_slv_pslverr   : slave error to inject
  //   apb_slv_wait_n    : number of extra wait states (0 = immediate)
  // -------------------------------------------------------------------------

  integer      apb_slv_wait_n    = 0;
  reg [DW-1:0] apb_slv_rdata     = 32'h0;
  reg          apb_slv_pslverr   = 1'b0;
  integer      apb_wait_cnt_r;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      apb_pready    <= 1'b0;
      apb_prdata    <= 32'h0;
      apb_pslverr   <= 1'b0;
      apb_wait_cnt_r <= 0;
    end else begin
      if (apb_psel && !apb_penable) begin
        // Setup phase: preload wait counter
        apb_wait_cnt_r <= apb_slv_wait_n;
        apb_pready     <= 1'b0;
        apb_prdata     <= apb_slv_rdata;
        apb_pslverr    <= 1'b0;
      end else if (apb_psel && apb_penable) begin
        // Access phase
        if (apb_wait_cnt_r > 0) begin
          apb_wait_cnt_r <= apb_wait_cnt_r - 1;
          apb_pready     <= 1'b0;
        end else begin
          // Drive response
          apb_pready   <= 1'b1;
          apb_prdata   <= apb_slv_rdata;
          apb_pslverr  <= apb_slv_pslverr;
        end
      end else begin
        apb_pready   <= 1'b0;
        apb_pslverr  <= 1'b0;
        apb_wait_cnt_r <= 0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Test tracking
  // -------------------------------------------------------------------------

  integer tests_run  = 0;
  integer tests_pass = 0;
  integer tests_fail = 0;

  task automatic check_t;
    input [127:0] name;  // packed string (iverilog compatible)
    input         condition;
    begin
      tests_run = tests_run + 1;
      if (condition) begin
        tests_pass = tests_pass + 1;
        $display("  PASS: %s", name);
      end else begin
        tests_fail = tests_fail + 1;
        $display("  FAIL: %s at time %0t", name, $time);
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // Captured APB signals (latch on access-phase PREADY)
  // -------------------------------------------------------------------------

  reg [AW-1:0]  cap_paddr;
  reg [DW-1:0]  cap_pwdata;
  reg [DBW-1:0] cap_pstrb;
  reg           cap_pwrite;

  always @(posedge clk) begin
    if (apb_psel && apb_penable && apb_pready) begin
      cap_paddr  <= apb_paddr;
      cap_pwdata <= apb_pwdata;
      cap_pstrb  <= apb_pstrb;
      cap_pwrite <= apb_pwrite;
    end
  end

  // -------------------------------------------------------------------------
  // TL-UL host task: issue Get
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // TL-UL host tasks
  //
  // Timing model:
  //   1. Present request signals (after posedge + #1 setup margin)
  //   2. SPIN until a_ready=1 (DUT in IDLE, combinational)
  //   3. @(posedge clk): DUT latches the request; transition IDLE→SETUP
  //   4. De-assert a_valid at posedge+1 (clean)
  //   5. SPIN until d_valid=1 (polls after NBA settle with #1)
  //   6. Capture response; @(posedge clk): DUT latches d_ready; RESP→IDLE
  // -------------------------------------------------------------------------

  task tl_get;
    input  [AW-1:0]           addr;
    input  [SOURCE_WIDTH-1:0] source;
    output [DW-1:0]           rdata;
    output                    rerr;
    integer cnt;
    begin
      // Present request — check a_ready is high before clocking in
      cnt = 0;
      while (!tl_a_ready) begin
        @(posedge clk); #1;
        cnt = cnt + 1;
        if (cnt > TIMEOUT) begin $display("tl_get: a_ready idle timeout"); $finish(1); end
      end
      // a_ready=1 (DUT in IDLE); drive request signals
      tl_a_valid   = 1'b1;
      tl_a_opcode  = 3'h4;   // Get
      tl_a_param   = 3'h0;
      tl_a_size    = 2'h2;
      tl_a_source  = source;
      tl_a_address = addr;
      tl_a_mask    = 4'hf;
      tl_a_data    = 32'h0;
      tl_d_ready   = 1'b1;
      // Clock in the request: DUT latches a_valid=1 → IDLE→SETUP
      @(posedge clk); #1;
      tl_a_valid = 1'b0;
      // Wait for d_valid (DUT goes SETUP→ACCESS→RESP)
      cnt = 0;
      while (!tl_d_valid) begin
        @(posedge clk); #1;
        cnt = cnt + 1;
        if (cnt > TIMEOUT) begin $display("tl_get: d_valid timeout"); $finish(1); end
      end
      rdata = tl_d_data;
      rerr  = tl_d_error;
      // Clock in d_ready=1: DUT latches → RESP→IDLE
      @(posedge clk); #1;
      tl_d_ready = 1'b0;
    end
  endtask

  task tl_put;
    input  [AW-1:0]           addr;
    input  [DW-1:0]           data;
    input  [DBW-1:0]          mask;
    input  [2:0]              opcode;
    input  [SOURCE_WIDTH-1:0] source;
    output                    rerr;
    integer cnt;
    begin
      cnt = 0;
      while (!tl_a_ready) begin
        @(posedge clk); #1;
        cnt = cnt + 1;
        if (cnt > TIMEOUT) begin $display("tl_put: a_ready idle timeout"); $finish(1); end
      end
      tl_a_valid   = 1'b1;
      tl_a_opcode  = opcode;
      tl_a_param   = 3'h0;
      tl_a_size    = 2'h2;
      tl_a_source  = source;
      tl_a_address = addr;
      tl_a_mask    = mask;
      tl_a_data    = data;
      tl_d_ready   = 1'b1;
      @(posedge clk); #1;
      tl_a_valid = 1'b0;
      cnt = 0;
      while (!tl_d_valid) begin
        @(posedge clk); #1;
        cnt = cnt + 1;
        if (cnt > TIMEOUT) begin $display("tl_put: d_valid timeout"); $finish(1); end
      end
      rerr = tl_d_error;
      @(posedge clk); #1;
      tl_d_ready = 1'b0;
    end
  endtask

  // -------------------------------------------------------------------------
  // Main test sequence
  // -------------------------------------------------------------------------

  reg [DW-1:0] rd_data;
  reg          rd_err, wr_err;

  initial begin
    $display("=== tlul_apb_adapter testbench ===");

    rst_n        = 1'b0;
    tl_a_valid   = 1'b0;
    tl_a_opcode  = 3'h0;
    tl_a_param   = 3'h0;
    tl_a_size    = 2'h2;
    tl_a_source  = 8'h0;
    tl_a_address = 32'h0;
    tl_a_mask    = 4'hf;
    tl_a_data    = 32'h0;
    tl_d_ready   = 1'b0;
    apb_slv_rdata   = 32'h0;
    apb_slv_pslverr = 1'b0;
    apb_slv_wait_n  = 0;

    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);

    // -----------------------------------------------------------------
    // TC01: Single read, zero-wait APB
    // -----------------------------------------------------------------
    $display("\n[TC01] Single read (Get), zero-wait APB");
    apb_slv_rdata   = 32'hDEAD_BEEF;
    apb_slv_pslverr = 1'b0;
    apb_slv_wait_n  = 0;
    tl_get(32'h1000_0000, 8'h01, rd_data, rd_err);
    check_t("TC01.data",   rd_data == 32'hDEAD_BEEF);
    check_t("TC01.error",  rd_err  == 1'b0);
    check_t("TC01.idle",   tl_a_ready == 1'b1);
    check_t("TC01.source", tl_d_source == 8'h01);

    // -----------------------------------------------------------------
    // TC02: Single write, zero-wait APB
    // -----------------------------------------------------------------
    $display("\n[TC02] Single write (PutFullData), zero-wait APB");
    apb_slv_rdata  = 32'h0;
    apb_slv_wait_n = 0;
    tl_put(32'h2000_0008, 32'hCAFE_0000, 4'hf, 3'h0, 8'h02, wr_err);
    @(posedge clk); #1;  // let cap_* registers settle
    check_t("TC02.error",  wr_err     == 1'b0);
    check_t("TC02.addr",   cap_paddr  == 32'h2000_0008);
    check_t("TC02.data",   cap_pwdata == 32'hCAFE_0000);
    check_t("TC02.write",  cap_pwrite == 1'b1);
    check_t("TC02.opcode", tl_d_opcode == 3'h0);

    // -----------------------------------------------------------------
    // TC03: Partial write with byte mask 4'b0110
    // -----------------------------------------------------------------
    $display("\n[TC03] Partial write (PutPartialData) byte mask 4'b0110");
    apb_slv_rdata  = 32'h0;
    apb_slv_wait_n = 0;
    tl_put(32'h3000_0000, 32'h1234_5678, 4'b0110, 3'h1, 8'h03, wr_err);
    @(posedge clk); #1;
    check_t("TC03.pstrb",  cap_pstrb  == 4'b0110);
    check_t("TC03.pwrite", cap_pwrite == 1'b1);
    check_t("TC03.error",  wr_err     == 1'b0);

    // -----------------------------------------------------------------
    // TC04: Multi-cycle APB slave (3 wait states)
    // -----------------------------------------------------------------
    $display("\n[TC04] Read with 3 APB wait states");
    apb_slv_rdata  = 32'hA5A5_A5A5;
    apb_slv_wait_n = 3;
    tl_get(32'h4000_0000, 8'h04, rd_data, rd_err);
    check_t("TC04.data",  rd_data == 32'hA5A5_A5A5);
    check_t("TC04.error", rd_err  == 1'b0);
    apb_slv_wait_n = 0;

    // -----------------------------------------------------------------
    // TC05: Back-to-back write then read
    // -----------------------------------------------------------------
    $display("\n[TC05] Back-to-back write then read");
    apb_slv_rdata  = 32'h0;
    apb_slv_wait_n = 0;
    tl_put(32'h5000_0000, 32'hABCD_EF01, 4'hf, 3'h0, 8'h05, wr_err);
    check_t("TC05.write_no_err", wr_err == 1'b0);
    apb_slv_rdata  = 32'h5555_AAAA;
    tl_get(32'h5000_0000, 8'h06, rd_data, rd_err);
    check_t("TC05.read_data",  rd_data == 32'h5555_AAAA);
    check_t("TC05.read_error", rd_err  == 1'b0);

    // -----------------------------------------------------------------
    // TC06: PSLVERR propagation
    // -----------------------------------------------------------------
    $display("\n[TC06] PSLVERR propagation to TL-UL d_error");
    apb_slv_rdata   = 32'h0;
    apb_slv_pslverr = 1'b1;
    apb_slv_wait_n  = 0;
    tl_get(32'h6000_0000, 8'h07, rd_data, rd_err);
    check_t("TC06.d_error", rd_err == 1'b1);
    apb_slv_pslverr = 1'b0;

    // -----------------------------------------------------------------
    // TC07: d_ready back-pressure — d_valid must be held
    // -----------------------------------------------------------------
    $display("\n[TC07] d_ready back-pressure");
    begin : tc07
      integer cnt7;
      apb_slv_rdata  = 32'h0000_1234;
      apb_slv_wait_n = 0;
      // Wait for DUT to be idle
      cnt7 = 0;
      while (!tl_a_ready) begin
        @(posedge clk); #1;
        cnt7 = cnt7 + 1;
        if (cnt7 > TIMEOUT) begin $display("TC07 idle timeout"); $finish(1); end
      end
      // Present request with d_ready held low
      tl_a_valid   = 1'b1;
      tl_a_opcode  = 3'h4;
      tl_a_source  = 8'h08;
      tl_a_address = 32'h7000_0000;
      tl_a_mask    = 4'hf;
      tl_a_size    = 2'h2;
      tl_d_ready   = 1'b0;   // hold low intentionally
      @(posedge clk); #1;    // DUT latches request → SETUP
      tl_a_valid = 1'b0;
      // Poll for d_valid
      cnt7 = 0;
      @(posedge clk); #1;
      while (!tl_d_valid) begin
        @(posedge clk); #1;
        cnt7 = cnt7 + 1;
        if (cnt7 > TIMEOUT) begin $display("TC07 d_valid timeout"); $finish(1); end
      end
      // Hold d_ready=0 for 4 more cycles: d_valid must stay asserted
      repeat(4) begin
        @(posedge clk); #1;
        check_t("TC07.d_valid_held", tl_d_valid == 1'b1);
      end
      // Release
      tl_d_ready = 1'b1;
      @(posedge clk); #1;
      tl_d_ready = 1'b0;
    end

    // -----------------------------------------------------------------
    // TC08: Reset mid-transaction
    // -----------------------------------------------------------------
    $display("\n[TC08] Reset mid-transaction");
    apb_slv_rdata  = 32'h0;
    apb_slv_wait_n = 0;
    // Wait for IDLE, then start a transaction
    while (!tl_a_ready) begin @(posedge clk); #1; end
    tl_a_valid   = 1'b1;
    tl_a_opcode  = 3'h4;
    tl_a_address = 32'h8000_0000;
    tl_a_source  = 8'h09;
    tl_a_mask    = 4'hf;
    @(posedge clk); #1;   // DUT latches: IDLE→SETUP
    tl_a_valid = 1'b0;
    @(posedge clk); #1;   // DUT in SETUP
    rst_n = 1'b0;
    repeat(3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk); #1;
    check_t("TC08.a_ready", tl_a_ready == 1'b1);
    check_t("TC08.d_valid", tl_d_valid == 1'b0);
    check_t("TC08.psel",    apb_psel   == 1'b0);

    // -----------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------
    repeat(4) @(posedge clk);
    $display("\n=== Results: %0d/%0d passed ===", tests_pass, tests_run);
    if (tests_fail > 0)
      $display("FAILED: %0d test(s)", tests_fail);
    else
      $display("ALL TESTS PASSED");
    $finish;
  end

  // -------------------------------------------------------------------------
  // Timeout watchdog
  // -------------------------------------------------------------------------

  initial begin
    #(CLK_PERIOD * 5000);
    $display("TIMEOUT: simulation exceeded time limit");
    $finish(1);
  end

  // -------------------------------------------------------------------------
  // Waveform dump
  // -------------------------------------------------------------------------

  initial begin
    $dumpfile("tlul_apb_adapter.vcd");
    $dumpvars(0, tb_tlul_apb_adapter);
  end

endmodule : tb_tlul_apb_adapter
