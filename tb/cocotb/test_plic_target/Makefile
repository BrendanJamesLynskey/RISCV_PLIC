# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(shell pwd)/../../../rtl/plic_pkg.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_target.sv

TOPLEVEL = plic_target
MODULE = test_plic_target

COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
