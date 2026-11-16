#!/system/bin/sh
# 안뜨거운 모델(80% 부하율) 1개를 cpu1 -> cpu5 순서로 하나씩 오래 돌려서 코어별로 DTM이 걸리는지 확인
export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 모델 설정 (zip 압축을 푼 실제 .tflite 파일 이름에 맞춰 수정)
MODEL_PATH=/data/local/tmp/SM/model/inception_v3.tflite
MODEL_TAG=$(basename "$MODEL_PATH" .tflite)   # 파일 이름에서 자동으로: inception_v3

# 실험 설정
CORES="1 2 3 4 5"     # 돌릴 코어 순서 (로거는 cpu0)
DUTY=80               # 부하율(%)
RUN_SECS=1800         # 코어 하나당 본 실험 시간(초), 30분
CALIB_SECS=15         # 추론 1회 시간 측정용 짧은 실행(초)
RUN_DELAY_FIX=""      # 직접 지정하려면 초 단위로 입력(예: 0.005). 비워 두면 코어마다 자동 계산
PRE_TEMP_SECS=5       # 온도를 찍고 모델 시작까지 대기(초)

# 냉각 조건: 다음에 돌릴 코어 온도를 COOL_INTERVAL초마다 재서
#           COOL_MIN~COOL_MAX도가 COOL_COUNT번 연속 나오면 시작
COOL_MIN=32
COOL_MAX=34
COOL_INTERVAL=5
COOL_COUNT=2

# 코어별 thermal zone type 이름 ("코어:type" 형식, 공백으로 구분). 냉각 판단에 필요해서 꼭 채워야 함
# 예: CORE_TEMP_TYPES="1:typeA 2:typeB 3:typeC 4:typeD 5:typeE"
# 못 찾으면 cpu 관련 zone 목록을 찍고 멈춤 -> 목록에서 골라 넣으면 됨
CORE_TEMP_TYPES=""

cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output

if [ ! -f "$MODEL_PATH" ]; then
    echo "model not found: $MODEL_PATH"
    exit 1
fi

LOGGER_PID=""
MODEL_PID=""
SKIN_ZONES=""

# 코어 하나가 끝날 때, 또는 중간에 끊길 때(Ctrl+C, adb 끊김) 모델, 스킨템프, 로거를 원래대로 돌려놓음
stop_run() {
    [ -n "$MODEL_PID" ] && kill -0 $MODEL_PID 2>/dev/null && kill $MODEL_PID 2>/dev/null
    MODEL_PID=""
    for z in $SKIN_ZONES; do
        echo enabled > $z/mode 2>/dev/null
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

# $1 = cpu 번호 -> 그 코어의 thermal zone 경로 (못 찾으면 빈 값)
core_zone() {
    TT=""
    for p in $CORE_TEMP_TYPES; do
        [ "${p%%:*}" = "$1" ] && TT="${p#*:}"
    done
    [ -z "$TT" ] && return
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat $z/type 2>/dev/null)" = "$TT" ] && echo $z && return
    done
}

# $1 = thermal zone 경로 -> 온도(도, 소수 1자리)
zone_temp() {
    awk -v v="$(cat $1/temp 2>/dev/null)" 'BEGIN { printf "%.1f", v / 1000 }'
}

# 시작 전에 모든 코어의 zone을 확인. 하나라도 없으면 cpu zone 목록을 찍고 멈춤
for c in $CORES; do
    if [ -z "$(core_zone $c)" ]; then
        echo "core${c} thermal zone not found -> CORE_TEMP_TYPES 확인. cpu zone 목록:"
        for z in /sys/class/thermal/thermal_zone*; do
            t=$(cat $z/type 2>/dev/null)
            echo "$t" | grep -qi "cpu" && echo "  $z  type=$t  $(zone_temp $z) C"
        done
        exit 1
    fi
done

# 냉각: $1 = cpu 번호, $2 = 어떤 냉각인지(출력용)
# COOL_INTERVAL초마다 온도를 재서 COOL_MIN~COOL_MAX가 COOL_COUNT번 연속이면 끝
wait_cool() {
    Z=$(core_zone $1)
    OK=0
    ELAPSED=0
    echo "cooldown start (core$1, $2): target ${COOL_MIN}~${COOL_MAX} C x ${COOL_COUNT}"
    while [ $OK -lt $COOL_COUNT ]; do
        T=$(zone_temp $Z)
        if awk -v t="$T" -v lo="$COOL_MIN" -v hi="$COOL_MAX" 'BEGIN { exit !(t >= lo && t <= hi) }'; then
            OK=$((OK + 1))
            NOTE="in range"
        else
            OK=0
            if awk -v t="$T" -v lo="$COOL_MIN" 'BEGIN { exit !(t < lo) }'; then
                NOTE="below ${COOL_MIN} C"
            else
                NOTE="above ${COOL_MAX} C"
            fi
        fi
        echo "cooldown core$1: ${ELAPSED}s, ${T} C, ${NOTE} (${OK}/${COOL_COUNT})"
        [ $OK -ge $COOL_COUNT ] && break
        sleep $COOL_INTERVAL
        ELAPSED=$((ELAPSED + COOL_INTERVAL))
    done
    echo "cooldown done (core$1, $2): ${ELAPSED}s"
    COOL_LOG="${COOL_LOG} $2=${ELAPSED}s"
}

# $1 = 실행 시간(초), $2 = 출력 파일, $3 = run_delay(초, 0이면 sleep 없음)
run_model() {
taskset $CORE_MASK /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
--graph="$MODEL_PATH" \
--num_runs=2147483647 \
--min_secs=$1 \
--max_secs=$1 \
--run_delay=$3 \
--num_threads=1 \
--warmup_runs=10 \
--warmup_min_secs=1 \
--require_full_delegation=true \
--external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
--external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1' \
>> "$2" 2>&1
}

# 코어 하나 실험: $1 = cpu 번호
run_one_core() {
    CORE_NUM=$1
    CORE_MASK=$(printf "%02x" $((1 << CORE_NUM)))   # 1 -> 02, 4 -> 10, 5 -> 20
    OUTPUT_NAME=./output/${MODEL_TAG}_cold${DUTY}_core${CORE_NUM}_$((RUN_SECS/60))min_$(date +%Y%m%d_%H%M%S)
    OUTPUT_FILE=$OUTPUT_NAME.txt
    MODEL_FILE="${OUTPUT_NAME}_model1.txt"   # 모델 쪽 기록은 이 파일 하나에 모음
    RUN_DELAY=$RUN_DELAY_FIX
    AVG_US=""
    COOL_LOG=""
    echo "========== core${CORE_NUM} (mask ${CORE_MASK}) =========="

    # 1) run_delay 계산: 냉각 -> sleep 없이 짧게 돌려서 추론 1회 평균 시간을 잼
    #    부하율 = 추론 / (추론 + sleep) 이므로 sleep = 추론 x (100 - DUTY) / DUTY
    if [ -z "$RUN_DELAY" ]; then
        wait_cool $CORE_NUM before_calib
        echo "calibration: ${CALIB_SECS}s"
        echo "===== calibration (${CALIB_SECS}s, no sleep) =====" >> "$MODEL_FILE"
        run_model $CALIB_SECS "$MODEL_FILE" 0
        AVG_US=$(grep "Inference (avg)" "$MODEL_FILE" | tail -1 | sed 's/.*Inference (avg): *\([0-9.eE+-]*\).*/\1/')
        if [ -z "$AVG_US" ]; then
            echo "calibration failed: $MODEL_FILE 확인 -> core${CORE_NUM} 건너뜀"
            grep -iE "fail|error|abort" "$MODEL_FILE" | head -5
            return 1
        fi
        RUN_DELAY=$(awk -v a="$AVG_US" -v d="$DUTY" 'BEGIN { printf "%.6f", a * (100 - d) / d / 1000000 }')
        echo "inference avg: ${AVG_US} us -> run_delay: ${RUN_DELAY} s (duty ${DUTY}%)"
    fi

    # 2) 본 실험 전 냉각
    wait_cool $CORE_NUM before_main

    # 3) 로거 시작 (cpu0)
    taskset 01 /data/local/tmp/SM/logger/logger261104_v2 "$OUTPUT_NAME" &
    LOGGER_PID=$!
    sleep 1
    if ! kill -0 $LOGGER_PID 2>/dev/null; then
        echo "logger failed to start -> 중단"
        exit 1
    fi

    # 4) 스킨템프 끄기
    SKIN_PATTERN="skin|user_|front_temp|back_temp|quiet"
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat $z/type 2>/dev/null)
        if echo "$t" | grep -qE "$SKIN_PATTERN"; then
            echo disabled > $z/mode 2>/dev/null && SKIN_ZONES="$SKIN_ZONES $z"
            echo "skin zone: $z ($t) -> $(cat $z/mode 2>/dev/null)"
        fi
    done

    # 5) 모델 시작 5초 전 코어 온도 기록
    PRE_TEMP=$(zone_temp $(core_zone $CORE_NUM))
    echo "pre temp (core${CORE_NUM}, -${PRE_TEMP_SECS}s): ${PRE_TEMP} C"
    sleep $PRE_TEMP_SECS

    # 6) 본 실험: 80% 부하율로 1개만 실행
    echo "run: ${RUN_SECS}s, mask ${CORE_MASK}, run_delay ${RUN_DELAY}s"
    echo "===== setting =====" >> "$MODEL_FILE"
    echo "duty=${DUTY} run_delay=${RUN_DELAY} avg_us=${AVG_US:-manual} mask=${CORE_MASK}" >> "$MODEL_FILE"
    echo "cooldown:${COOL_LOG}" >> "$MODEL_FILE"
    echo "pre_temp(-${PRE_TEMP_SECS}s)=${PRE_TEMP}C" >> "$MODEL_FILE"
    echo "===== main run (${RUN_SECS}s) =====" >> "$MODEL_FILE"
    run_model $RUN_SECS "$MODEL_FILE" $RUN_DELAY &
    MODEL_PID=$!
    wait $MODEL_PID
    MODEL_PID=""

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
}

# 코어 순서대로 하나씩 실행 (코어마다 시작 전에 냉각 조건을 확인함)
for c in $CORES; do
    run_one_core $c
done

chmod -R 777 ./output
echo "all done: cores ${CORES}"