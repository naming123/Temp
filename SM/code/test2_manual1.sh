export QAIRT_HOME=/data/local/tmp/SM/lib/qairt
export LD_LIBRARY_PATH=${QAIRT_HOME}/aarch64-android:${LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=${QAIRT_HOME}/hexagon-v75/unsigned

# 결과 폴더와 파일 이름
cd /data/local/tmp/SM/code || exit 1
mkdir -p ./output
OUTPUT_NAME=./output/$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE=$OUTPUT_NAME.txt

# 로거 시작
taskset 01 /data/local/tmp/SM/logger/logger261104 "$OUTPUT_NAME" &
LOGGER_PID=$!
sleep 1

if ! kill -0 $LOGGER_PID 2>/dev/null; then
    echo "logger failed to start"
    exit 1
fi

taskset 10 /data/local/tmp/SM/lib/tf_benchmark_tool/tf_benchmark_tool \
--graph=/data/local/tmp/SM/model/inception_v3.tflite \
--num_runs=10000000000 \
--min_secs=60 \
--max_secs=60 \
--num_threads=1 \
--warmup_runs=10 \
--warmup_min_secs=1 \
--require_full_delegation=true \
--external_delegate_path=/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnTFLiteDelegate.so \
--external_delegate_options='backend_type:htp;library_path:/data/local/tmp/SM/lib/qairt/aarch64-android/libQnnHtp.so;skel_library_dir:/data/local/tmp/SM/lib/qairt/hexagon-v75/unsigned;htp_precision:0;htp_performance_mode:1'

# 로거 종료
if kill -0 $LOGGER_PID 2>/dev/null; then
    kill $LOGGER_PID
    wait $LOGGER_PID 2>/dev/null
else
    echo "warning: logger exited before benchmark finished"
fi

# 저장 확인
if [ -s "$OUTPUT_FILE" ]; then
    chmod -R 777 ./output
    echo "saved: $OUTPUT_FILE"
else
    echo "save failed: $OUTPUT_FILE"
fi