#!/system/bin/sh
# policy5(cpu5, cpu6)의 최소 클럭을 1.19 GHz 바로 위(PIN_MIN)로 올린 뒤 코어마다 부하를 걸고,
# 로거(100 ms)로 클럭, 사용률, 온도를 같이 기록함.
# 확인하려는 것: walt가 1.19 GHz에서 멈추던 게 "그 이상은 안 올림"인지,
#               최소값을 올려 주면 그 위로도 올라가는지
# 끝나거나 Ctrl+C로 끊겨도 scaling_min_freq를 원래 값으로 되돌리고 로거를 멈춤

PIN_MIN=1286400       # 1.19 GHz(1190400) 바로 위 단계
CORES="5 6"           # 확인할 코어
IDLE_SECS=10          # 로거 시작 후 첫 부하까지 대기(초), 기준 온도용
LOAD_SECS=20          # 코어 하나에 부하 거는 시간(초)
REST_SECS=60          # 코어 사이 대기(초)
ZONES="10 11 12 13 14 15 16 17 18 19 20 21 22 23 25 26 27 28 29"   # cpuss-0~3 + cpu-*-*-* (24 = aoss-1 제외)
LOGGER=./logger       # 로거 실행 파일
LOGGER_MASK=01        # 로거는 cpu0에 고정

POL=/sys/devices/system/cpu/cpufreq/policy5

cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output
STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=./output/zone_map_policy5_min${PIN_MIN}_${STAMP}.txt
LOG_NAME=./output/logger_policy5_min${PIN_MIN}_${STAMP}     # 로거가 .txt를 붙임

# PIN_MIN이 실제로 있는 클럭 단계인지 확인
case " $(cat $POL/scaling_available_frequencies) " in
    *" $PIN_MIN "*) ;;
    *) echo "PIN_MIN $PIN_MIN 은 policy5 클럭 단계에 없음"; exit 1 ;;
esac
[ -x "$LOGGER" ] || { echo "logger 없음: $LOGGER"; exit 1; }

ORIG_MIN=$(cat $POL/scaling_min_freq)
LOAD_PID=""
LOGGER_PID=""

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

cleanup() {
    [ -n "$LOAD_PID" ] && kill $LOAD_PID 2>/dev/null
    [ -n "$LOGGER_PID" ] && { kill -TERM $LOGGER_PID 2>/dev/null; wait $LOGGER_PID 2>/dev/null; }
    LOAD_PID=""; LOGGER_PID=""
    echo $ORIG_MIN > $POL/scaling_min_freq
    echo "restored policy5 scaling_min_freq = $(cat $POL/scaling_min_freq)"
}

read_all() {
    for n in $ZONES; do echo -n "$(cat /sys/class/thermal/thermal_zone$n/temp) "; done
}

{
trap 'cleanup; exit 130' INT TERM HUP

echo $PIN_MIN > $POL/scaling_min_freq
taskset $LOGGER_MASK $LOGGER $LOG_NAME &
LOGGER_PID=$!
T0=$(now_ms)

echo "policy5 min=$(cat $POL/scaling_min_freq) max=$(cat $POL/scaling_max_freq) (orig min $ORIG_MIN)"
echo "load ${LOAD_SECS}s per core, rest ${REST_SECS}s, logger ${LOG_NAME}.txt on mask ${LOGGER_MASK}"
sleep $IDLE_SECS

for c in $CORES; do
    m=$(printf "%02x" $((1 << c)))
    BEFORE=$(read_all)
    S=$(( ($(now_ms) - T0) / 1000 ))
    taskset $m sh -c 'while :; do :; done' &
    LOAD_PID=$!
    sleep $((LOAD_SECS - 1))
    FREQ=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq)
    sleep 1
    AFTER=$(read_all)
    kill $LOAD_PID 2>/dev/null
    wait $LOAD_PID 2>/dev/null
    LOAD_PID=""
    E=$(( ($(now_ms) - T0) / 1000 ))

    echo "===== cpu${c} (mask ${m}) : load ${S}s ~ ${E}s (logger Time), cur_freq ${FREQ} kHz ====="
    i=1
    for n in $ZONES; do
        b=$(echo $BEFORE | cut -d' ' -f$i)
        a=$(echo $AFTER | cut -d' ' -f$i)
        t=$(cat /sys/class/thermal/thermal_zone$n/type)
        awk -v n="$n" -v t="$t" -v b="$b" -v a="$a" \
            'BEGIN { printf "%6.1f C  zone%-3s %-12s (%.1f -> %.1f)\n", (a - b) / 1000, n, t, b / 1000, a / 1000 }'
        i=$((i + 1))
    done | sort -r -n

    [ "$c" != "${CORES##* }" ] && sleep $REST_SECS
done
sleep $IDLE_SECS      # 마지막 부하 뒤 식는 구간도 기록
cleanup
} 2>&1 | tee "$OUTPUT_FILE"

# 혹시 위에서 못 되돌렸을 때를 대비해 한 번 더 확인
[ "$(cat $POL/scaling_min_freq)" != "$ORIG_MIN" ] && echo $ORIG_MIN > $POL/scaling_min_freq
echo "policy5 scaling_min_freq now = $(cat $POL/scaling_min_freq)"
echo "saved: $OUTPUT_FILE, ${LOG_NAME}.txt"