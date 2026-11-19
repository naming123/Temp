#!/system/bin/sh
# 3단계 다시 (CPU 열이 NPU 모델에 주는 영향, MID2 클러스터만 사용)
#   model1: real_esrgan_x4plus (NPU 전체 위임) NPU_RUNS회. CPU 쪽 코어는 cpu3 고정 (cpu2와 cpu4 사이)
#   model2: inception_v3 (CPU 계산, delegate 없음, 100% sleep 없음)을 HEAT_MASK 코어에서 열원으로 돌림
#           real과 동시에 시작하고, real이 끝나면 같이 끔 (inception 횟수는 측정하지 않음)
# 조건마다 HEAT_MASK만 다름 (비움 = real 혼자, 04 = cpu2 NPU에 가까움, 10 = cpu4 같은 클러스터에서 가장 멂)
# 로거는 모델 코어에서 돌림 (LOGGER_MASK = CORE_MASK1 + HEAT_MASK)
# 스킨템프는 끄고 돌린 뒤, 끝나거나 중간에 끊기면 다시 켬
# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델 종료, 스킨템프 복구, 돈 횟수 기록, 로거 종료, 저장을 모두 함
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델과 실험 설정
MODEL1_PATH=/data/local/tmp/SM/model/real_esrgan_x4plus.tflite     # NPU 전체 위임 (측정 대상)
MODEL2_PATH=/data/local/tmp/SM/model/dump/inception_v3.tflite      # CPU 계산, 100% (열원)
MODEL1_TAG=$(basename "$MODEL1_PATH" .tflite)   # 파일 이름에서 자동으로
MODEL2_TAG=$(basename "$MODEL2_PATH" .tflite)
CORE_MASK1=08         # model1(real)의 CPU 쪽 코어, 고정: 08 = cpu3
HEAT_MASK=            # model2(inception) 코어: 비움 = 없음(real 혼자), 04 = cpu2, 10 = cpu4
TARGET_SECS=900       # 파일 이름의 시간 표기용 (step3과 같게)
NPU_RUNS=42000        # real 횟수: 지난 step3(1,082~1,169초)와 비교하려고 같게 둠
MAX_SECS=2400         # 안전 상한(초). real은 지난 step3에서 최대 1,228초
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
if [ -n "$HEAT_MASK" ]; then
    HEAT_NUM=$(core_num $HEAT_MASK)
    LOGGER_MASK=$(printf '%02X' $((16#$CORE_MASK1 | 16#$HEAT_MASK)))   # 로거 코어 = 두 모델 코어
else
    LOGGER_MASK=$CORE_MASK1   # 로거 코어 = real 코어
fi
SKIN_TAG=skinoff
[ "$SKIN_OFF" = 1 ] || SKIN_TAG=skinon
if [ -n "$HEAT_MASK" ]; then
    OUTPUT_NAME=./output/step3b_${SKIN_TAG}_${MODEL2_TAG}_hot100_core${HEAT_NUM}_${MODEL1_TAG}_npu_core${CORE_NUM1}_$((TARGET_SECS / 60))min_$(date +%Y%m%d_%H%M%S)
else
    OUTPUT_NAME=./output/step3b_${SKIN_TAG}_${MODEL1_TAG}_npu_core${CORE_NUM1}_alone_$((TARGET_SECS / 60))min_$(date +%Y%m%d_%H%M%S)
fi
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
MODEL_START=""
HEAT_END=""
SKIN_ZONES=""
FINISHED=0

# model1: real을 NPU 전체 위임으로 NPU_RUNS회 돌리고, 끝난 시각을 모델 파일에 남김
run_model1() {
    taskset $CORE_MASK1 /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$MODEL1_PATH" \
    --num_runs=$NPU_RUNS \
    --min_secs=0 \
    --max_secs=$MAX_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    --require_full_delegation=true \
    --external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
    --external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1' \
    >> "$MODEL1_FILE" 2>&1
    echo "model end: $(now) s" >> "$MODEL1_FILE"
}

# model2: inception을 CPU에서(delegate 없음) 쉬지 않고 돌림. real이 끝나면 밖에서 끔
run_model2() {
    exec taskset $HEAT_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$MODEL2_PATH" \
    --num_runs=100000000 \
    --min_secs=$MAX_SECS \
    --max_secs=$MAX_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    >> "$MODEL2_FILE" 2>&1
}

# inception 끄기 (real이 끝났을 때와 중간에 끊겼을 때)
stop_heat() {
    if [ -n "$MODEL2_PID" ] && kill -0 $MODEL2_PID 2>/dev/null; then
        kill $MODEL2_PID 2>/dev/null
        wait $MODEL2_PID 2>/dev/null
    fi
    MODEL2_PID=""
    [ -z "$HEAT_END" ] && HEAT_END=$(now)
}

# real의 돈 횟수와 시간 기록: 끝까지 돌면 도구가 찍은 count, 끊기면 본 실행 전에 끊겼다고 적음
write_count() {
    { [ -n "$MODEL_START" ] && [ -f "$MODEL1_FILE" ]; } || return
    ME=$(grep -m1 "^model end:" "$MODEL1_FILE" 2>/dev/null | sed 's/model end: \([0-9.]*\).*/\1/')
    [ -z "$ME" ] && ME=$STOP
    MAIN_LINE=$(grep "count=" "$MODEL1_FILE" | sed -n 2p)
    echo "===== count =====" >> "$MODEL1_FILE"
    echo "target: $NPU_RUNS runs" >> "$MODEL1_FILE"
    if [ -n "$MAIN_LINE" ]; then
        echo "done: $(echo "$MAIN_LINE" | sed 's/.*\(count=[0-9]*\).*/\1/') (도구가 찍은 값)" >> "$MODEL1_FILE"
    else
        echo "stopped early: 도구가 본 실행 결과를 찍기 전에 끊김" >> "$MODEL1_FILE"
    fi
    awk -v ms="$MODEL_START" -v me="$ME" '
    BEGIN { printf "model start: %.2f s, model end: %.2f s, model time: %.2f s (부팅 후 경과 시간 기준)\n", ms, me, me - ms }' >> "$MODEL1_FILE"
    echo "battery temp at end: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$MODEL1_FILE"
    # inception: 횟수는 측정하지 않고, 켜져 있던 시간만 남김
    if [ -n "$HEAT_MASK" ] && [ -f "$MODEL2_FILE" ]; then
        echo "===== count =====" >> "$MODEL2_FILE"
        echo "열원으로만 돌림: real이 끝나서 끔 (횟수는 측정하지 않음)" >> "$MODEL2_FILE"
        awk -v ms="$MODEL_START" -v me="${HEAT_END:-$STOP}" '
        BEGIN { printf "model start: %.2f s, model end: %.2f s, model time: %.2f s (부팅 후 경과 시간 기준)\n", ms, me, me - ms }' >> "$MODEL2_FILE"
    fi
}

# 끝날 때와 중간에 끊길 때 모두 이 함수가 한 번만 돎
finish() {
    [ $FINISHED = 1 ] && return
    FINISHED=1
    STOP=$(now)

    # 1) 모델 종료
    stop_heat
    if [ -n "$MODEL1_PID" ] && kill -0 $MODEL1_PID 2>/dev/null; then
        kill $MODEL1_PID 2>/dev/null
        pkill -f tf_benchmark_tool 2>/dev/null
        echo "model stopped early"
    fi

    # 2) 스킨템프 복구
    for z in $SKIN_ZONES; do
        echo enabled > $z/mode 2>/dev/null
        echo "skin zone restored: $z -> $(cat $z/mode 2>/dev/null)"
    done

    # 3) 돈 횟수와 시간 기록
    write_count
    for f in "$MODEL1_FILE" "$MODEL2_FILE"; do
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

# 3) 설정 기록
echo "===== setting =====" > "$MODEL1_FILE"
echo "model=$MODEL1_PATH (NPU 전체 위임)" >> "$MODEL1_FILE"
echo "core_mask=${CORE_MASK1} logger_mask=${LOGGER_MASK} num_runs=${NPU_RUNS} max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$MODEL1_FILE"
echo "heat: ${HEAT_MASK:+$MODEL2_TAG core_mask=$HEAT_MASK (CPU, 100%, real 끝날 때까지)}${HEAT_MASK:-없음 (real 혼자)}" >> "$MODEL1_FILE"
if [ -n "$HEAT_MASK" ]; then
    echo "===== setting =====" > "$MODEL2_FILE"
    echo "model=$MODEL2_PATH (CPU, delegate 없음, 열원)" >> "$MODEL2_FILE"
    echo "core_mask=${HEAT_MASK} logger_mask=${LOGGER_MASK} real이 끝날 때까지 (상한 ${MAX_SECS} s) skin_off=${SKIN_OFF}" >> "$MODEL2_FILE"
fi
for f in "$MODEL1_FILE" ${HEAT_MASK:+"$MODEL2_FILE"}; do
    echo "skin zones disabled:${SKIN_ZONES:- none}" >> "$f"
    echo "logger start: ${LOGGER_START} s (부팅 후 경과 시간)" >> "$f"
    echo "battery temp at start: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$f"
    echo "===== main run =====" >> "$f"
done

# 4) real과 inception을 동시에 시작, real이 끝나면 inception을 끔
MODEL_START=$(now)
if [ -n "$HEAT_MASK" ]; then
    run_model2 &
    MODEL2_PID=$!
fi
run_model1 &
MODEL1_PID=$!
wait $MODEL1_PID
MODEL1_PID=""
stop_heat
