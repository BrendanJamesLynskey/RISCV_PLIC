#!/bin/bash
# Brendan Lynskey 2025
set -e
PASS=0
FAIL=0

run_test() {
    local name=$1
    shift
    echo "=== Building $name ==="
    iverilog -g2012 -o sim_${name} "$@"
    echo "=== Running $name ==="
    if vvp sim_${name}; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAILED: $name"
    fi
    rm -f sim_${name}
}

run_test gateway    rtl/plic_pkg.sv rtl/plic_gateway.sv tb/sv/tb_plic_gateway.sv
run_test resolver   rtl/plic_pkg.sv rtl/plic_priority_resolver.sv tb/sv/tb_plic_priority_resolver.sv
run_test target     rtl/plic_pkg.sv rtl/plic_target.sv tb/sv/tb_plic_target.sv
run_test reg_file   rtl/plic_pkg.sv rtl/plic_reg_file.sv tb/sv/tb_plic_reg_file.sv
run_test top        rtl/plic_pkg.sv rtl/plic_gateway.sv rtl/plic_priority_resolver.sv rtl/plic_target.sv rtl/plic_reg_file.sv rtl/plic_top.sv tb/sv/tb_plic_top.sv

echo ""
echo "=============================="
echo " SV RESULTS: $PASS passed, $FAIL failed"
echo "=============================="
[ $FAIL -eq 0 ] || exit 1
