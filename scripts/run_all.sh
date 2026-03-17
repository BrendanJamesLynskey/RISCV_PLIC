#!/bin/bash
# Brendan Lynskey 2025
echo "=== Running all SystemVerilog tests ==="
bash scripts/run_sv_tests.sh
echo ""
echo "=== Running all CocoTB tests ==="
bash scripts/run_cocotb_tests.sh
echo ""
echo "=== ALL TESTS COMPLETE ==="
