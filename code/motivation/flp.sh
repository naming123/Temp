#!/system/bin/sh
# 뜨거운 모델(100%, sleep 없음) 1개를 BIG 코어(cpu7)에서 돌리고, 로거도 cpu7에서 돌림
# MID 코어(cpu2-6)는 비워 두고, 로거의 MID2_temp ~ MID6_temp로 누가 BIG 열을 먼저, 많이 받는지 봄
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델 설정
MODEL_PATH=/data/local/tmp/SM/model/inception_v3.tflite
MODEL_TAG=$(basename "$MODEL_PATH" .tflite)   # 파일 이름에서 자동으로: inception_v3

# 실험 설정
CORE_MASK=80         # 모델 코어: 80 = cpu7 (BIG)
LOGGER_MASK=80        # 로거 코어: 80 = cpu7 (BIG)
RUN_SECS=1800         # 본 실험 시간(초), 30분
USE_NPU=0             # 0 = CPU에서 직접 계산(BIG을 데움), 1 = HTP(NPU) delegate 사용

cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output

# CORE_MASK(16진수)에서 cpu 번호를 뽑음 (80 -> 7)
MASK_DEC=$((16#$CORE_MASK))
CORE_NUM=""
i=0
while [ $MASK_DEC -gt 0 ]; do
    [ $((MASK_DEC & 1)) = 1 ] && CORE_NUM="${CORE_NUM}${i}"
    MASK_DEC=$((MASK_DEC >> 1))
    i=$((i + 1))
done
OUTPUT_NAME=./output/flpMID2_${MODEL_TAG}_core${CORE_NUM}_$((RUN_SECS/60))min_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL_FILE="${OUTPUT_NAME}_model1.txt"

if [ ! -f "$MODEL_PATH" ]; then
    echo "model not found: $MODEL_PATH"
    exit 1
fi

LOGGER_PID=""
MODEL_PID=""
SKIN_ZONES=""
CLEANED=0

# 중간에 끊겨도(Ctrl+C, adb 끊김) 모델, 스킨템프, 로거를 원래대로 돌려놓음
cleanup() {
    [ "$CLEANED" = 1 ] && return
    CLEANED=1
    [ -n "$MODEL_PID" ] && kill -0 $MODEL_PID 2>/dev/null && kill $MODEL_PID 2>/dev/null
    for z in $SKIN_ZONES; do
        echo enabled > $z/mode 2>/dev/null
        echo "skin zone restored: $z -> $(cat $z/mode 2>/dev/null)"
    done
    if [ -n "$LOGGER_PID" ] && kill -0 $LOGGER_PID 2>/dev/null; then
        kill $LOGGER_PID
        wait $LOGGER_PID 2>/dev/null
    fi
}
trap 'cleanup; exit 130' INT TERM HUP
trap cleanup EXIT

[ "$(id -u)" = 0 ] || echo "warning: not root -> skin zone mode 변경이 실패할 수 있음"

# 1) 로거 시작
taskset $LOGGER_MASK /data/local/tmp/SM/logger/logger261110_100ms "$OUTPUT_NAME" &
LOGGER_PID=$!
sleep 1
if ! kill -0 $LOGGER_PID 2>/dev/null; then
    echo "logger failed to start"
    exit 1
fi

# 2) 스킨템프 끄기
SKIN_PATTERN="skin|user_|front_temp|back_temp|quiet"
for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat $z/type 2>/dev/null)
    if echo "$t" | grep -qE "$SKIN_PATTERN"; then
        echo disabled > $z/mode 2>/dev/null && SKIN_ZONES="$SKIN_ZONES $z"
        echo "skin zone: $z ($t) -> $(cat $z/mode 2>/dev/null)"
    fi
done

# 3) 본 실험: 100%(sleep 없음)로 RUN_SECS초 실행
if [ "$USE_NPU" = 1 ]; then
    DELEGATE_OPTS="--require_full_delegation=true \
--external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
--external_delegate_options=backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1"
else
    DELEGATE_OPTS=""
fi

echo "run: ${RUN_SECS}s, model mask ${CORE_MASK}, logger mask ${LOGGER_MASK}, use_npu ${USE_NPU}"
echo "===== setting =====" >> "$MODEL_FILE"
echo "duty=100 mask=${CORE_MASK} logger_mask=${LOGGER_MASK} use_npu=${USE_NPU} run_secs=${RUN_SECS}" >> "$MODEL_FILE"
echo "===== main run (${RUN_SECS}s) =====" >> "$MODEL_FILE"
taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
--graph="$MODEL_PATH" \
--num_runs=2147483647 \
--min_secs=$RUN_SECS \
--max_secs=$RUN_SECS \
--num_threads=1 \
--warmup_runs=10 \
--warmup_min_secs=1 \
$DELEGATE_OPTS \
>> "$MODEL_FILE" 2>&1 &
MODEL_PID=$!
wait $MODEL_PID
MODEL_PID=""

# 로거가 끝까지 살아 있었는지 확인
kill -0 $LOGGER_PID 2>/dev/null || echo "warning: logger exited before benchmark finished"

# 스킨템프 복구 + 로거 종료
cleanup

# 모델 실행 결과 간단 확인
if grep -qiE "fail|error|abort" "$MODEL_FILE"; then
    echo "check model log: $MODEL_FILE"
    grep -iE "fail|error|abort" "$MODEL_FILE" | head -5
fi

# 저장 확인
if [ -s "$OUTPUT_FILE" ]; then
    chmod -R 777 ./output
    echo "saved: $OUTPUT_FILE"
else
    echo "save failed: $OUTPUT_FILE"
fi