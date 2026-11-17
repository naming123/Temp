#!/system/bin/sh
# 모델 1개를 cpu2에서 정해진 횟수(NUM_RUNS)만큼 돌리고, 로거는 cpu6에서 돌림
# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델 종료, 로거 종료, 돈 횟수 추정, 저장을 모두 함
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델과 실험 설정
MODEL_PATH=/data/local/tmp/SM/model/inception_v3.tflite
MODEL_TAG=$(basename "$MODEL_PATH" .tflite)   # 파일 이름에서 자동으로: inception_v3
CORE_MASK=04          # 모델 코어: 04 = cpu2
LOGGER_MASK=04        # 로거 코어: 04 = cpu4
NUM_RUNS=1000000      # 본 실행 횟수
MAX_SECS=3600         # 안전용 상한(초). 느려져도 이 시간이 넘으면 끝남
AVG_US=771.5          # 추론 1회 시간(us). 끊겼을 때 돈 횟수 추정에만 씀 (이전 실행 워밍업 avg)

# 결과 폴더와 파일 이름
cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output
# CORE_MASK(16진수)에서 cpu 번호를 뽑음 (04 -> 2)
MASK_DEC=$((16#$CORE_MASK))
CORE_NUM=""
i=0
while [ $MASK_DEC -gt 0 ]; do
    [ $((MASK_DEC & 1)) = 1 ] && CORE_NUM="${CORE_NUM}${i}"
    MASK_DEC=$((MASK_DEC >> 1))
    i=$((i + 1))
done
OUTPUT_NAME=./output/${MODEL_TAG}_core${CORE_NUM}_${NUM_RUNS}iter_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL_FILE="${OUTPUT_NAME}_model1.txt"

# 부팅 후 경과 시간(초, 소수 둘째 자리)
now() { cut -d' ' -f1 /proc/uptime; }

LOGGER_PID=""
MODEL1_PID=""
MODEL_START=""
FINISHED=0

# 끝날 때와 중간에 끊길 때 모두 이 함수가 한 번만 돎
finish() {
    [ $FINISHED = 1 ] && return
    FINISHED=1
    STOP=$(now)

    # 1) 모델 종료
    if [ -n "$MODEL1_PID" ] && kill -0 $MODEL1_PID 2>/dev/null; then
        kill $MODEL1_PID 2>/dev/null
        pkill -f tf_benchmark_tool 2>/dev/null
        echo "model stopped early"
    fi

    # 2) 돈 횟수 기록: 끝까지 돌면 도구가 찍은 count, 끊기면 돈 시간 / 1회 시간으로 추정
    if [ -n "$MODEL_START" ] && [ -f "$MODEL_FILE" ]; then
        MAIN_LINE=$(grep "count=" "$MODEL_FILE" | sed -n 2p)
        WARM_LINE=$(grep -m1 "count=" "$MODEL_FILE")
        INIT_MS=$(grep -m1 "Initialized session in" "$MODEL_FILE" | sed 's/.*in \([0-9.]*\)ms.*/\1/')
        echo "===== count =====" >> "$MODEL_FILE"
        echo "target: ${NUM_RUNS} runs" >> "$MODEL_FILE"
        if [ -n "$MAIN_LINE" ]; then
            echo "done: $(echo "$MAIN_LINE" | sed 's/.*\(count=[0-9]*\).*/\1/') (도구가 찍은 값)" >> "$MODEL_FILE"
        elif [ -n "$INIT_MS" ] && [ -n "$WARM_LINE" ]; then
            WARM_N=$(echo "$WARM_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')
            WARM_AVG=$(echo "$WARM_LINE" | sed 's/.*avg=\([0-9.]*\).*/\1/')
            awk -v ms="$MODEL_START" -v st="$STOP" -v init="$INIT_MS" -v wn="$WARM_N" -v wa="$WARM_AVG" -v a="$AVG_US" '
            BEGIN {
                run_s = (st - ms) - init / 1000 - wn * wa / 1e6
                if (run_s < 0) run_s = 0
                printf "stopped early: about %d runs (= %.2f s / %s us, 추정)\n", run_s * 1e6 / a, run_s, a
            }' >> "$MODEL_FILE"
        else
            echo "stopped early: 본 실행 시작 전에 끊김" >> "$MODEL_FILE"
        fi
        sed -n '/===== count =====/,$p' "$MODEL_FILE"
    fi

    # 3) 로거 종료
    if [ -n "$LOGGER_PID" ] && kill -0 $LOGGER_PID 2>/dev/null; then
        kill $LOGGER_PID
        wait $LOGGER_PID 2>/dev/null
    elif [ -n "$LOGGER_PID" ]; then
        echo "warning: logger exited before benchmark finished"
    fi

    # 4) 저장 확인
    chmod -R 777 ./output
    if [ -s "$OUTPUT_FILE" ]; then
        echo "saved: $OUTPUT_FILE"
    else
        echo "save failed: $OUTPUT_FILE"
    fi
}
trap 'finish; exit 130' INT TERM HUP
trap finish EXIT

# 로거 시작
taskset $LOGGER_MASK /data/local/tmp/SM/logger/logger261117_100ms_v2 "$OUTPUT_NAME" &
LOGGER_PID=$!
sleep 1

if ! kill -0 $LOGGER_PID 2>/dev/null; then
    echo "logger failed to start"
    LOGGER_PID=""
    exit 1
fi

# 모델 1개 실행 (NUM_RUNS번 돌면 끝, 시간 조건 없음)
MODEL_START=$(now)
taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
--graph="$MODEL_PATH" \
--num_runs=$NUM_RUNS \
--min_secs=0 \
--max_secs=$MAX_SECS \
--num_threads=1 \
--warmup_runs=10 \
--warmup_min_secs=1 \
--require_full_delegation=true \
--external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
--external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1' \
> "$MODEL_FILE" 2>&1 &
MODEL1_PID=$!
wait $MODEL1_PID