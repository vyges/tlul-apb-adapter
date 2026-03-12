# Copyright 2026 Vyges Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Top-level Makefile for tlul-apb-adapter
# Simulator: Verilator (via cocotb)

RTL_FILES = rtl/tlul_pkg.sv rtl/tlul_apb_adapter.sv

.PHONY: all sim lint waves clean help

all: sim

# -----------------------------------------------------------------------
# Simulation: cocotb + Verilator
# -----------------------------------------------------------------------
sim:
	$(MAKE) -C tb/cocotb SIM=verilator

# -----------------------------------------------------------------------
# Lint (Verilator lint-only)
# -----------------------------------------------------------------------
lint:
	verilator --lint-only -sv --top-module tlul_apb_adapter \
	          $(RTL_FILES) 2>&1

# -----------------------------------------------------------------------
# Waveform viewer (FST from Verilator)
# -----------------------------------------------------------------------
waves:
	gtkwave tb/cocotb/dump.fst &

# -----------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------
clean:
	$(MAKE) -C tb/cocotb clean
	rm -f *.vcd *.fst

# -----------------------------------------------------------------------
help:
	@echo "Targets:"
	@echo "  sim    - Run cocotb test suite (Verilator)"
	@echo "  lint   - Verilator lint check"
	@echo "  waves  - Open FST waveform in GTKWave"
	@echo "  clean  - Remove build artifacts"
