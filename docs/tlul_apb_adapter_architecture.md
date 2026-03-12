# TL-UL to APB Adapter — Architecture

**IP Name:** `tlul-apb-adapter`
**Namespace:** `vyges/tlul-apb-adapter`
**Version:** 0.1.0
**License:** Apache-2.0
**Last updated:** 2026-03-12

---

## 1. Overview

The `tlul_apb_adapter` is a protocol bridge IP that connects a TileLink Uncached Lightweight (TL-UL) bus fabric to one or more APB peripherals. It implements the TL-UL slave (device) role on one side and the APB master role on the other.

```
  ┌────────────────────────────────────────────────────────────────┐
  │                  SoC (TL-UL Crossbar Domain)                   │
  │                                                                │
  │  CPU Core       TL-UL Crossbar (xbar)                         │
  │  (Ibex/CVA6) ──►  [Host Port 0] ──► ... other devices ...     │
  │                   [Host Port 1]      [Device Port N]           │
  │                                           │                    │
  └───────────────────────────────────────────┼────────────────────┘
                                              │ TL-UL Slave port
                                     ┌────────▼────────┐
                                     │  tlul_apb_adapter│
                                     │  (this IP)       │
                                     └────────┬────────┘
                                              │ APB Master port
                         ┌────────────────────┼──────────────────┐
                         │                    │                   │
                    ┌────▼────┐         ┌────▼────┐        ┌────▼────┐
                    │ APB     │         │ APB     │        │ APB     │
                    │Peripheral│        │Peripheral│       │Peripheral│
                    │(GPIO)   │         │(UART)   │        │(FFT)    │
                    └─────────┘         └─────────┘        └─────────┘
```

> **Note:** One `tlul_apb_adapter` instance is required per APB peripheral. The APB bus itself (1:N demux from a single TL-UL port) can be implemented with an APB decoder external to this IP, or by instantiating one adapter per peripheral with non-overlapping address ranges in the TL-UL crossbar routing table.

---

## 2. Internal Architecture

### 2.1 Block Diagram

```
TL-UL A channel                                     APB Master
───────────────────────────────────────────────────────────────

  a_valid ──►┌──────────────┐                 PSEL ──────────►
  a_opcode──►│  Request     │                 PENABLE ────────►
  a_param ──►│  Capture     │ req_write_q     PWRITE ─────────►
  a_size ───►│  Registers   ├─────────────────► PADDR ─────────►
  a_source──►│              │ req_addr_q      PWDATA ─────────►
  a_address─►│              │ req_wdata_q     PSTRB ──────────►
  a_mask ───►│              │ req_mask_q      PPROT ──────────►
  a_data ───►│              │ req_source_q
             └──────┬───────┘ req_size_q         PRDATA ──────►┐
                    │                             PREADY ──────►│
             ┌──────▼───────┐                     PSLVERR─────►│
             │   4-State    │                                   │
             │    FSM       │                  ┌────────────────┘
             │              │              ┌───▼────────────┐
             │  IDLE        │              │   Response     │
             │  APB_SETUP   │              │   Capture      │
             │  APB_ACCESS  │              │   Registers    │
             │  TL_RESP     │              │   rsp_rdata_q  │
             └──────┬───────┘              │   rsp_error_q  │
                    │                      └───┬────────────┘
             ┌──────▼───────┐                  │
TL-UL D      │  Response    │◄─────────────────┘
channel      │  Output Mux  │
             └──────────────┘
  d_valid ◄──┤
  d_opcode◄──┤
  d_param ◄──┤
  d_size ◄───┤
  d_source◄──┤
  d_error ◄──┤
  d_data ◄───┤
  a_ready ◄──┤ (IDLE state)
             └──────────────
```

### 2.2 Sub-Components

| Component | Type | Description |
|-----------|------|-------------|
| Request Capture Registers | Sequential | Captures `a_opcode`, `a_address`, `a_data`, `a_mask`, `a_size`, `a_source` on the cycle `a_valid & a_ready` |
| 4-State FSM | Sequential | Orchestrates the TL-UL → APB → TL-UL protocol translation sequence |
| APB Drive Logic | Combinational | Drives `PSEL`, `PENABLE`, `PWRITE`, `PADDR`, `PWDATA`, `PSTRB`, `PPROT` from FSM state and captured registers |
| Response Capture Registers | Sequential | Captures `PRDATA` and `PSLVERR` on the cycle `APB_ACCESS & PREADY` |
| Response Output Mux | Combinational | Drives TL-UL D-channel signals from captured response and FSM state |

---

## 3. Protocol Translation Mapping

### 3.1 TL-UL A Opcode → APB

| TL-UL A Opcode | Value | APB Operation | PWRITE |
|----------------|-------|---------------|--------|
| `Get` | `3'h4` | Read | 0 |
| `PutFullData` | `3'h0` | Write (all bytes) | 1 |
| `PutPartialData` | `3'h1` | Write (selected bytes) | 1 |

### 3.2 APB Response → TL-UL D Channel

| APB Signal | TL-UL Signal | Notes |
|-----------|-------------|-------|
| `PRDATA` | `tl_d_data_o` | Read data passthrough; `32'h0` for writes |
| `PSLVERR` | `tl_d_error_o` | Only when `APB4_EN=1`; else `tl_d_error_o=0` |
| (write op) | `tl_d_opcode_o = AccessAck (0)` | |
| (read op) | `tl_d_opcode_o = AccessAckData (1)` | |
| `a_source` (captured) | `tl_d_source_o` | Echo-back for transaction tracking |
| `a_size` (captured) | `tl_d_size_o` | Echo-back |

### 3.3 APB Byte Enable Mapping

| Mode | PSTRB Source |
|------|-------------|
| `APB4_EN = 1` | `tl_a_mask_i` (4-bit byte enables from TL-UL) |
| `APB4_EN = 0` | `4'hF` (all bytes enabled, APB3 behavior) |

---

## 4. Design Decisions

### 4.1 Single-Outstanding Constraint

TL-UL Uncached Lightweight mandates that only one transaction is in-flight at any time. APB is inherently single-outstanding as well. This constraint is enforced by de-asserting `tl_a_ready_o` in all states except `IDLE`. No FIFO or request buffering is needed.

**Implication for SoC designers:** If multiple agents need to access the same APB peripheral, they must share a single TL-UL crossbar port via arbitration upstream. The adapter itself does not provide arbitration.

### 4.2 No Clock-Domain Crossing

The adapter is designed for a single-clock-domain SoC where the TL-UL crossbar and APB peripherals share `clk_i`. This is the typical configuration in small RISC-V SoC designs.

**If APB peripheral runs on a different clock:** An external CDC (clock-domain crossing) bridge must be placed between the adapter's APB master port and the peripheral. Two-flop synchronizers on `PREADY` and `PSLVERR` are the minimum requirement.

### 4.3 APB3 vs APB4 Parameterization

The `APB4_EN` parameter allows the adapter to work with both APB3 peripherals (no PSTRB, no PSLVERR) and APB4 peripherals. Setting `APB4_EN=0` is appropriate for legacy peripherals. The parameter is a Verilog `bit` type (not a `localparam`) so synthesis tools can optimize away the unused logic branch cleanly.

### 4.4 Source ID Echo

The `tl_a_source_i` field uniquely identifies a TL-UL transaction for the bus fabric (used for response routing). The adapter captures it in `req_source_q` and echoes it back as `tl_d_source_o`. This is essential for correct operation of the TL-UL crossbar.

### 4.5 PPROT Mapping

AMBA APB4 defines `PPROT[2:0]` as:
- Bit 0: Normal/Privileged
- Bit 1: Secure/Non-secure
- Bit 2: Data/Instruction

TL-UL does not have a direct privilege encoding in the base `TL-UL` spec. The adapter drives `PPROT = 3'b000` (unprivileged, non-secure, data). Future enhancement: derive `PPROT` from `tl_a_user_i` if a user-privilege encoding convention is defined by the SoC.

---

## 5. Integration Guide

### 5.1 Address Decoding

The adapter does not perform address decoding. The TL-UL crossbar is responsible for routing transactions to the correct `tlul_apb_adapter` instance based on address ranges. Each adapter instance handles exactly one APB slave address region.

**Example address map:**

```
0x3000_0000 – 0x3000_FFFF  → tlul_apb_adapter (FFT accelerator)
0x3001_0000 – 0x3001_FFFF  → tlul_apb_adapter (GPIO)
0x3002_0000 – 0x3002_FFFF  → tlul_apb_adapter (UART)
```

### 5.2 Instantiation Example

```systemverilog
tlul_apb_adapter #(
  .AW          (32),
  .DW          (32),
  .SOURCE_WIDTH(8),
  .APB4_EN     (1)
) u_tlul_apb_fft (
  .clk_i         (clk),
  .rst_ni        (rst_n),
  // TL-UL slave
  .tl_a_valid_i  (tl_fft_h2d.a_valid),
  .tl_a_opcode_i (tl_fft_h2d.a_opcode),
  .tl_a_param_i  (tl_fft_h2d.a_param),
  .tl_a_size_i   (tl_fft_h2d.a_size),
  .tl_a_source_i (tl_fft_h2d.a_source),
  .tl_a_address_i(tl_fft_h2d.a_address),
  .tl_a_mask_i   (tl_fft_h2d.a_mask),
  .tl_a_data_i   (tl_fft_h2d.a_data),
  .tl_a_ready_o  (tl_fft_d2h.a_ready),
  .tl_d_valid_o  (tl_fft_d2h.d_valid),
  .tl_d_opcode_o (tl_fft_d2h.d_opcode),
  .tl_d_param_o  (tl_fft_d2h.d_param),
  .tl_d_size_o   (tl_fft_d2h.d_size),
  .tl_d_source_o (tl_fft_d2h.d_source),
  .tl_d_error_o  (tl_fft_d2h.d_error),
  .tl_d_data_o   (tl_fft_d2h.d_data),
  .tl_d_ready_i  (tl_fft_h2d.d_ready),
  // APB master → FFT peripheral
  .apb_psel_o    (fft_psel),
  .apb_penable_o (fft_penable),
  .apb_pwrite_o  (fft_pwrite),
  .apb_paddr_o   (fft_paddr),
  .apb_pwdata_o  (fft_pwdata),
  .apb_pstrb_o   (fft_pstrb),
  .apb_pprot_o   (fft_pprot),
  .apb_prdata_i  (fft_prdata),
  .apb_pready_i  (fft_pready),
  .apb_pslverr_i (fft_pslverr)
);
```

### 5.3 Using `tlul_pkg` Structs (Optional)

If the SoC design uses OpenTitan-compatible TL-UL structs (`tl_h2d_t`, `tl_d2h_t`), the `tlul_pkg.sv` file defines these types. Connect as shown in section 5.2 by selecting individual fields from the packed structs.

---

## 6. File Structure

```
tlul-apb-adapter/
├── rtl/
│   ├── tlul_pkg.sv              # TL-UL type definitions (optional, OpenTitan-compatible)
│   └── tlul_apb_adapter.sv      # Main adapter module
├── tb/
│   └── cocotb/
│       ├── Makefile             # cocotb simulation Makefile
│       └── test_tlul_apb_adapter.py  # cocotb Python tests (TC01–TC09)
├── docs/
│   ├── tlul_apb_adapter_design_specification.md  # Interface, timing, verification plan
│   ├── tlul_apb_adapter_architecture.md         # This document
│   └── fft_integration_guide.md # Step-by-step FFT APB integration example
├── examples/
│   └── fft_tlul_wrapper.sv      # Wrapper: instantiates adapter + FFT APB port connection
├── constraints/
│   └── tlul_apb_adapter.sdc     # Timing constraints (OpenLane/Synopsys)
├── vyges-metadata.json          # Vyges IP catalog metadata
├── README.md
├── LICENSE                      # Apache-2.0
└── Makefile                     # Top-level: sim, lint, clean targets
```

---

## 7. Dependency Graph

```
vyges/tlul-apb-adapter@0.1.0
  └── [implements] TL-UL Uncached Lightweight slave
  └── [implements] AMBA APB3/APB4 master
  └── [used_in]    vyges/fast-fourier-transform-ip (FFT APB port bridging)
  └── [compatible] lowrisc/opentitan TL-UL crossbar
  └── [compatible] Caravel user project area (via Ibex + TL-UL xbar)
```

---

## 8. References

1. [TileLink Specification 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b18_tilelink_spec_1.8.1.pdf)
2. [AMBA APB Protocol Specification — ARM IHI0024](https://developer.arm.com/documentation/ihi0024/latest)
3. [OpenTitan TL-UL Documentation](https://opentitan.org/book/hw/ip/tlul/index.html)
4. [Ibex RISC-V Core (lowRISC)](https://github.com/lowRISC/ibex)
5. [Vyges FFT Accelerator IP](https://github.com/vyges/fast-fourier-transform-ip)
6. [Vyges IP Catalog](https://github.com/orgs/vyges-ip/repositories)
7. [ChipFoundry Contest Documentation](https://chipfoundry.io/challenges/application)
