# Copyright 2026 Vyges Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Timing Constraints: tlul_apb_adapter
# Targets: OpenLane (SKY130), Synopsys Design Compiler

# Primary clock
create_clock -name clk_i -period 5.0 [get_ports clk_i]

# Input delays (relative to clk_i)
set_input_delay  -clock clk_i -max 1.5 [all_inputs]
set_input_delay  -clock clk_i -min 0.5 [all_inputs]

# Output delays (relative to clk_i)
set_output_delay -clock clk_i -max 1.5 [all_outputs]
set_output_delay -clock clk_i -min 0.5 [all_outputs]

# False paths on reset (asynchronous is not used here; rst_ni is synchronous)
set_false_path -from [get_ports rst_ni]
