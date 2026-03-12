# Copyright 2026 Vyges Inc.
# SPDX-License-Identifier: Apache-2.0
#
# cocotb Makefile for tlul_apb_adapter — Verilator

TOPLEVEL_LANG  = verilog
TOPLEVEL       = tlul_apb_adapter
MODULE         = test_tlul_apb_adapter
SIM            = verilator

# Source files
RTL_DIR        = ../../rtl
VERILOG_SOURCES = $(RTL_DIR)/tlul_pkg.sv \
                  $(RTL_DIR)/tlul_apb_adapter.sv

# Verilator flags
COMPILE_ARGS   = -sv --timing
EXTRA_ARGS    += --trace-fst

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: waves clean-waves
waves:
	gtkwave dump.fst &

clean-waves:
	rm -f *.fst dump.*
