// Copyright 2026 Vyges Inc.
// SPDX-License-Identifier: Apache-2.0
//
// TL-UL (TileLink Uncached Lightweight) Protocol Type Definitions — STANDALONE COPY
//
// *** IMPORTANT ***
// This file is provided ONLY for standalone use of tlul_apb_adapter without
// the opentitan-tlul IP. It is a minimal subset of opentitan-tlul's tlul_pkg:
//   - Missing: d_sink field, TL_DIW, TL_H2D_DEFAULT, TL_D2H_DEFAULT, integrity functions
//
// In a TL-UL SoC (with opentitan-rv-core-ibex, opentitan-uart, etc.) you MUST
// use opentitan-tlul's tlul_pkg.sv instead. Do NOT add this directory to your
// compile path if opentitan-tlul is already present — the `ifndef` guard will
// prevent double-compilation, but this version is structurally incomplete
// (missing d_sink) and will break code that references that field.
//
// Preferred: declare opentitan-tlul as a dependency and compile from there.
//
// This package defines the type definitions for the TL-UL protocol as
// used in the OpenTitan project and compatible ecosystems (Ibex RISC-V core,
// OpenTitan peripherals). The definitions follow the TileLink specification
// for the Uncached Lightweight (TL-UL) sub-protocol.
//
// Reference: https://github.com/chipsalliance/tilelink

`ifndef TLUL_PKG_SV
`define TLUL_PKG_SV

package tlul_pkg;

  // ---------------------------------------------------------------------------
  // Protocol parameters
  // ---------------------------------------------------------------------------

  parameter int unsigned TL_DW    = 32;         // Data width (bits)
  parameter int unsigned TL_AW    = 32;         // Address width (bits)
  parameter int unsigned TL_DBW   = TL_DW >> 3; // Data byte width (4)
  parameter int unsigned TL_SZW   = 2;          // Size field width (log2 of max data bytes)
  parameter int unsigned TL_AIW   = 8;          // Source/Sink ID width
  parameter int unsigned TL_AUW   = 16;         // A-channel user width
  parameter int unsigned TL_DUW   = 4;          // D-channel user width

  // ---------------------------------------------------------------------------
  // A-channel opcodes (Host -> Device)
  // ---------------------------------------------------------------------------

  typedef enum logic [2:0] {
    PutFullData    = 3'h0,   // Write: all enabled bytes (mask = all 1s)
    PutPartialData = 3'h1,   // Write: selected bytes via mask
    Get            = 3'h4    // Read request
  } tl_a_op_e;

  // ---------------------------------------------------------------------------
  // D-channel opcodes (Device -> Host)
  // ---------------------------------------------------------------------------

  typedef enum logic [2:0] {
    AccessAck     = 3'h0,    // Write acknowledgement (no data)
    AccessAckData = 3'h1     // Read acknowledgement (with data)
  } tl_d_op_e;

  // ---------------------------------------------------------------------------
  // Host-to-Device channel struct (A channel + d_ready)
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic                 a_valid;    // A channel valid
    tl_a_op_e             a_opcode;   // A channel opcode
    logic [2:0]           a_param;    // Unused in TL-UL, must be 0
    logic [TL_SZW-1:0]   a_size;     // Transfer size: 0=1B 1=2B 2=4B
    logic [TL_AIW-1:0]   a_source;   // Transaction ID (returned in d_source)
    logic [TL_AW-1:0]    a_address;  // Target address
    logic [TL_DBW-1:0]   a_mask;     // Byte enable mask (write) / don't care (read)
    logic [TL_DW-1:0]    a_data;     // Write data (ignored for Get)
    logic [TL_AUW-1:0]   a_user;     // User-defined bits (pass-through)
    logic                 d_ready;   // Host ready to accept D-channel response
  } tl_h2d_t;

  // ---------------------------------------------------------------------------
  // Device-to-Host channel struct (D channel + a_ready)
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic                 d_valid;    // D channel valid
    tl_d_op_e             d_opcode;   // D channel opcode
    logic [1:0]           d_param;    // Unused in TL-UL, must be 0
    logic [TL_SZW-1:0]   d_size;     // Echo of a_size
    logic [TL_AIW-1:0]   d_source;   // Echo of a_source
    logic                 d_error;   // Transaction error (maps to APB PSLVERR)
    logic [TL_DW-1:0]    d_data;     // Read data (zero for writes)
    logic [TL_DUW-1:0]   d_user;     // User-defined bits (pass-through)
    logic                 a_ready;   // Device ready to accept A-channel request
  } tl_d2h_t;

  // ---------------------------------------------------------------------------
  // Default / reset values
  // Note: struct parameter literals are not supported in all SystemVerilog
  // tools without full SV struct support. Use per-field assignments in RTL instead.
  // These are provided as documentation references only.
  //
  // TL_H2D_DEFAULT: a_valid=0, a_opcode=Get, a_size=2, d_ready=1, rest=0
  // TL_D2H_DEFAULT: d_valid=0, d_opcode=AccessAck, a_ready=1, rest=0
  // ---------------------------------------------------------------------------

endpackage : tlul_pkg

`endif // TLUL_PKG_SV
