#!/bin/sh
# Quick seed sweep — try a few seeds to close timing.
#
# NOTE: this is FOUR full builds, run one after another (~40 min each). It
# takes the same lock as build.sh and uses the same 10G cap, so it can never
# run alongside a build -- but it does hold the lock for hours.
set -e
cd "$(dirname "$0")"

export QUARTUS_ROOTDIR=/storage01/tools/intelFPGA_lite/17.0/quartus
export PATH="$QUARTUS_ROOTDIR/bin:$PATH"

# One build at a time, shared with build.sh.
LOCK=/tmp/rayforce_build.lock
exec 9>>"$LOCK"
if ! flock -n 9; then
    echo "REFUSED: a Ray Force build is already running (pid $(cat "$LOCK" 2>/dev/null))." >&2
    exit 1
fi
: > "$LOCK"
echo $$ >&9

SEEDS="3 8 11 13"
BEST_SEED=""
BEST_SLACK="-999"

for SEED in $SEEDS; do
    echo "=== Seed $SEED ==="
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $SEED/" Rayforce.qsf

    rm -rf db incremental_db output_files
    systemd-run --user --scope --quiet \
        -p MemoryHigh=10G -p MemoryMax=10G -p MemorySwapMax=0 -p CPUWeight=80 \
        nice -n 5 quartus_sh --flow compile Rayforce > /tmp/rf_seed_$SEED.log 2>&1

    if [ -f output_files/Rayforce.sta.rpt ]; then
        SLACK=$(grep "Worst-case setup slack" output_files/Rayforce.sta.rpt | awk '{print $5}')
        echo "Seed $SEED: slack = $SLACK"
        if [ -n "$SLACK" ] && [ "$(echo "$SLACK > $BEST_SLACK" | bc -l)" = "1" ]; then
            BEST_SLACK=$SLACK
            BEST_SEED=$SEED
        fi
    else
        echo "Seed $SEED: FAILED (no sta.rpt)"
    fi
done

echo ""
echo "Best seed: $BEST_SEED (slack = $BEST_SLACK)"
sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $BEST_SEED/" Rayforce.qsf
echo "QSF updated to seed $BEST_SEED"
