#!/bin/sh
# Probe (throwaway): the power-loss suite over many seeds, printing every failing state with its explanation and a count.
#   KIT=/path/to/tclkit tests/probe_power_soak.sh <first-seed> <last-seed> <scenarios>
cd "$(dirname "$0")/.."
bad=0; runs=0
for s in $(seq "$1" "$2"); do
    out=$(MKS_POWER_SEED=$s MKS_POWER_SCENARIOS=$3 REAL_MK=1 perl -e 'alarm 600; exec @ARGV' "$KIT" tests/run.tcl tests/test_power_loss.tcl 2>&1) || true
    runs=$((runs + 1))
    if echo "$out" | tail -1 | grep -q ' 0 failed'; then :; else bad=$((bad + 1)); echo "=== seed $s FAILED"; echo "$out" | grep -a "FAIL\|UNCAUGHT\|passed," | cut -c1-400; fi
done
echo "POWER SOAK: $runs seeds, $bad with failures"
