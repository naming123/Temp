#!/system/bin/sh
# 2단계 (CPU 뜨거운 코어 두 개의 거리): CPU 계산 모델 2개를 코어 2개에서 각각 100%(sleep 없음)로 HEAT_SECS초 동시에 돌리고, 모든 코어와 NPU 온도를 로거로 기록
# 배치마다 CORE_MASK1, CORE_MASK2만 다름 (cpu2+cpu3, cpu2+cpu4, cpu2+cpu6)
# 로거는 두 모델 코어에서 돌림 (LOGGER_MASK = CORE_MASK1 + CORE_MASK2)
# 스킨템프는 끄고 돌린 뒤, 끝나거나 중간에 끊기면 다시 켬
# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델 종료, 스킨템프 복구, 돈 횟수 기록, 로거 종료, 저장을 모두 함

# 모델과 실험 설정
MODEL_PATH=/data/local/tmp/SM/model/dump/inception_v3.tflite
MODEL_TAG=$(basename "$MODEL_PATH" .tflite)   # 파일 이름에서 자동으로
CORE_MASK1=04         # model1 코어: 04 = cpu2
CORE_MASK2=10         # model2 코어: 08 = cpu3, 10 = cpu4, 40 = cpu6
CORE_MASK=$(printf '%02X' $((16#$CORE_MASK1 | 16#$CORE_MASK2)))   # 두 모델 코어 합 (04 + 08 = 0C)
LOGGER_MASK=$CORE_MASK  # 로거 코어 = 두 모델 코어
HEAT_SECS=900         # 가열 시간(초). 시간 기준으로 돌림
SKIN_OFF=1            # 1 = 스킨템프 끄고 실행, 0 = 켠 채로 실행

# 결과 폴더와 파일 이름
cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output
# 코어 mask(16진수)에서 cpu 번호를 뽑음 (0C -> 23)
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
OUTPUT_NAME=./output/step2_${SKIN_TAG}_${MODEL_TAG}_hot100_core${CORE_NUM}_$((HEAT_SECS / 60))min_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL1_FILE="${OUTPUT_NAME}_model1.txt"
MODEL2_FILE="${OUTPUT_NAME}_model2.txt"

if [ ! -f "$MODEL_PATH" ]; then
    echo "model not found: $MODEL_PATH"
    exit 1
fi

# 부팅 후 경과 시간(초, 소수 둘째 자리)
now() { cut -d' ' -f1 /proc/uptime; }

LOGGER_PID=""
LOGGER_START=""
MODEL1_PID=""
MODEL2_PID=""
MODEL_START=""
SKIN_ZONES=""
FINISHED=0

# 모델을 CPU에서(delegate 없음) HEAT_SECS초 동안 쉬지 않고 돌리고, 끝난 시각을 모델 파일에 남김
# 사용: run_model 코어mask 모델파일
run_model() {
    taskset $1 /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$MODEL_PATH" \
    --num_runs=100000000 \
    --min_secs=$HEAT_SECS \
    --max_secs=$HEAT_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    >> "$2" 2>&1
    echo "model end: $(now) s" >> "$2"
}

# 돈 횟수와 시간 기록: 끝까지 돌면 도구가 찍은 count, 끊기면 본 실행 시작 전인지 후인지만 적음
# 사용: write_count 모델파일
write_count() {
    { [ -n "$MODEL_START" ] && [ -f "$1" ]; } || return
    ME=$(grep -m1 "^model end:" "$1" 2>/dev/null | sed 's/model end: \([0-9.]*\).*/\1/')
    [ -z "$ME" ] && ME=$STOP
    MAIN_LINE=$(grep "count=" "$1" | sed -n 2p)
    echo "===== count =====" >> "$1"
    echo "target: ${HEAT_SECS} s" >> "$1"
    if [ -n "$MAIN_LINE" ]; then
        echo "done: $(echo "$MAIN_LINE" | sed 's/.*\(count=[0-9]*\).*/\1/') (도구가 찍은 값)" >> "$1"
    else
        echo "stopped early: 도구가 본 실행 결과를 찍기 전에 끊김" >> "$1"
    fi
    awk -v ms="$MODEL_START" -v me="$ME" '
    BEGIN { printf "model start: %.2f s, model end: %.2f s, model time: %.2f s (부팅 후 경과 시간 기준)\n", ms, me, me - ms }' >> "$1"
    echo "battery temp at end: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$1"
}

# 끝날 때와 중간에 끊길 때 모두 이 함수가 한 번만 돎
finish() {
    [ $FINISHED = 1 ] && return
    FINISHED=1
    STOP=$(now)

    # 1) 모델 종료
    STOPPED=0
    for p in $MODEL1_PID $MODEL2_PID; do
        kill -0 $p 2>/dev/null && { kill $p 2>/dev/null; STOPPED=1; }
    done
    if [ $STOPPED = 1 ]; then
        pkill -f tf_benchmark_tool 2>/dev/null
        echo "model stopped early"
    fi

    # 2) 스킨템프 복구
    for z in $SKIN_ZONES; do
        echo enabled > $z/mode 2>/dev/null
        echo "skin zone restored: $z -> $(cat $z/mode 2>/dev/null)"
    done

    # 3) 돈 횟수와 시간 기록
    for f in "$MODEL1_FILE" "$MODEL2_FILE"; do
        write_count "$f"
        [ -f "$f" ] && { echo "$f"; sed -n '/===== count =====/,$p' "$f"; }
    done

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

# 3) 설정 기록 (모델 파일마다)
for k in 1 2; do
    if [ $k = 1 ]; then f=$MODEL1_FILE; m=$CORE_MASK1; else f=$MODEL2_FILE; m=$CORE_MASK2; fi
    echo "===== setting =====" > "$f"
    echo "model=$MODEL_PATH (CPU, delegate 없음)" >> "$f"
    echo "core_mask=${m} logger_mask=${LOGGER_MASK} heat_secs=${HEAT_SECS} skin_off=${SKIN_OFF}" >> "$f"
    echo "pair: model1 core_mask=${CORE_MASK1}, model2 core_mask=${CORE_MASK2}" >> "$f"
    echo "skin zones disabled:${SKIN_ZONES:- none}" >> "$f"
    echo "logger start: ${LOGGER_START} s (부팅 후 경과 시간)" >> "$f"
    echo "battery temp at start: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$f"
    echo "===== main run =====" >> "$f"
done

# 4) 모델 2개 동시 실행 (HEAT_SECS초 동안 쉬지 않고)
MODEL_START=$(now)
run_model $CORE_MASK1 "$MODEL1_FILE" &
MODEL1_PID=$!
run_model $CORE_MASK2 "$MODEL2_FILE" &
MODEL2_PID=$!
wait $MODEL1_PID
wait $MODEL2_PID
MODEL1_PID=""
MODEL2_PID=""
