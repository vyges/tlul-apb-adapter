# FFT Accelerator TL-UL Integration Guide

**Applies to:** `vyges/tlul-apb-adapter@0.1.0` + `vyges/fast-fourier-transform-ip`
**Last updated:** 2026-03-12

---

## 1. Overview

This guide explains how to integrate the Vyges FFT Accelerator IP
(`vyges/fast-fourier-transform-ip`) into a TL-UL-based SoC (such as
one built around the Ibex RISC-V core and OpenTitan TL-UL crossbar)
using the `tlul_apb_adapter`.

The FFT IP provides two bus interfaces:
- **APB** (32-bit) — used in this integration; matches TL-UL data width
- **AXI4** (64-bit) — left unconnected in this path (data width mismatch)

---

## 2. Why APB, Not AXI4

The FFT IP's AXI4 port is 64-bit (`FFT_AXI_DATA_WIDTH = 64`), while TL-UL
is 32-bit. A direct AXI4→TL-UL adapter would require either:
- Data width narrowing (2 TL-UL beats per AXI4 beat), or
- A custom 64↔32 width converter

The FFT's APB port is natively 32-bit (`PWDATA/PRDATA = 32'h`) and maps
cleanly to TL-UL with no width conversion. For configuration register
access and data I/O via the APB memory-mapped interface, this is the
recommended path.

**Use case summary:**

| Access Pattern | Recommended Interface |
|---------------|----------------------|
| Configure FFT (length, mode, start) | APB via `tlul_apb_adapter` |
| Read status, scale factor, interrupts | APB via `tlul_apb_adapter` |
| Bulk data DMA transfer (future) | AXI4 directly to DMA engine |

---

## 3. Integration Steps

### Step 1: Add IPs to your SoC

Reference both IPs in your `vyges.lock` or dependency manifest:

```toml
# vyges.lock
[dependencies]
"vyges/tlul-apb-adapter" = "0.1.0"
"vyges/fast-fourier-transform-ip" = "1.0.0"
```

Or in `soc-spec.yaml`:

```yaml
peripherals:
  - name: fft_accel
    ip: vyges/fast-fourier-transform-ip@1.0.0
    config:
      fft_max_length_log2: 12
      fft_data_width: 16
    bus: tlul
    bus_adapter: vyges/tlul-apb-adapter@0.1.0
    base_address: 0x3000_0000
    size: 0x1000
```

### Step 2: Instantiate the wrapper

The `examples/fft_tlul_wrapper.sv` in this repository provides a ready-to-use
wrapper that instantiates both the adapter and the FFT IP with correct
port connections:

```systemverilog
fft_tlul_wrapper #(
  .FFT_MAX_LENGTH_LOG2 (12),
  .FFT_DATA_WIDTH      (16),
  .SOURCE_WIDTH        (8),
  .APB4_EN             (1)
) u_fft_wrapper (
  .clk_i          (clk),
  .rst_ni         (rst_n),
  // Connect TL-UL crossbar device port
  .tl_a_valid_i   (tl_fft_h2d_a_valid),
  .tl_a_opcode_i  (tl_fft_h2d_a_opcode),
  // ... all TL-UL signals ...
  .fft_done_o     (fft_irq),
  .fft_error_o    (fft_err_irq)
);
```

### Step 3: Assign address range

Assign the FFT peripheral a 4KB region in the TL-UL crossbar routing table.
A typical assignment for Caravel user project area:

```
0x3000_0000 – 0x3000_0FFF : FFT Accelerator (APB registers)
```

The APB address seen by `fft_top` will be bits `[15:0]` of the TL-UL
address (lower 16 bits, matching `FFT_APB_ADDR_WIDTH = 16`).

### Step 4: Interrupt routing

Connect `fft_done_o` and `fft_error_o` to the SoC interrupt controller
or directly to Ibex's `irq_fast_i` inputs:

```systemverilog
assign irq_fast[0] = fft_done_o;
assign irq_fast[1] = fft_error_o;
```

---

## 4. FFT APB Register Map

The FFT accelerator's control and status registers are accessed through
the APB interface. Key registers (base = `0x3000_0000`):

| Offset | Register | Access | Description |
|--------|----------|--------|-------------|
| `0x000` | `FFT_CTRL` | R/W | Control: `[0]=start`, `[1]=reset`, `[2]=rescale_en` |
| `0x004` | `FFT_STATUS` | RO | Status: `[0]=busy`, `[1]=done`, `[2]=error` |
| `0x008` | `FFT_LENGTH` | R/W | FFT length log2: `8`=256pt, `10`=1024pt, `12`=4096pt |
| `0x00C` | `FFT_CONFIG` | R/W | Mode config: `[0]=double_buffer`, `[1]=scale_track` |
| `0x010` | `FFT_SCALE` | RO | Current scale factor (auto-rescaling result) |
| `0x014` | `FFT_INT_EN` | R/W | Interrupt enable: `[0]=done_irq`, `[1]=error_irq` |
| `0x018` | `FFT_INT_STAT`| R/W1C | Interrupt status (write 1 to clear) |
| `0x100+` | `FFT_DATA[]` | R/W | Input/output sample data buffer |

> **Note:** The full register map is in the FFT IP documentation at
> [github.com/vyges/fast-fourier-transform-ip](https://github.com/vyges/fast-fourier-transform-ip).

---

## 5. Firmware Driver Example

Sample bare-metal C driver for configuring and starting a 1024-point FFT:

```c
#include <stdint.h>

#define FFT_BASE        0x30000000UL
#define FFT_CTRL        (*(volatile uint32_t *)(FFT_BASE + 0x000))
#define FFT_STATUS      (*(volatile uint32_t *)(FFT_BASE + 0x004))
#define FFT_LENGTH      (*(volatile uint32_t *)(FFT_BASE + 0x008))
#define FFT_CONFIG      (*(volatile uint32_t *)(FFT_BASE + 0x00C))
#define FFT_INT_EN      (*(volatile uint32_t *)(FFT_BASE + 0x014))
#define FFT_INT_STAT    (*(volatile uint32_t *)(FFT_BASE + 0x018))
#define FFT_DATA(i)     (*(volatile uint32_t *)(FFT_BASE + 0x100 + (i)*4))

#define FFT_CTRL_START      (1u << 0)
#define FFT_CTRL_RESET      (1u << 1)
#define FFT_CTRL_RESCALE_EN (1u << 2)
#define FFT_STATUS_BUSY     (1u << 0)
#define FFT_STATUS_DONE     (1u << 1)
#define FFT_STATUS_ERROR    (1u << 2)

// Load samples and run a 1024-point FFT
int fft_run_1024(int16_t *real_in, int16_t *imag_in,
                 int16_t *real_out, int16_t *imag_out) {
    // Reset and configure
    FFT_CTRL   = FFT_CTRL_RESET;
    FFT_LENGTH = 10;               // log2(1024) = 10
    FFT_CONFIG = 0x1;              // double-buffer enable
    FFT_INT_EN = 0x3;              // enable done + error IRQs
    FFT_CTRL   = FFT_CTRL_RESCALE_EN;

    // Load input samples (packed real[15:0] | imag[15:0])
    for (int i = 0; i < 1024; i++) {
        FFT_DATA(i) = ((uint32_t)(uint16_t)real_in[i] << 16) |
                       (uint32_t)(uint16_t)imag_in[i];
    }

    // Start FFT
    FFT_CTRL |= FFT_CTRL_START;

    // Poll for completion (or use interrupt handler)
    while (!(FFT_STATUS & FFT_STATUS_DONE)) {
        if (FFT_STATUS & FFT_STATUS_ERROR) return -1;
    }

    // Read output samples
    for (int i = 0; i < 1024; i++) {
        uint32_t v = FFT_DATA(i);
        real_out[i] = (int16_t)(v >> 16);
        imag_out[i] = (int16_t)(v & 0xFFFF);
    }

    // Clear done interrupt
    FFT_INT_STAT = FFT_INT_STAT;
    return 0;
}
```

---

## 6. Simulation: Verifying the Integration

To run the cocotb integration test from this repository:

```bash
cd tb/cocotb
SIM=icarus make MODULE=test_tlul_apb_adapter
```

For gate-level simulation after OpenLane synthesis:

```bash
cd tb/cocotb
SIM=icarus NETLIST=1 GATE_NETLIST=../../syn/tlul_apb_adapter_synth.v make
```

---

## 7. Known Integration Notes

| Issue | Detail | Mitigation |
|-------|--------|-----------|
| FFT APB clock | `fft_top` has separate `pclk_i` input | Connect to same `clk_i`; single clock domain |
| FFT address width | `FFT_APB_ADDR_WIDTH=16` | Upper bits of TL-UL address are dropped (only `[15:0]` reach FFT) |
| PSLVERR | FFT IP does not assert `pready_o`-gated error | Tie `apb_pslverr_i=1'b0` in adapter instantiation |
| AXI port tie-off | AXI port inputs must not be left floating | Wrapper ties all AXI inputs to `0`/`1'b0` |
| Interrupt polarity | `fft_done_o` is active-high | Standard for Ibex `irq_fast_i` |
