# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(shell pwd)/../../../rtl/plic_pkg.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/plic_reg_file.sv

TOPLEVEL = plic_reg_file
MODULE = test_plic_reg_file

COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
