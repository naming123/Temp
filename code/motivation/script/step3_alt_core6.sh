#!/system/bin/sh
# 3단계 번갈아 (CPU 뜨거운 코어와 NPU의 거리): 코어 하나(CORE_MASK)에서 두 모델을 약 1분씩 번갈아 돌림
#   CPU가 뜨거운 조각: inception_v3 (CPU 계산, delegate 없음, 100% sleep 없음) CPU_RUNS회
#   NPU가 뜨거운 조각: real_esrgan_x4plus (NPU 전체 위임) NPU_RUNS회
#   inception 조각 -> real 조각을 한 번씩 돌리고, 시작부터 TARGET_SECS(900초)가 지나면 새 조각을 시작하지 않음
# 배치마다 CORE_MASK만 다름 (04 = cpu2 NPU에 가까움, 40 = cpu6 NPU에서 멂)
# 조각 횟수: 1분 / 1회 평균을 맨 앞자리만 남기고 버림 (예: 2,849 -> 2,000)
#   inception: 1단계 heatmap 모델 파일에서 같은 코어의 Inference (avg)로 자동 계산
#   real: 21,060 µs(real 단독 스킨 off 워밍업 avg) 기준 2,849 -> 2,000
# real은 조각마다 새로 띄워서 초기화(이전 로그 약 35초)가 조각마다 들어감. 초기화 시간은 본 실행 시간에 들어가지 않음
# 조각마다 시작, 끝, 횟수, 1회 평균을 _chunks.txt에 한 줄씩 남김 (나중에 더해서 씀)
# 로거는 모델과 같은 코어에서 돌림
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
CORE_MASK=40          # 두 모델 코어: 04 = cpu2, 40 = cpu6
LOGGER_MASK=$CORE_MASK  # 로거 코어 = 모델 코어
TARGET_SECS=900       # 이 시간이 지나면 새 조각을 시작하지 않음
CHUNK_SECS=60         # 조각 목표 길이(초). 횟수는 맨 앞자리만 남기고 버림
NPU_AVG_US=21060      # real 1회 평균(µs): real 단독 스킨 off 워밍업 avg
MAX_SECS=600          # 조각 하나의 안전 상한(초)
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
OUTPUT_NAME=./output/step3alt_${SKIN_TAG}_${MODEL1_TAG}_${MODEL2_TAG}_core${CORE_NUM}_$((TARGET_SECS / 60))min_$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt
MODEL1_FILE="${OUTPUT_NAME}_model1.txt"
MODEL2_FILE="${OUTPUT_NAME}_model2.txt"
CHUNK_FILE="${OUTPUT_NAME}_chunks.txt"
TMP_FILE="${OUTPUT_NAME}_tmp.txt"   # 조각 하나의 도구 출력을 잠깐 받는 파일. 끝나면 지움

for p in "$MODEL1_PATH" "$MODEL2_PATH"; do
    if [ ! -f "$p" ]; then
        echo "model not found: $p"
        exit 1
    fi
done

# 1분 / 1회 평균을 맨 앞자리만 남기고 버림 (2849 -> 2000, 1234 -> 1000, 456 -> 400)
msb_runs() {
    awk -v a="$1" -v t=$CHUNK_SECS 'BEGIN { n = int(t * 1000000 / a); d = 10 ^ (length(n "") - 1); printf "%d", int(n / d) * d }'
}

# inception 횟수: 1단계 heatmap 모델 파일(같은 코어, 스킨 off, 가장 최근)의 Inference (avg)로 계산
HEATMAP_FILE=$(ls -t ./output/heatmap_skinoff_${MODEL1_TAG}_hot100_core${CORE_NUM}_*_model1.txt 2>/dev/null | head -1)
CPU_AVG_US=""
[ -n "$HEATMAP_FILE" ] && CPU_AVG_US=$(grep "Inference (avg)" "$HEATMAP_FILE" | tail -1 | sed 's/.*Inference (avg): \([0-9.e+]*\).*/\1/')
if [ -z "$CPU_AVG_US" ]; then
    echo "heatmap avg not found (core${CORE_NUM}): ${HEATMAP_FILE:-파일 없음}"
    exit 1
fi
CPU_RUNS=$(msb_runs $CPU_AVG_US)
NPU_RUNS=$(msb_runs $NPU_AVG_US)

# 부팅 후 경과 시간(초, 소수 둘째 자리)
now() { cut -d' ' -f1 /proc/uptime; }

LOGGER_PID=""
LOGGER_START=""
MODEL_PID=""
MODEL_START=""
SKIN_ZONES=""
FINISHED=0
N_CHUNK=0

# 조각 하나: 모델 하나를 횟수 기준으로 돌림. 도구 출력은 TMP_FILE로 받음
# 사용: run_chunk cpu|npu
run_chunk() {
    if [ "$1" = npu ]; then
        taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
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
        > "$TMP_FILE" 2>&1
    else
        taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
        --graph="$MODEL1_PATH" \
        --num_runs=$CPU_RUNS \
        --min_secs=0 \
        --max_secs=$MAX_SECS \
        --num_threads=1 \
        --warmup_runs=10 \
        --warmup_min_secs=1 \
        > "$TMP_FILE" 2>&1
    fi
}

# 조각 결과 기록: 도구 출력을 모델 파일에 붙이고, _chunks.txt에 한 줄 남김
# 사용: save_chunk cpu|npu 시작시각 끝시각
save_chunk() {
    if [ "$1" = npu ]; then f=$MODEL2_FILE; tag=$MODEL2_TAG; r=$NPU_RUNS; else f=$MODEL1_FILE; tag=$MODEL1_TAG; r=$CPU_RUNS; fi
    echo "----- chunk $N_CHUNK ($1) start $2 s -----" >> "$f"
    [ -f "$TMP_FILE" ] && cat "$TMP_FILE" >> "$f"
    echo "chunk end: $3 s" >> "$f"
    MAIN_LINE=$(grep "count=" "$TMP_FILE" 2>/dev/null | sed -n 2p)
    if [ -n "$MAIN_LINE" ]; then
        c=$(echo "$MAIN_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')
        a=$(echo "$MAIN_LINE" | sed 's/.* avg=\([0-9.e+]*\).*/\1/')
        awk -v n=$N_CHUNK -v k=$1 -v t=$tag -v s=$2 -v e=$3 -v r=$r -v c=$c -v a=$a 'BEGIN {
            printf "%d\t%s\t%s\t%.2f\t%.2f\t%d\t%d\t%s\t%.2f\n", n, k, t, s, e, r, c, a, c * a / 1000000 }' >> "$CHUNK_FILE"
    else
        awk -v n=$N_CHUNK -v k=$1 -v t=$tag -v s=$2 -v e=$3 -v r=$r 'BEGIN {
            printf "%d\t%s\t%s\t%.2f\t%.2f\t%d\t-\t-\t-\tstopped early\n", n, k, t, s, e, r }' >> "$CHUNK_FILE"
    fi
    rm -f "$TMP_FILE"
}

# 끝날 때와 중간에 끊길 때 모두 이 함수가 한 번만 돎
finish() {
    [ $FINISHED = 1 ] && return
    FINISHED=1
    STOP=$(now)

    # 1) 모델 종료 (도는 조각이 있으면 끊고, 그 조각도 기록)
    if [ -n "$MODEL_PID" ] && kill -0 $MODEL_PID 2>/dev/null; then
        kill $MODEL_PID 2>/dev/null
        pkill -f tf_benchmark_tool 2>/dev/null
        echo "model stopped early"
        save_chunk $CHUNK_KIND $CHUNK_START $STOP
    fi

    # 2) 스킨템프 복구
    for z in $SKIN_ZONES; do
        echo enabled > $z/mode 2>/dev/null
        echo "skin zone restored: $z -> $(cat $z/mode 2>/dev/null)"
    done

    # 3) 돈 횟수와 시간 기록 (조각 합계)
    if [ -n "$MODEL_START" ] && [ -f "$CHUNK_FILE" ]; then
        for k in cpu npu; do
            if [ $k = npu ]; then f=$MODEL2_FILE; else f=$MODEL1_FILE; fi
            echo "===== count =====" >> "$f"
            awk -F'\t' -v k=$k 'NR > 1 && $2 == k {
                n++; if ($7 != "-") { c += $7; s += $9 } else bad++ }
                END { printf "chunks: %d (끊긴 조각 %d), count 합: %d, 본 실행 시간 합 (count x avg): %.2f s\n", n, bad, c, s }' "$CHUNK_FILE" >> "$f"
            awk -v ms="$MODEL_START" -v me="$STOP" '
            BEGIN { printf "first chunk start: %.2f s, last chunk end: %.2f s, total: %.2f s (부팅 후 경과 시간 기준)\n", ms, me, me - ms }' >> "$f"
            echo "battery temp at end: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$f"
            echo "$f"; sed -n '/===== count =====/,$p' "$f"
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

# 3) 설정 기록
echo "===== setting =====" > "$MODEL1_FILE"
echo "model=$MODEL1_PATH (CPU, delegate 없음)" >> "$MODEL1_FILE"
echo "core_mask=${CORE_MASK} logger_mask=${LOGGER_MASK} chunk_runs=${CPU_RUNS} max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$MODEL1_FILE"
echo "chunk_runs 근거: ${HEATMAP_FILE} Inference (avg) ${CPU_AVG_US} us, ${CHUNK_SECS} s를 맨 앞자리만 남기고 버림" >> "$MODEL1_FILE"
echo "===== setting =====" > "$MODEL2_FILE"
echo "model=$MODEL2_PATH (NPU 전체 위임)" >> "$MODEL2_FILE"
echo "core_mask=${CORE_MASK} logger_mask=${LOGGER_MASK} chunk_runs=${NPU_RUNS} max_secs=${MAX_SECS} skin_off=${SKIN_OFF}" >> "$MODEL2_FILE"
echo "chunk_runs 근거: 1회 평균 ${NPU_AVG_US} us (real 단독 스킨 off 워밍업 avg), ${CHUNK_SECS} s를 맨 앞자리만 남기고 버림" >> "$MODEL2_FILE"
for f in "$MODEL1_FILE" "$MODEL2_FILE"; do
    echo "alternate: ${MODEL1_TAG} ${CPU_RUNS}회 -> ${MODEL2_TAG} ${NPU_RUNS}회 반복, ${TARGET_SECS} s가 지나면 새 조각 시작 안 함" >> "$f"
    echo "skin zones disabled:${SKIN_ZONES:- none}" >> "$f"
    echo "logger start: ${LOGGER_START} s (부팅 후 경과 시간)" >> "$f"
    echo "battery temp at start: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (0.1도 단위)" >> "$f"
    echo "===== main run =====" >> "$f"
done
printf "chunk\tkind\tmodel\tstart_s\tend_s\ttarget_runs\tcount\tavg_us\tmain_s(count x avg)\n" > "$CHUNK_FILE"

# 4) 번갈아 실행: inception 조각 -> real 조각, TARGET_SECS가 지나면 새 조각을 시작하지 않음
MODEL_START=$(now)
while :; do
    for CHUNK_KIND in cpu npu; do
        el=$(awk -v s="$MODEL_START" -v n="$(now)" 'BEGIN { printf "%d", n - s }')
        [ $el -ge $TARGET_SECS ] && break 2
        N_CHUNK=$((N_CHUNK + 1))
        CHUNK_START=$(now)
        run_chunk $CHUNK_KIND &
        MODEL_PID=$!
        wait $MODEL_PID
        MODEL_PID=""
        save_chunk $CHUNK_KIND $CHUNK_START $(now)
    done
done
