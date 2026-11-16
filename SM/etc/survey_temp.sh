#!/system/bin/sh
# survey_temp.sh - log every CPU/cpuss/GPU/NSP sensor individually (degC) to pick one sensor per unit
# usage: sh survey_temp.sh <out.txt> [seconds]   (default 60 s, ~100 ms interval; interval is approximate)
# Run it while the workload runs (or during the per-core taskset test) and send back the file.

OUT=${1:-survey.txt}
SEC=${2:-60}
ZONES="28 29 20 21 22 23 25 26 27 14 15 16 17 18 19 10 11 12 13 41 42 43 44 45 46 47 48 30 31 32 33 34 35"

# header: zone type names (cpu-C-K-S, cpuss-N, gpuss-N, nsphvx-N, nsphmx-N)
line="Time_ms"
for z in $ZONES; do
    read t < /sys/class/thermal/thermal_zone$z/type
    line="$line	$t"
done
echo "$line" > "$OUT"

i=0
n=$((SEC * 10))
while [ $i -lt $n ]; do
    line="$((i * 100))"
    for z in $ZONES; do
        read v < /sys/class/thermal/thermal_zone$z/temp     # builtin read: no fork per sensor
        line="$line	$((v / 1000)).$(printf '%03d' $((v % 1000)))"
    done
    echo "$line" >> "$OUT"
    i=$((i + 1))
    sleep 0.1
done
echo "done: $OUT"