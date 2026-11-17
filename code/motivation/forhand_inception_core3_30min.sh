#!/system/bin/sh
# 안뜨거운 모델(80% 부하율) 1개를 코어 1개에서 돌려서 실행시간 측정
# 코어는 아래 CORE만 바꿔서 손으로 하나씩 돌림. 코어마다 같은 조건으로 비교하려면 ITERS와 RUN_DELAY_FIX를 같은 값으로 고정
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델 설정 (zip 압축을 푼 실제 .tflite 파일 이름에 맞춰 수정)
MODEL_PATH=/data/local/tmp/SM/model/inception_v3.tflite
MODEL_TAG=$(basename "$MODEL_PATH" .tflite)   # 파일 이름에서 자동으로: inception_v3

# 실험 설정
CORE=5                # 돌릴 코어 (cpu 번호는 0부터). MID는 2~6. 로거는 cpu0
DUTY=80               # 부하율(%), 추론 / (추론 + sleep)의 시간 비율
ITERS=""              # 본 실험 iter 수. 비워 두면 이번 측정값으로 RUN_SECS에 맞춰 정함. 다른 코어와 같게 하려면 첫 코어 결과의 값을 넣을 것
RUN_SECS=1800         # ITERS를 비웠을 때 iter 수를 정하는 기준 시간(초), 30분
CALIB_SECS=15         # 추론 1회 시간 측정용 짧은 실행(초)
RUN_DELAY_FIX=""      # 초 단위(예: 0.005). 비워 두면 이번 측정값으로 자동 계산. 다른 코어와 같게 하려면 첫 코어 결과의 값을 넣을 것

cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output

if [ ! -f "$MODEL_PATH" ]; then
    echo "model not found: $MODEL_PATH"
    exit 1
fi

LOGGER_PID=""
MODEL_PID=""
SKIN_ZONES=""

# 끝날 때, 또는 중간에 끊길 때(Ctrl+C, adb 끊김) 모델, 스킨템프, 로거를 원래대로 돌려놓음
stop_run() {
    if [ -n "$MODEL_PID" ] && kill -0 $MODEL_PID 2>/dev/null; then
        kill $MODEL_PID 2>/dev/null
        # 함수를 &로 돌리면 $MODEL_PID가 서브셸일 수 있어서 벤치마크 프로세스도 직접 종료
        pkill -f tf_benchmark_tool 2>/dev/null
    fi
    MODEL_PID=""
    for z in $SKIN_ZONES; do
        { echo enabled > $z/mode; } 2>/dev/null
        echo "skin zone restored: $z -> $(cat $z/mode 2>/dev/null)"
    done
    SKIN_ZONES=""
    if [ -n "$LOGGER_PID" ] && kill -0 $LOGGER_PID 2>/dev/null; then
        kill $LOGGER_PID
        wait $LOGGER_PID 2>/dev/null
    fi
    LOGGER_PID=""
}
trap 'stop_run; exit 130' INT TERM HUP
trap stop_run EXIT

[ "$(id -u)" = 0 ] || echo "warning: not root -> skin zone mode 변경이 실패할 수 있음"

# $1 = num_runs, $2 = min_secs, $3 = max_secs, $4 = 출력 파일, $5 = run_delay(초, 0이면 sleep 없음)
run_model() {
taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
--graph="$MODEL_PATH" \
--num_runs=$1 \
--min_secs=$2 \
--max_secs=$3 \
--run_delay=$5 \
--num_threads=1 \
--warmup_runs=10 \
--warmup_min_secs=1 \
--require_full_delegation=true \
--external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
--external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1' \
>> "$4" 2>&1
}

# $1 = 모델 파일에서 마지막 "Inference (avg)" 값(us), 없거나 숫자가 아니면 빈 값
last_avg_us() {
    V=$(grep "Inference (avg)" "$1" | tail -1 | sed 's/.*Inference (avg): *\([0-9.eE+-]*\).*/\1/')
    case "$V" in
        ''|*[!0-9.eE+-]*) echo "" ;;
        *) echo "$V" ;;
    esac
}

CORE_NUM=$CORE
CORE_MASK=$(printf "%02x" $((1 << CORE_NUM)))   # 2 -> 04, 4 -> 10, 6 -> 40
RUN_DELAY=$RUN_DELAY_FIX
AVG_US=""
CALIB_TMP=./output/.calib_core${CORE_NUM}.txt
rm -f "$CALIB_TMP"
echo "========== core${CORE_NUM} (mask ${CORE_MASK}) =========="

# 1) run_delay 계산: sleep 없이 짧게 돌려서 추론 1회 평균 시간을 잼
#    부하율 = 추론 / (추론 + sleep) 이므로 sleep = 추론 x (100 - DUTY) / DUTY
if [ -z "$RUN_DELAY" ]; then
    echo "calibration: ${CALIB_SECS}s"
    run_model 2147483647 $CALIB_SECS $CALIB_SECS "$CALIB_TMP" 0
    AVG_US=$(last_avg_us "$CALIB_TMP")
    if [ -z "$AVG_US" ]; then
        echo "calibration failed: $CALIB_TMP 확인 (Inference (avg) 줄이 없거나 숫자가 아님)"
        grep -iE "fail|error|abort" "$CALIB_TMP" | head -5
        exit 1
    fi
    RUN_DELAY=$(awk -v a="$AVG_US" -v d="$DUTY" 'BEGIN { printf "%.6f", a * (100 - d) / d / 1000000 }')
    echo "inference avg: ${AVG_US} us -> run_delay: ${RUN_DELAY} s (duty ${DUTY}%)"
fi

# iter 수: 비어 있으면 이번 측정값으로 정함 (추론 + sleep 한 번 = 추론 x 100 / DUTY)
if [ -z "$ITERS" ]; then
    if [ -z "$AVG_US" ]; then
        echo "ITERS가 비어 있고 측정값도 없음 -> ITERS를 직접 넣어야 함"
        exit 1
    fi
    ITERS=$(awk -v s="$RUN_SECS" -v a="$AVG_US" -v d="$DUTY" 'BEGIN { printf "%d", s * 1000000 * d / 100 / a }')
    echo "ITERS set: ${ITERS} (about ${RUN_SECS}s)"
fi

OUTPUT_NAME=./output/${MODEL_TAG}_cold${DUTY}_core${CORE_NUM}_${ITERS}iter_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL_FILE="${OUTPUT_NAME}_model1.txt"   # 모델 쪽 기록은 이 파일 하나에 모음
if [ -f "$CALIB_TMP" ]; then
    echo "===== calibration (${CALIB_SECS}s, no sleep) =====" >> "$MODEL_FILE"
    cat "$CALIB_TMP" >> "$MODEL_FILE"
    rm -f "$CALIB_TMP"
fi

# 2) 로거 시작 (cpu0)
taskset 01 /data/local/tmp/SM/logger/logger261104_v2 "$OUTPUT_NAME" &
LOGGER_PID=$!
sleep 1
if ! kill -0 $LOGGER_PID 2>/dev/null; then
    echo "logger failed to start -> 중단"
    exit 1
fi

# 3) 스킨템프 끄기
SKIN_PATTERN="skin|user_|front_temp|back_temp|quiet"
for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat $z/type 2>/dev/null)
    if echo "$t" | grep -qE "$SKIN_PATTERN"; then
        { echo disabled > $z/mode; } 2>/dev/null && SKIN_ZONES="$SKIN_ZONES $z"
        echo "skin zone: $z ($t) -> $(cat $z/mode 2>/dev/null)"
    fi
done

# 4) 본 실험: 80% 부하율로 1개만, ITERS번 실행 (시간 제한은 하루)
echo "run: ${ITERS} iter, mask ${CORE_MASK}, run_delay ${RUN_DELAY}s"
echo "===== setting =====" >> "$MODEL_FILE"
echo "duty=${DUTY} run_delay=${RUN_DELAY} avg_us=${AVG_US:-manual} mask=${CORE_MASK} iters=${ITERS}" >> "$MODEL_FILE"
echo "===== main run (${ITERS} iter) =====" >> "$MODEL_FILE"
RUN_START=$(date +%s)
run_model $ITERS 0 86400 "$MODEL_FILE" $RUN_DELAY &
MODEL_PID=$!
wait $MODEL_PID
MODEL_PID=""
RUN_TIME=$(( $(date +%s) - RUN_START ))
echo "main run done: ${ITERS} iter, ${RUN_TIME}s ($((RUN_TIME / 60))m $((RUN_TIME % 60))s)"

# 본 실험 추론 평균과 실제 부하율 (wall_time에는 모델 로드, 워밍업, sleep이 포함되므로 코어 비교는 inference_avg_us로)
MAIN_AVG_US=$(last_avg_us "$MODEL_FILE")
ACTUAL_DUTY="unknown"
if [ -n "$MAIN_AVG_US" ]; then
    ACTUAL_DUTY=$(awk -v a="$MAIN_AVG_US" -v r="$RUN_DELAY" 'BEGIN { printf "%.1f", a * 100 / (a + r * 1000000) }')
fi
echo "===== result =====" >> "$MODEL_FILE"
echo "iters=${ITERS} wall_time=${RUN_TIME}s inference_avg_us=${MAIN_AVG_US:-unknown} actual_duty=${ACTUAL_DUTY}%" >> "$MODEL_FILE"
echo "inference_avg_us=${MAIN_AVG_US:-unknown}, actual duty=${ACTUAL_DUTY}%"
echo "다음 코어에 같은 조건으로 돌리려면: ITERS=${ITERS}  RUN_DELAY_FIX=${RUN_DELAY}"

# 로거가 끝까지 살아 있었는지 확인
kill -0 $LOGGER_PID 2>/dev/null || echo "warning: logger exited before benchmark finished"

# 스킨템프 복구 + 로거 종료
stop_run

# 모델 실행 결과 간단 확인
if grep -qiE "fail|error|abort" "$MODEL_FILE"; then
    echo "check model log: $MODEL_FILE"
    grep -iE "fail|error|abort" "$MODEL_FILE" | head -5
fi

# 저장 확인
if [ -s "$OUTPUT_FILE" ]; then
    echo "saved: $OUTPUT_FILE"
else
    echo "save failed: $OUTPUT_FILE"
fi

chmod -R 777 ./output
echo "all done: core ${CORE_NUM}"