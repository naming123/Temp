#!/system/bin/sh
# 모델 2개(NPU, HTP delegate)를 동시에 돌림: model1은 cpu2에서 NUM_RUNS1회, model2는 cpu5에서 NUM_RUNS2회
# 로거는 두 모델 코어(cpu2, cpu5)에서 돌림
# 스킨템프는 끄고 돌린 뒤, 끝나거나 중간에 끊기면 다시 켬
# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델 종료, 스킨템프 복구, 돈 횟수 추정, 로거 종료, 저장을 모두 함
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델과 실험 설정
MODEL1_PATH=/data/local/tmp/SM/model/dump/inception_v3.tflite
MODEL2_PATH=/data/local/tmp/SM/model/real_esrgan_x4plus.tflite
MODEL1_TAG=$(basename "$MODEL1_PATH" .tflite)   # 파일 이름에서 자동으로
MODEL2_TAG=$(basename "$MODEL2_PATH" .tflite)
CORE_MASK1=10         # model1 코어: 04 = cpu2, 08 = cpu3, 10 = cpu4
CORE_MASK2=08         # model2 코어: 20 = cpu5, 40 = cpu6
LOGGER_MASK=01        # 로거 코어: lit0
NUM_RUNS1=1000000     # model1 본 실행 횟수
NUM_RUNS2=40000       # model2 본 실행 횟수
MAX_SECS=3600         # 안전용 상한(초). 느려져도 이 시간이 넘으면 끝남
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
CORE_NUM1=$(core_num $CORE_MASK1)
CORE_NUM2=$(core_num $CORE_MASK2)
OUTPUT_NAME=./output/skinoff_${MODEL1_TAG}_core${CORE_NUM1}_${NUM_RUNS1}iter_${MODEL2_TAG}_core${CORE_NUM2}_${NUM_RUNS2}iter_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL1_FILE="${OUTPUT_NAME}_model1.txt"
MODEL2_FILE="${OUTPUT_NAME}_model2.txt"

for p in "$MODEL1_PATH" "$MODEL2_PATH"; do
    if [ ! -f "$p" ]; then
        echo "model not found: $p"
        exit 1
    fi
done

# 부팅 후 경과 시간(초, 소수 둘째 자리)
now() { cut -d' ' -f1 /proc/uptime; }

LOGGER_PID=""
LOGGER_START=""
MODEL1_PID=""
MODEL2_PID=""
MODEL1_START=""
MODEL2_START=""
SKIN_ZONES=""
FINISHED=0

# 모델 1개를 정해진 횟수만큼 돌리고, 끝난 시각을 모델 파일에 남김
# 사용: run_model 코어mask 모델경로 횟수 모델파일
run_model() {
    taskset $1 /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$2" \
    --num_runs=$3 \
    --min_secs=0 \
    --max_secs=$MAX_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    --require_full_delegation=true \
    --external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
    --external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1' \
    >> "$4" 2>&1
    echo "model end: $(now) s" >> "$4"
}

# 모델이 끝난 시각: 끝까지 돌았으면 run_model이 남긴 값, 끊겼으면 STOP
get_end() {
    e=$(grep -m1 "^model end:" "$1" 2>/dev/null | sed 's/model end: \([0-9.]*\).*/\1/')
    [ -z "$e" ] && e=$STOP
    echo "$e"
}

# 돈 횟수와 시간 기록: 끝까지 돌면 도구가 찍은 count, 끊기면 돈 시간 / 워밍업 1회 평균으로 추정
# 사용: write_count 모델파일 시작시각 끝시각 목표횟수
write_count() {
    f=$1; ms=$2; me=$3; target=$4
    { [ -n "$ms" ] && [ -f "$f" ]; } || return
    MAIN_LINE=$(grep "count=" "$f" | sed -n 2p)
    WARM_LINE=$(grep -m1 "count=" "$f")
    INIT_MS=$(grep -m1 "Initialized session in" "$f" | sed 's/.*in \([0-9.]*\)ms.*/\1/')
    echo "===== count =====" >> "$f"
    echo "target: ${target} runs" >> "$f"
    if [ -n "$MAIN_LINE" ]; then
        echo "done: $(echo "$MAIN_LINE" | sed 's/.*\(count=[0-9]*\).*/\1/') (도구가 찍은 값)" >> "$f"
    elif [ -n "$INIT_MS" ] && [ -n "$WARM_LINE" ]; then
        WARM_N=$(echo "$WARM_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')
        WARM_AVG=$(echo "$WARM_LINE" | sed 's/.*avg=\([0-9.]*\).*/\1/')
        awk -v ms="$ms" -v st="$me" -v init="$INIT_MS" -v wn="$WARM_N" -v wa="$WARM_AVG" '
        BEGIN {
            run_s = (st - ms) - init / 1000 - wn * wa / 1e6
            if (run_s < 0) run_s = 0
            printf "stopped early: about %d runs (= %.2f s / %s us, 워밍업 avg로 추정)\n", run_s * 1e6 / wa, run_s, wa
        }' >> "$f"
    else
        echo "stopped early: 본 실행 시작 전에 끊김" >> "$f"
    fi
    awk -v ms="$ms" -v me="$me" -v fs="$FIRST_START" -v le="$LAST_END" '
    BEGIN {
        printf "model start: %.2f s, model end: %.2f s, model time: %.2f s (부팅 후 경과 시간 기준)\n", ms, me, me - ms
        printf "total time: %.2f s (첫 모델 시작 ~ 마지막 모델 끝)\n", le - fs
    }' >> "$f"
    echo "battery temp at end: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$f"
}

# 끝날 때와 중간에 끊길 때 모두 이 함수가 한 번만 돎
finish() {
    [ $FINISHED = 1 ] && return
    FINISHED=1
    STOP=$(now)

    # 1) 모델 종료
    STOPPED=0
    for p in $MODEL1_PID $MODEL2_PID; do
        if kill -0 $p 2>/dev/null; then
            kill $p 2>/dev/null
            STOPPED=1
        fi
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
    if [ -n "$MODEL1_START" ]; then
        END1=$(get_end "$MODEL1_FILE")
        END2=$STOP
        [ -n "$MODEL2_START" ] && END2=$(get_end "$MODEL2_FILE")
        FIRST_START=$MODEL1_START
        LAST_END=$(awk -v a="$END1" -v b="$END2" 'BEGIN { print (a > b) ? a : b }')
        write_count "$MODEL1_FILE" "$MODEL1_START" "$END1" "$NUM_RUNS1"
        write_count "$MODEL2_FILE" "$MODEL2_START" "$END2" "$NUM_RUNS2"
        for f in "$MODEL1_FILE" "$MODEL2_FILE"; do
            [ -f "$f" ] || continue
            echo "[$f]"
            sed -n '/===== count =====/,$p' "$f"
        done
    fi

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
# 사용: write_setting 모델파일 코어mask 횟수 모델경로
write_setting() {
    echo "===== setting =====" > "$1"
    echo "model=$4" >> "$1"
    echo "core_mask=$2 logger_mask=${LOGGER_MASK} num_runs=$3 max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$1"
    echo "skin zones disabled:${SKIN_ZONES:- none}" >> "$1"
    echo "logger start: ${LOGGER_START} s (부팅 후 경과 시간)" >> "$1"
    echo "battery temp at start: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$1"
    echo "===== main run =====" >> "$1"
}
write_setting "$MODEL1_FILE" "$CORE_MASK1" "$NUM_RUNS1" "$MODEL1_PATH"
write_setting "$MODEL2_FILE" "$CORE_MASK2" "$NUM_RUNS2" "$MODEL2_PATH"

# 4) 모델 2개 동시 실행 (각자 정해진 횟수를 돌면 끝, 시간 조건 없음)
MODEL1_START=$(now)
run_model $CORE_MASK1 "$MODEL1_PATH" $NUM_RUNS1 "$MODEL1_FILE" &
MODEL1_PID=$!
MODEL2_START=$(now)
run_model $CORE_MASK2 "$MODEL2_PATH" $NUM_RUNS2 "$MODEL2_FILE" &
MODEL2_PID=$!

wait $MODEL1_PID
MODEL1_PID=""
wait $MODEL2_PID
MODEL2_PID=""