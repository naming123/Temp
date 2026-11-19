#!/system/bin/sh
# MID5 클러스터(cpu5~6) 주파수 확인: CPU 계산 모델 1개를 cpu5에서 100%(sleep 없음)로 NUM_RUNS회 돌리고, 실행시간을 비교
# 사용: sh mid5check.sh default   -> 기본 설정 그대로
#       sh mid5check.sh min_max   -> policy5의 scaling_min_freq를 scaling_max_freq로 올리고 실행 (끝나면 원래 값으로 되돌림)
# 로거는 모델과 같은 코어에서 돌림 (다른 코어를 데우지 않게)
# 스킨템프는 끄고 돌린 뒤, 끝나거나 중간에 끊기면 다시 켬 (min 주파수도 같이 되돌림)
# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델 종료, 스킨템프 복구, 돈 횟수 기록, 로거 종료, 저장을 모두 함

# 모델과 실험 설정
MODEL_PATH=/data/local/tmp/SM/model/dump/inception_v3.tflite
MODEL_TAG=$(basename "$MODEL_PATH" .tflite)   # 파일 이름에서 자동으로
CORE_MASK=20          # 모델 코어: 20 = cpu5
LOGGER_MASK=$CORE_MASK  # 로거 코어 = 모델 코어
NUM_RUNS=5000         # 횟수 기준으로 돌림
MAX_SECS=1800         # 안전 상한(초). 기본 설정에서 1회 144,582 µs면 약 723초
MODE=${1:-default}    # default 또는 min_max
POLICY=/sys/devices/system/cpu/cpufreq/policy5
SKIN_OFF=1            # 1 = 스킨템프 끄고 실행, 0 = 켠 채로 실행

# 결과 폴더와 파일 이름
cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output
# 코어 mask(16진수)에서 cpu 번호를 뽑음 (04 -> 2)
core_num() {
    m=$((16#$1)); n=""; i=0
    while [ $m -gt 0 ]; do
        [ $((m & 1)) = 1 ] && n="${n}${i}"
        m=$((m >> 1))
        i=$((i + 1))
    done
    echo "$n"
}
CORE_NUM=$(core_num $CORE_MASK)
SKIN_TAG=skinoff
[ "$SKIN_OFF" = 1 ] || SKIN_TAG=skinon
OUTPUT_NAME=./output/mid5check_${SKIN_TAG}_${MODEL_TAG}_hot100_core${CORE_NUM}_${MODE}_${NUM_RUNS}iter_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL_FILE="${OUTPUT_NAME}_model1.txt"

if [ "$MODE" != default ] && [ "$MODE" != min_max ]; then
    echo "mode must be default or min_max: $MODE"
    exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "model not found: $MODEL_PATH"
    exit 1
fi

# 부팅 후 경과 시간(초, 소수 둘째 자리)
now() { cut -d' ' -f1 /proc/uptime; }

LOGGER_PID=""
LOGGER_START=""
MODEL_PID=""
MODEL_START=""
SKIN_ZONES=""
FINISHED=0
MIN_ORIG=""

# 모델을 CPU에서(delegate 없음) NUM_RUNS회 쉬지 않고 돌리고, 끝난 시각을 모델 파일에 남김
run_model() {
    taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$MODEL_PATH" \
    --num_runs=$NUM_RUNS \
    --min_secs=0 \
    --max_secs=$MAX_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    >> "$MODEL_FILE" 2>&1
    echo "model end: $(now) s" >> "$MODEL_FILE"
}

# 돈 횟수와 시간 기록: 끝까지 돌면 도구가 찍은 count, 끊기면 본 실행 시작 전인지 후인지만 적음
write_count() {
    { [ -n "$MODEL_START" ] && [ -f "$MODEL_FILE" ]; } || return
    ME=$(grep -m1 "^model end:" "$MODEL_FILE" 2>/dev/null | sed 's/model end: \([0-9.]*\).*/\1/')
    [ -z "$ME" ] && ME=$STOP
    MAIN_LINE=$(grep "count=" "$MODEL_FILE" | sed -n 2p)
    echo "===== count =====" >> "$MODEL_FILE"
    echo "target: ${NUM_RUNS} runs" >> "$MODEL_FILE"
    if [ -n "$MAIN_LINE" ]; then
        echo "done: $(echo "$MAIN_LINE" | sed 's/.*\(count=[0-9]*\).*/\1/') (도구가 찍은 값)" >> "$MODEL_FILE"
    else
        echo "stopped early: 도구가 본 실행 결과를 찍기 전에 끊김" >> "$MODEL_FILE"
    fi
    awk -v ms="$MODEL_START" -v me="$ME" '
    BEGIN { printf "model start: %.2f s, model end: %.2f s, model time: %.2f s (부팅 후 경과 시간 기준)\n", ms, me, me - ms }' >> "$MODEL_FILE"
    echo "battery temp at end: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$MODEL_FILE"
}

# 끝날 때와 중간에 끊길 때 모두 이 함수가 한 번만 돎
finish() {
    [ $FINISHED = 1 ] && return
    FINISHED=1
    STOP=$(now)

    # 1) 모델 종료
    if [ -n "$MODEL_PID" ] && kill -0 $MODEL_PID 2>/dev/null; then
        kill $MODEL_PID 2>/dev/null
        pkill -f tf_benchmark_tool 2>/dev/null
        echo "model stopped early"
    fi

    # 1-1) min 주파수 복구 (min_max일 때만 바꿨음)
    if [ -n "$MIN_ORIG" ]; then
        echo $MIN_ORIG > $POLICY/scaling_min_freq 2>/dev/null
        echo "policy5 scaling_min_freq restored: $(cat $POLICY/scaling_min_freq)"
    fi

    # 2) 스킨템프 복구
    for z in $SKIN_ZONES; do
        echo enabled > $z/mode 2>/dev/null
        echo "skin zone restored: $z -> $(cat $z/mode 2>/dev/null)"
    done

    # 3) 돈 횟수와 시간 기록
    write_count
    [ -f "$MODEL_FILE" ] && sed -n '/===== count =====/,$p' "$MODEL_FILE"

    # 4) 로거 종료
    if [ -n "$LOGGER_PID" ] && kill -0 $LOGGER_PID 2>/dev/null; then
        kill $LOGGER_PID
        wait $LOGGER_PID 2>/dev/null
    elif [ -n "$LOGGER_PID" ]; then
        echo "warning: logger exited before benchmark finished"
    fi

    # 5) 저장 확인
    chmod -R 777 ./output
    if [ -s "$OUTPUT_FILE" ]; then
        echo "saved: $OUTPUT_FILE"
    else
        echo "save failed: $OUTPUT_FILE"
    fi
}
trap 'finish; exit 130' INT TERM HUP
trap finish EXIT

[ "$(id -u)" = 0 ] || echo "warning: not root -> skin zone mode 변경이 실패할 수 있음"

# 1) 로거 시작
LOGGER_START=$(now)
taskset $LOGGER_MASK /data/local/tmp/SM/logger/logger261117_100ms_v2 "$OUTPUT_NAME" &
LOGGER_PID=$!
sleep 1

if ! kill -0 $LOGGER_PID 2>/dev/null; then
    echo "logger failed to start"
    LOGGER_PID=""
    exit 1
fi

# 2) 스킨템프 끄기
if [ "$SKIN_OFF" = 1 ]; then
    SKIN_PATTERN="skin|user_|front_temp|back_temp|quiet"
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat $z/type 2>/dev/null)
        if echo "$t" | grep -qE "$SKIN_PATTERN"; then
            echo disabled > $z/mode 2>/dev/null && SKIN_ZONES="$SKIN_ZONES $z"
            echo "skin zone: $z ($t) -> $(cat $z/mode 2>/dev/null)"
        fi
    done
    [ -z "$SKIN_ZONES" ] && echo "warning: 끈 skin zone이 없음"
fi

# 2-1) min_max: policy5의 min을 max로 올림
if [ "$MODE" = min_max ]; then
    MIN_ORIG=$(cat $POLICY/scaling_min_freq)
    cat $POLICY/scaling_max_freq > $POLICY/scaling_min_freq
    echo "policy5 scaling_min_freq: $MIN_ORIG -> $(cat $POLICY/scaling_min_freq)"
fi

# 3) 설정 기록
echo "===== setting =====" > "$MODEL_FILE"
echo "model=$MODEL_PATH (CPU, delegate 없음)" >> "$MODEL_FILE"
echo "core_mask=${CORE_MASK} logger_mask=${LOGGER_MASK} num_runs=${NUM_RUNS} max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$MODEL_FILE"
echo "mode=${MODE} policy5 scaling_min_freq=$(cat $POLICY/scaling_min_freq) scaling_max_freq=$(cat $POLICY/scaling_max_freq) governor=$(cat $POLICY/scaling_governor)" >> "$MODEL_FILE"
echo "skin zones disabled:${SKIN_ZONES:- none}" >> "$MODEL_FILE"
echo "logger start: ${LOGGER_START} s (부팅 후 경과 시간)" >> "$MODEL_FILE"
echo "battery temp at start: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$MODEL_FILE"
echo "===== main run =====" >> "$MODEL_FILE"

# 4) 모델 실행 (NUM_RUNS회 쉬지 않고)
MODEL_START=$(now)
run_model &
MODEL_PID=$!
wait $MODEL_PID
MODEL_PID=""
