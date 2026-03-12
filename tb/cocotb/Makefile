# Copyright 2026 Vyges Inc.
# SPDX-License-Identifier: Apache-2.0
#
# cocotb Makefile for tlul_apb_adapter

TOPLEVEL_LANG  ?= verilog
TOPLEVEL        = tlul_apb_adapter
MODULE          = test_tlul_apb_adapter

# Simulator: icarus (default) or verilator
SIM            ?= icarus

# Source files
RTL_DIR         = ../../rtl
VERILOG_SOURCES = $(RTL_DIR)/tlul_pkg.sv \
                  $(RTL_DIR)/tlul_apb_adapter.sv

# Simulator-specific flags
ifeq ($(SIM), icarus)
  COMPILE_ARGS  = -g2012
endif

ifeq ($(SIM), verilator)
  COMPILE_ARGS  = -sv --timing
  EXTRA_ARGS   += --trace-fst
endif

# Wave dump
ifeq ($(SIM), icarus)
  PLUSARGS     += +vcd
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: waves clean-waves
waves:
	gtkwave tlul_apb_adapter.vcd &

clean-waves:
	rm -f *.vcd *.fst
