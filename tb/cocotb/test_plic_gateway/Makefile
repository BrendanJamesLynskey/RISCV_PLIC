# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(shell pwd)/../../../rtl/plic_pkg.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_gateway.sv

TOPLEVEL = plic_gateway
MODULE = test_plic_gateway

COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
