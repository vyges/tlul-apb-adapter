# tlul-apb-adapter

**Vyges Infrastructure IP** | `vyges/tlul-apb-adapter@0.1.0`

A generic, parameterized TileLink Uncached Lightweight (TL-UL) slave to AMBA APB master protocol adapter. Enables any APB peripheral to be connected to a TL-UL bus fabric (Ibex, OpenTitan) without modification to either side.

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Maturity: Prototype](https://img.shields.io/badge/Maturity-Prototype-orange.svg)](vyges-metadata.json)

---

## Overview

```
  TL-UL Crossbar                         APB Peripheral
  ┌──────────────┐                        ┌──────────────┐
  │  device port ├─── tlul_apb_adapter ───┤  APB slave   │
  └──────────────┘                        └──────────────┘
  (Ibex / OpenTitan)                   (GPIO, UART, FFT, ...)
```

The adapter translates the TL-UL A/D channel handshake to the APB setup/access phase sequence, handles PREADY wait-state extension, propagates APB4 PSLVERR to TL-UL `d_error`, and echoes `a_source` in `d_source` for correct crossbar routing.

**Key properties:**
- Zero buffering — single-outstanding constraint enforced by design
- Minimum 3-cycle latency (zero-wait APB slave)
- ~50–80 standard cells (SKY130); 40 LUTs (FPGA)
- APB3 and APB4 support via `APB4_EN` parameter
- OpenTitan/Ibex TL-UL struct compatible (`tlul_pkg.sv`)

---

## File Structure

```
rtl/
  tlul_pkg.sv              TL-UL type definitions (OpenTitan-compatible)
  tlul_apb_adapter.sv      Main adapter module

tb/
  tb_tlul_apb_adapter.sv   SystemVerilog testbench (TC01–TC08)
  cocotb/
    test_tlul_apb_adapter.py  cocotb test suite (TC01–TC09)
    Makefile

docs/
  design_specification.md  Interface definition, timing, verification plan
  architecture.md          Internal architecture, design decisions
  fft_integration_guide.md Step-by-step FFT APB integration example

examples/
  fft_tlul_wrapper.sv      Wrapper: adapter + Vyges FFT Accelerator

constraints/
  tlul_apb_adapter.sdc     Timing constraints (OpenLane/Synopsys)

vyges-metadata.json        Vyges IP catalog metadata
```

---

## Quick Start

### Instantiate in your SoC

```systemverilog
tlul_apb_adapter #(
  .AW          (32),
  .DW          (32),
  .SOURCE_WIDTH(8),
  .APB4_EN     (1)     // 1=APB4 (PSTRB/PSLVERR), 0=APB3
) u_tlul_apb_periph (
  .clk_i          (clk),
  .rst_ni         (rst_n),
  // TL-UL slave (connect to xbar device port)
  .tl_a_valid_i   (...), .tl_a_opcode_i (...),
  .tl_a_param_i   (...), .tl_a_size_i   (...),
  .tl_a_source_i  (...), .tl_a_address_i(...),
  .tl_a_mask_i    (...), .tl_a_data_i   (...),
  .tl_a_ready_o   (...),
  .tl_d_valid_o   (...), .tl_d_opcode_o (...),
  .tl_d_param_o   (...), .tl_d_size_o   (...),
  .tl_d_source_o  (...), .tl_d_error_o  (...),
  .tl_d_data_o    (...), .tl_d_ready_i  (...),
  // APB master (connect to peripheral)
  .apb_psel_o     (...), .apb_penable_o (...),
  .apb_pwrite_o   (...), .apb_paddr_o   (...),
  .apb_pwdata_o   (...), .apb_pstrb_o   (...),
  .apb_pprot_o    (...),
  .apb_prdata_i   (...), .apb_pready_i  (...),
  .apb_pslverr_i  (...)
);
```

### Run Simulations

**SystemVerilog testbench (Icarus Verilog):**
```bash
iverilog -g2012 -o sim.vvp rtl/tlul_pkg.sv rtl/tlul_apb_adapter.sv \
         tb/tb_tlul_apb_adapter.sv && vvp sim.vvp
```

**cocotb (Icarus Verilog):**
```bash
cd tb/cocotb && make SIM=icarus
```

**cocotb (Verilator):**
```bash
cd tb/cocotb && make SIM=verilator
```

**Lint:**
```bash
make lint
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AW` | 32 | Address width (bits, must be ≤ 32) |
| `DW` | 32 | Data width (must be 32) |
| `SOURCE_WIDTH` | 8 | TL-UL source/sink ID width |
| `APB4_EN` | 1 | `1`=APB4 (PSTRB/PPROT/PSLVERR), `0`=APB3 |

---

## Timing

| Scenario | Latency (cycles) |
|----------|-----------------|
| Zero-wait APB slave | 3 |
| N-wait-state APB slave | 3 + N |
| Max throughput | 1 transaction / 3 cycles |

---

## Integration with Vyges FFT Accelerator

See [`docs/fft_integration_guide.md`](docs/fft_integration_guide.md) and [`examples/fft_tlul_wrapper.sv`](examples/fft_tlul_wrapper.sv) for a complete worked example connecting the [Vyges FFT Accelerator](https://github.com/vyges/fast-fourier-transform-ip) APB port to a TL-UL crossbar.

---

## Compatibility

- **Bus fabrics**: OpenTitan TL-UL crossbar, Ibex RISC-V SoC, any TL-UL-compliant fabric
- **Simulators**: Icarus Verilog (`iverilog`), Verilator, ModelSim/Xcelium
- **Synthesis**: Yosys, Synopsys Design Compiler, Vivado
- **PDKs**: SKY130 (OpenLane), GF180MCU (OpenLane), any standard cell process
- **FPGA**: Xilinx 7-series/UltraScale, Intel Cyclone/Arria, Lattice iCE40/ECP5

---

## License

Copyright 2026 Vyges Inc.  
Licensed under the [Apache License, Version 2.0](LICENSE).

---

## Related IPs

- [vyges/fast-fourier-transform-ip](https://github.com/vyges/fast-fourier-transform-ip) — FFT accelerator with APB/AXI interfaces
- [Vyges IP Catalog](https://github.com/orgs/vyges-ip/repositories) — Curated open-source silicon IP
