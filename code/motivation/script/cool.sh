#!/system/bin/sh
# 냉각 폴링 (기기에서 실행): 시작 온도 범위에 들어올 때까지 기다림
# 사용: sh cool.sh 다음실험이름 로그파일
# 조건: cpu2~6 zone은 모두 CPU_MAX 이하, cpu7 zone은 CPU7_MAX 이하, NPU HMX zone은 HMX_MAX 이하인 상태가
#       POLL_SECS초 간격으로 STABLE_N번 연속이면 끝(종료 코드 0). WAIT_MAX초를 넘으면 종료 코드 1
LABEL=$1
LOG=$2

# 냉각 조건 (밀리도 단위, 33500 = 33.5도)
CPU_MAX=36000    # cpu2~6: 지금까지 시작 온도 31.74~33.38도를 모두 포함
CPU7_MAX=37000   # cpu7: 쉬고 있을 때도 33.8~35.3도(ambi)라 따로 둠
HMX_MAX=36000    # NPU HMX: 지금까지 시작 온도 33.52~34.52도
POLL_SECS=10
STABLE_N=6       # 60초 연속
WAIT_MAX=3600    # 최대 대기(초)

# zone 찾기: cpu2~4 = cpu-2-*, cpu5~6 = cpu-1-0-*, cpu-1-1-*, cpu7 = cpu-1-2-*, NPU HMX = type에 nsphmx
CPU_ZONES=""
CPU7_ZONES=""
HMX_ZONES=""
for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat $z/type 2>/dev/null)
    case $t in
        cpu-2-*|cpu-1-0-*|cpu-1-1-*) CPU_ZONES="$CPU_ZONES $z" ;;
        cpu-1-2-*) CPU7_ZONES="$CPU7_ZONES $z" ;;
        *nsphmx*) HMX_ZONES="$HMX_ZONES $z" ;;
    esac
done
if [ -z "$CPU_ZONES" ] || [ -z "$CPU7_ZONES" ] || [ -z "$HMX_ZONES" ]; then
    echo "zone not found (cpu:${CPU_ZONES:- none} / cpu7:${CPU7_ZONES:- none} / hmx:${HMX_ZONES:- none})" | tee -a "$LOG"
    exit 1
fi

# 모든 zone이 상한 이하이면 0
check_cool() {
    for z in $CPU_ZONES; do [ $(cat $z/temp) -le $CPU_MAX ] || return 1; done
    for z in $CPU7_ZONES; do [ $(cat $z/temp) -le $CPU7_MAX ] || return 1; done
    for z in $HMX_ZONES; do [ $(cat $z/temp) -le $HMX_MAX ] || return 1; done
    return 0
}

echo "cooling for $LABEL: start $(date +%H:%M:%S)" | tee -a "$LOG"
w0=$(date +%s); n=0
while :; do
    if check_cool; then n=$((n + 1)); else n=0; fi
    [ $n -ge $STABLE_N ] && break
    if [ $(( $(date +%s) - w0 )) -ge $WAIT_MAX ]; then
        echo "cooling timeout: ${WAIT_MAX} s" | tee -a "$LOG"
        exit 1
    fi
    sleep $POLL_SECS
done
echo "cooling wait on device: $(( $(date +%s) - w0 )) s" | tee -a "$LOG"
for z in $CPU_ZONES $CPU7_ZONES $HMX_ZONES; do echo "  start temp $(cat $z/type) $(cat $z/temp)"; done >> "$LOG"
exit 0
