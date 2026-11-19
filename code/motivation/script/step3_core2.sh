#!/system/bin/sh
# 3단계 (CPU 뜨거운 코어와 NPU의 거리): NPU 모델(real)은 고정하고, CPU 계산 모델을 100%(sleep 없음)로 CORE_MASK1 코어에 놓고 동시에 돌림
# 배치마다 CORE_MASK1만 다름 (04 = cpu2 NPU에 가까움, 40 = cpu6 NPU에서 멂)
# 두 모델 모두 횟수 기준. 횟수는 TARGET_SECS(900초)에 가깝게 잡음
#   CPU 모델: 1단계 heatmap 모델 파일에서 같은 코어의 Inference (avg)를 읽어 자동 계산
#   NPU 모델: NPU_RUNS 고정
# 로거는 두 모델 코어에서 돌림 (LOGGER_MASK = CORE_MASK1 + CORE_MASK2)
# 스킨템프는 끄고 돌린 뒤, 끝나거나 중간에 끊기면 다시 켬
# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델 종료, 스킨템프 복구, 돈 횟수 기록, 로거 종료, 저장을 모두 함
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델과 실험 설정
MODEL1_PATH=/data/local/tmp/SM/model/dump/inception_v3.tflite      # CPU 계산, 100%
MODEL2_PATH=/data/local/tmp/SM/model/real_esrgan_x4plus.tflite     # NPU 전체 위임
MODEL1_TAG=$(basename "$MODEL1_PATH" .tflite)   # 파일 이름에서 자동으로
MODEL2_TAG=$(basename "$MODEL2_PATH" .tflite)
CORE_MASK1=04         # model1(CPU) 코어: 04 = cpu2, 40 = cpu6
CORE_MASK2=20         # model2(NPU)의 CPU 쪽 코어, 고정: 20 = cpu5 (시나리오 1, 2와 같음)
CORE_MASK=$(printf '%02X' $((16#$CORE_MASK1 | 16#$CORE_MASK2)))   # 두 모델 코어 합
LOGGER_MASK=$CORE_MASK  # 로거 코어 = 두 모델 코어
TARGET_SECS=900       # 목표 실행 시간(초)
NPU_RUNS=42000        # real 횟수: real 단독 스킨 off 워밍업 avg 21,060 µs x 42,000 = 약 885초
MAX_SECS=1800         # 안전 상한(초)
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
SKIN_TAG=skinoff
[ "$SKIN_OFF" = 1 ] || SKIN_TAG=skinon
OUTPUT_NAME=./output/step3_${SKIN_TAG}_${MODEL1_TAG}_hot100_core${CORE_NUM1}_${MODEL2_TAG}_npu_core${CORE_NUM2}_$((TARGET_SECS / 60))min_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL1_FILE="${OUTPUT_NAME}_model1.txt"
MODEL2_FILE="${OUTPUT_NAME}_model2.txt"

for p in "$MODEL1_PATH" "$MODEL2_PATH"; do
    if [ ! -f "$p" ]; then
        echo "model not found: $p"
        exit 1
    fi
done

# CPU 모델 횟수: 1단계 heatmap 모델 파일(같은 코어, 스킨 off, 가장 최근)의 Inference (avg)로 계산
HEATMAP_FILE=$(ls -t ./output/heatmap_skinoff_${MODEL1_TAG}_hot100_core${CORE_NUM1}_*_model1.txt 2>/dev/null | head -1)
CPU_AVG_US=""
[ -n "$HEATMAP_FILE" ] && CPU_AVG_US=$(grep "Inference (avg)" "$HEATMAP_FILE" | tail -1 | sed 's/.*Inference (avg): \([0-9.e+]*\).*/\1/')
if [ -z "$CPU_AVG_US" ]; then
    echo "heatmap avg not found (core${CORE_NUM1}): ${HEATMAP_FILE:-파일 없음}"
    exit 1
fi
CPU_RUNS=$(awk -v a="$CPU_AVG_US" -v t=$TARGET_SECS 'BEGIN { printf "%d", t * 1000000 / a }')

# 부팅 후 경과 시간(초, 소수 둘째 자리)
now() { cut -d' ' -f1 /proc/uptime; }

LOGGER_PID=""
LOGGER_START=""
MODEL1_PID=""
MODEL2_PID=""
MODEL_START=""
SKIN_ZONES=""
FINISHED=0

# model1: CPU에서(delegate 없음) CPU_RUNS회 쉬지 않고 돌리고, 끝난 시각을 모델 파일에 남김
run_model1() {
    taskset $CORE_MASK1 /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$MODEL1_PATH" \
    --num_runs=$CPU_RUNS \
    --min_secs=0 \
    --max_secs=$MAX_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    >> "$MODEL1_FILE" 2>&1
    echo "model end: $(now) s" >> "$MODEL1_FILE"
}

# model2: NPU 전체 위임으로 NPU_RUNS회 돌리고, 끝난 시각을 모델 파일에 남김
run_model2() {
    taskset $CORE_MASK2 /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
    --graph="$MODEL2_PATH" \
    --num_runs=$NPU_RUNS \
    --min_secs=0 \
    --max_secs=$MAX_SECS \
    --num_threads=1 \
    --warmup_runs=10 \
    --warmup_min_secs=1 \
    --require_full_delegation=true \
    --external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
    --external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1' \
    >> "$MODEL2_FILE" 2>&1
    echo "model end: $(now) s" >> "$MODEL2_FILE"
}

# 돈 횟수와 시간 기록: 끝까지 돌면 도구가 찍은 count, 끊기면 본 실행 시작 전인지 후인지만 적음
# 사용: write_count 모델파일 목표횟수
write_count() {
    { [ -n "$MODEL_START" ] && [ -f "$1" ]; } || return
    ME=$(grep -m1 "^model end:" "$1" 2>/dev/null | sed 's/model end: \([0-9.]*\).*/\1/')
    [ -z "$ME" ] && ME=$STOP
    MAIN_LINE=$(grep "count=" "$1" | sed -n 2p)
    echo "===== count =====" >> "$1"
    echo "target: $2 runs" >> "$1"
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
    write_count "$MODEL1_FILE" $CPU_RUNS
    write_count "$MODEL2_FILE" $NPU_RUNS
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

# 3) 설정 기록 (모델 파일마다)
echo "===== setting =====" > "$MODEL1_FILE"
echo "model=$MODEL1_PATH (CPU, delegate 없음)" >> "$MODEL1_FILE"
echo "core_mask=${CORE_MASK1} logger_mask=${LOGGER_MASK} num_runs=${CPU_RUNS} max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$MODEL1_FILE"
echo "num_runs 근거: ${HEATMAP_FILE} Inference (avg) ${CPU_AVG_US} us, 목표 ${TARGET_SECS} s" >> "$MODEL1_FILE"
echo "===== setting =====" > "$MODEL2_FILE"
echo "model=$MODEL2_PATH (NPU 전체 위임)" >> "$MODEL2_FILE"
echo "core_mask=${CORE_MASK2} logger_mask=${LOGGER_MASK} num_runs=${NPU_RUNS} max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$MODEL2_FILE"
for f in "$MODEL1_FILE" "$MODEL2_FILE"; do
    echo "pair: model1 core_mask=${CORE_MASK1} (CPU), model2 core_mask=${CORE_MASK2} (NPU)" >> "$f"
    echo "skin zones disabled:${SKIN_ZONES:- none}" >> "$f"
    echo "logger start: ${LOGGER_START} s (부팅 후 경과 시간)" >> "$f"
    echo "battery temp at start: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$f"
    echo "===== main run =====" >> "$f"
done

# 4) 모델 2개 동시 실행
MODEL_START=$(now)
run_model1 &
MODEL1_PID=$!
run_model2 &
MODEL2_PID=$!
wait $MODEL1_PID
wait $MODEL2_PID
MODEL1_PID=""
MODEL2_PID=""
