#!/usr/bin/env bash
# Day 1 + Day 6: OOC synth/impl of every thesis top at a set of clock periods.
# Each run is a fresh Vivado process so runs cannot contaminate each other.
#
#   VIVADO=/c/AMD/Vivado/2026.1/bin/vivado.bat vc709/tcl/fmax_sweep.sh
#   PERIODS="5.0 4.0" TOPS="fir8_fold" vc709/tcl/fmax_sweep.sh
#
# Results: vc709/reports/summary.csv (one line per run) + per-run report dirs.
set -e
cd "$(dirname "$0")/../.."
VIVADO="${VIVADO:-vivado}"
TOPS="${TOPS:-mrpm_radix4 mrpm_radix4_wide fir8_fold fir8_fold_pipelined}"
PERIODS="${PERIODS:-5.0 4.0 3.5 3.0 2.5 2.0}"
ADDER="${ADDER:-han_carlson_adder}"
mkdir -p vc709/reports/logs
for top in $TOPS; do
  for p in $PERIODS; do
    echo "### $top @ $p ns ($ADDER)"
    "$VIVADO" -mode batch -nojournal -log "vc709/reports/logs/${top}_${ADDER}_p${p}.log" \
      -source vc709/tcl/synth_ooc.tcl -tclargs "$top" "$p" impl "$ADDER" | grep -E "^RESULT|WNS=|LUT=|ERROR"
  done
done
echo "--- vc709/reports/summary.csv ---"
cat vc709/reports/summary.csv
