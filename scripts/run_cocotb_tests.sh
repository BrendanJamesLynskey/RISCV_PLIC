#!/bin/bash
# Brendan Lynskey 2025
set -e
PASS=0
FAIL=0

for dir in tb/cocotb/test_*/; do
    echo "=== Running CocoTB: $dir ==="
    if (cd "$dir" && make); then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAILED: $dir"
    fi
done

echo ""
echo "=============================="
echo " CocoTB RESULTS: $PASS passed, $FAIL failed"
echo "=============================="
[ $FAIL -eq 0 ] || exit 1
