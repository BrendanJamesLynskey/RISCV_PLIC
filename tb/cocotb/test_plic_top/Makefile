# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(shell pwd)/../../../rtl/plic_pkg.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_gateway.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_priority_resolver.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_target.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_reg_file.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_top.sv

TOPLEVEL = plic_top
MODULE = test_plic_top

COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
