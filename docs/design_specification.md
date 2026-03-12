# TL-UL to APB Adapter — Design Specification

**IP Name:** `tlul-apb-adapter`
**Namespace:** `vyges/tlul-apb-adapter`
**Version:** 0.1.0
**License:** Apache-2.0
**Classification:** Infrastructure IP
**Last updated:** 2026-03-12

---

## 1. Purpose and Scope

This document specifies the design requirements, interface definition, protocol behavior, and timing characteristics of the `tlul_apb_adapter` IP.

The adapter bridges a **TileLink Uncached Lightweight (TL-UL)** slave port to an **AMBA Peripheral Bus (APB)** master port. Its primary purpose is to allow any APB-interfaced peripheral to be connected directly to a TL-UL crossbar (such as the one used in the OpenTitan project and Ibex RISC-V SoC designs) without modification to either the bus controller or the peripheral.

### 1.1 Use Cases

- **RISC-V SoC integration**: Connect legacy or third-party APB peripherals (GPIO, UART, SPI, I2C, Timer, ADC, custom accelerators) to an Ibex/OpenTitan TL-UL fabric.
- **IP reuse**: Reuse existing APB IP in new TL-UL-based designs without re-implementing the peripheral interface.
- **Contest/tapeout**: Bridge the Vyges FFT accelerator (APB interface) into a Caravel/OpenTitan TL-UL crossbar for the ChipFoundry contest.
- **Standard bridge**: Generic infrastructure IP usable in any design requiring TL-UL ↔ APB protocol translation.

---

## 2. Supported Standards

| Standard | Version | Notes |
|----------|---------|-------|
| TileLink | TL-UL (Uncached Lightweight) | Single-beat, single-outstanding |
| AMBA APB | APB3 / APB4 | APB4 features optional via `APB4_EN` parameter |

### 2.1 TL-UL Constraints

TL-UL Uncached Lightweight enforces:
- **Single-outstanding**: only one in-flight transaction at any time
- **No burst**: each transaction is a single beat (up to 4 bytes at DW=32)
- **32-bit data width**: `TL_DW = 32`
- **32-bit address**: `TL_AW = 32`

These constraints align naturally with APB, making a lightweight adapter viable without buffering.

### 2.2 APB Mode Selection

| Feature | APB3 | APB4 (`APB4_EN=1`) |
|---------|------|---------------------|
| PSTRB (write strobes) | Not available | Driven from `tl_a_mask_i` |
| PPROT (protection) | Not available | Driven as `3'b000` |
| PSLVERR | Not observed | Mapped to `tl_d_error_o` |

When `APB4_EN = 0`: PSTRB is driven `4'hF` (all bytes enabled), PSLVERR is ignored.

---

## 3. Interface Definition

### 3.1 Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `AW` | `int unsigned` | 32 | Address bus width (bits). Must be ≤ 32. |
| `DW` | `int unsigned` | 32 | Data bus width (bits). Must be 32. |
| `DBW` | `int unsigned` | `DW/8` | Data byte width (derived). |
| `SOURCE_WIDTH` | `int unsigned` | 8 | TL-UL source/sink ID field width (bits). |
| `APB4_EN` | `bit` | 1 | `1` = APB4 (PSTRB/PPROT/PSLVERR), `0` = APB3. |

### 3.2 TL-UL Slave Ports

#### A Channel (Request — Host to Device)

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `tl_a_valid_i` | Input | 1 | A channel valid |
| `tl_a_opcode_i` | Input | 3 | Opcode: `4=Get`, `0=PutFullData`, `1=PutPartialData` |
| `tl_a_param_i` | Input | 3 | Protocol parameter (must be `3'b000` for TL-UL) |
| `tl_a_size_i` | Input | 2 | Transfer size: `0=1B`, `1=2B`, `2=4B` |
| `tl_a_source_i` | Input | `SOURCE_WIDTH` | Transaction ID (echoed in `tl_d_source_o`) |
| `tl_a_address_i` | Input | `AW` | Target address |
| `tl_a_mask_i` | Input | `DBW` | Byte enable mask (`APB4_EN=1`: maps to PSTRB) |
| `tl_a_data_i` | Input | `DW` | Write data (ignored for `Get`) |
| `tl_a_ready_o` | Output | 1 | Adapter ready to accept new request |

#### D Channel (Response — Device to Host)

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `tl_d_valid_o` | Output | 1 | D channel valid |
| `tl_d_opcode_o` | Output | 3 | `0=AccessAck` (write), `1=AccessAckData` (read) |
| `tl_d_param_o` | Output | 2 | Always `2'b00` |
| `tl_d_size_o` | Output | 2 | Echo of `tl_a_size_i` |
| `tl_d_source_o` | Output | `SOURCE_WIDTH` | Echo of `tl_a_source_i` |
| `tl_d_error_o` | Output | 1 | Error: `1` if PSLVERR asserted (APB4 only) |
| `tl_d_data_o` | Output | `DW` | Read data (`32'h0` for writes) |
| `tl_d_ready_i` | Input | 1 | Host ready to accept D channel response |

### 3.3 APB Master Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `apb_psel_o` | Output | 1 | Peripheral select |
| `apb_penable_o` | Output | 1 | Enable (asserted in access phase) |
| `apb_pwrite_o` | Output | 1 | `1` = write, `0` = read |
| `apb_paddr_o` | Output | `AW` | Address |
| `apb_pwdata_o` | Output | `DW` | Write data |
| `apb_pstrb_o` | Output | `DBW` | Write strobes (`APB4_EN=1`: from mask; else `4'hF`) |
| `apb_pprot_o` | Output | 3 | Protection (`3'b000` — unprivileged, non-secure, data) |
| `apb_prdata_i` | Input | `DW` | Read data from peripheral |
| `apb_pready_i` | Input | 1 | Peripheral ready (extends access phase when low) |
| `apb_pslverr_i` | Input | 1 | Slave error (APB4; tie `1'b0` for APB3 peripherals) |

### 3.4 Clocking and Reset

| Signal | Direction | Description |
|--------|-----------|-------------|
| `clk_i` | Input | System clock. Both TL-UL and APB use this single clock. |
| `rst_ni` | Input | Active-low synchronous reset. All registers reset to 0. |

> **Note:** This adapter is a single-clock-domain design. Clock domain crossing is not provided. If the APB peripheral operates on a different clock, an external CDC wrapper is required.

---

## 4. Functional Description

### 4.1 Transaction State Machine

The adapter implements a 4-state finite state machine (FSM):

```
         tl_a_valid
IDLE ───────────────► APB_SETUP
 ▲                        │
 │                        │ (next cycle)
 │                        ▼
 │            ┌──── APB_ACCESS
 │            │         │
 │      !pready          │ pready
 │            └──────────┘
 │                        ▼
 │       tl_d_ready   TL_RESP
 └───────────────────────┘
```

| State | PSEL | PENABLE | a_ready | d_valid | Description |
|-------|------|---------|---------|---------|-------------|
| `IDLE` | 0 | 0 | 1 | 0 | Ready; accepts next TL-UL request |
| `APB_SETUP` | 1 | 0 | 0 | 0 | APB setup phase — drives address/data/control |
| `APB_ACCESS` | 1 | 1 | 0 | 0 | APB access phase — waits for `PREADY` |
| `TL_RESP` | 0 | 0 | 0 | 1 | TL-UL D channel — waits for `d_ready` |

### 4.2 Read Transaction (Get)

```
Cycle:    T0       T1          T2          T3
State: IDLE→SETUP  APB_SETUP   APB_ACCESS  TL_RESP
        ___         ___________
PSEL:  ╱   ╲                   ╲___
           ____________________
PENABLE:  ╱ setup ╱ access                ╲___
                              ✓ PREADY
                              prdata captured → d_data
                                          ___
d_valid:                                 ╱   ╲
                                              ✓ d_ready
```

### 4.3 Write Transaction (PutFullData / PutPartialData)

Identical state machine to read. In `TL_RESP`, `tl_d_opcode_o = AccessAck` (no data). `tl_d_data_o` is driven to `32'h0`.

### 4.4 PREADY Extension

If an APB slave de-asserts `PREADY` (inserts wait states), the adapter remains in `APB_ACCESS` until `PREADY` is sampled high. There is no limit on wait cycles enforced by the adapter; a higher-level bus timeout mechanism may be required for robustness.

### 4.5 D-Channel Back-Pressure

Once `tl_d_valid_o` is asserted, it remains asserted until `tl_d_ready_i` is sampled high. The adapter does not accept a new A-channel request (`tl_a_ready_o = 0`) during this time. This upholds the TL-UL ordering constraint.

### 4.6 Reset Behavior

On the de-assertion of `rst_ni`:
- FSM returns to `IDLE`
- All request/response capture registers cleared to zero
- `tl_a_ready_o = 1`, `tl_d_valid_o = 0`, `apb_psel_o = 0`

---

## 5. Timing Characteristics

### 5.1 Latency

| Scenario | Cycles |
|----------|--------|
| Zero-wait APB slave | 3 (SETUP + ACCESS + RESP) |
| N-wait-cycle APB slave | 3 + N |
| D-channel back-pressure (+M cycles) | 3 + M |

### 5.2 Throughput

- **Maximum throughput**: 1 transaction per 3 cycles (zero-wait, immediate d_ready)
- **Back-to-back**: New transaction starts the cycle after `tl_d_ready_i` is sampled in `TL_RESP` (returns to `IDLE`)

### 5.3 Waveform — Minimum Latency Read

```
        ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐
clk     ┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──
              ┌─────┐
a_valid ──────┘     └────────────────────────
              ┌─────┐
a_ready ──────┘     └────────────────────────
                    ┌─────┐
PSEL    ────────────┘     └──────────────────
                          ┌─────┐
PENABLE ──────────────────┘     └────────────
                          ┌─────┐
PREADY  ──────────────────┘     └────────────
                                ┌─────┐
d_valid ────────────────────────┘     └──────
                                ┌─────┐
d_ready ────────────────────────┘     └──────
```

---

## 6. Verification Plan

### 6.1 Test Matrix

| TC# | Test Name | Stimulus | Expected | Simulator |
|-----|-----------|----------|----------|-----------|
| TC01 | Read zero-wait | Get, PREADY immediate | d_data=PRDATA, d_error=0 | iverilog, cocotb |
| TC02 | Write zero-wait | PutFullData, PREADY immediate | AccessAck, d_error=0 | iverilog, cocotb |
| TC03 | Partial write | PutPartialData, mask=0b0110 | PSTRB=0b0110 | iverilog, cocotb |
| TC04 | Multi-cycle slave | Get, 3 wait cycles | d_data=PRDATA, d_error=0 | iverilog, cocotb |
| TC05 | Back-to-back | Write then read | Both complete correctly | iverilog, cocotb |
| TC06 | PSLVERR | Get, PSLVERR=1 | d_error=1 | iverilog, cocotb |
| TC07 | d_ready backpressure | Get, d_ready held low | d_valid held until d_ready | iverilog, cocotb |
| TC08 | Reset mid-transaction | Reset in APB_SETUP | Returns to IDLE cleanly | iverilog, cocotb |
| TC09 | Stress random | 20 random rd/wr, random waits | All match expected | cocotb |

### 6.2 Protocol Assertions

The SystemVerilog testbench includes protocol-level assertions:
- `PENABLE` must be preceded by `PSEL`
- `PADDR` stable during access phase
- `tl_d_source_o` echoes `tl_a_source_i`

### 6.3 Coverage Goals

| Metric | Target |
|--------|--------|
| Statement coverage | 100% |
| Branch coverage | 100% |
| FSM state coverage | All 4 states |
| FSM transition coverage | All valid transitions |
| PREADY wait cycles | 0, 1, 2, 3+ |
| APB4_EN parameter | Both values |

---

## 7. Resource Utilization Estimates

The following estimates are for SKY130 PDK (OpenLane synthesis) at typical corner:

| Resource | Estimate |
|----------|----------|
| Cell count | ~50–80 standard cells |
| Flip-flops | ~120–140 bits (FSM + capture registers) |
| Critical path | Datapath through register capture (~2 gate levels) |
| Frequency | >200 MHz at typical corner |

> **Note:** The adapter is a pure combinational/registered bridge with no memories or arrays. Resource consumption is minimal.

---

## 8. Known Limitations and Future Work

| Item | Description | Priority |
|------|-------------|----------|
| Single-outstanding | No pipelining; one transaction at a time | By design (TL-UL-UL constraint) |
| APB3 PSLVERR | `APB4_EN=0` ignores PSLVERR; error not propagated | Low |
| PPROT | Always `3'b000` (unprivileged); no TrustZone mapping | Medium |
| CDC | No clock-domain crossing; same clock for TL-UL and APB | Medium |
| AW < 32 | Only lower `AW` bits of address used; upper bits zero | Low |
| Burst | TL-UL-UL has no burst; adapter does not need burst APB | N/A |

---

## 9. References

1. [TileLink Specification 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b18_tilelink_spec_1.8.1.pdf)
2. [AMBA APB Protocol Specification](https://developer.arm.com/documentation/ihi0024/latest)
3. [OpenTitan TL-UL Protocol Checker](https://github.com/lowrisc/opentitan/tree/master/hw/ip/tlul)
4. [Ibex RISC-V Core Documentation](https://ibex-core.readthedocs.io/)
5. [Vyges FFT Accelerator IP](https://github.com/vyges/fast-fourier-transform-ip)
6. [Vyges IP Catalog](https://github.com/orgs/vyges-ip/repositories)
