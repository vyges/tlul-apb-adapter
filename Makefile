# Copyright 2026 Vyges Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Top-level Makefile for tlul-apb-adapter

RTL_FILES  = rtl/tlul_pkg.sv rtl/tlul_apb_adapter.sv
TB_FILE    = tb/tb_tlul_apb_adapter.sv
SIM_OUT    = sim.vvp

.PHONY: all sim sim-cocotb lint clean help

all: sim

# -----------------------------------------------------------------------
# Simulation: iverilog + vvp
# -----------------------------------------------------------------------
sim: $(SIM_OUT)
	vvp $(SIM_OUT)

$(SIM_OUT): $(RTL_FILES) $(TB_FILE)
	iverilog -g2012 -Wall -o $@ $^

# -----------------------------------------------------------------------
# cocotb simulation
# -----------------------------------------------------------------------
sim-cocotb:
	$(MAKE) -C tb/cocotb SIM=icarus

sim-cocotb-verilator:
	$(MAKE) -C tb/cocotb SIM=verilator

# -----------------------------------------------------------------------
# Lint (Verilator lint-only)
# -----------------------------------------------------------------------
lint:
	verilator --lint-only -sv --top-module tlul_apb_adapter \
	          $(RTL_FILES) 2>&1

# -----------------------------------------------------------------------
# Waveform viewer
# -----------------------------------------------------------------------
waves:
	gtkwave tlul_apb_adapter.vcd &

# -----------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------
clean:
	rm -f $(SIM_OUT) *.vcd *.fst
	$(MAKE) -C tb/cocotb clean

# -----------------------------------------------------------------------
help:
	@echo "Targets:"
	@echo "  sim                - Compile and run SV testbench (iverilog)"
	@echo "  sim-cocotb         - Run cocotb tests (icarus)"
	@echo "  sim-cocotb-verilator - Run cocotb tests (verilator)"
	@echo "  lint               - Run Verilator lint check"
	@echo "  waves              - Open waveform in GTKWave"
	@echo "  clean              - Remove build artifacts"
