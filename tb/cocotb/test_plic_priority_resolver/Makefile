# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(shell pwd)/../../../rtl/plic_pkg.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_priority_resolver.sv

TOPLEVEL = plic_priority_resolver
MODULE = test_plic_priority_resolver

COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
