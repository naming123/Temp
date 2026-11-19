#!/bin/bash
# 3단계 번갈아 대표 shell (컴퓨터에서 실행): run_all.sh와 run_step23.sh가 모두 끝나면(all done 두 번) SCRIPTS를 기기에 올리고, 차례로 하나마다 아래를 반복
#   재부팅 -> 부팅 완료 -> 냉각 폴링(cool.sh) -> 실험 shell 실행(nohup) -> 끝날 때까지 확인
# 실험 shell은 기기에서 nohup으로 돌아서, USB가 잠깐 끊겨도 그 실행은 계속 돎 (다시 붙으면 이어서 확인)
# 기기 명령은 모두 su -c로 root 권한으로 돌림 (처음 한 번 기기 화면에서 shell의 su 허용 필요)
# 냉각 시간: 앞 실험이 끝난 시각 ~ 냉각 조건을 만족한 시각 (재부팅 시간 포함)을 로그에 남김
PATH="$(cd "$(dirname "$0")" && pwd):$PATH"   # 이 폴더의 adb.exe를 먼저 씀
DEV_DIR=/data/local/tmp/SM/code/motivation/script
SCRIPTS="step3_alt_core2.sh step3_alt_core6.sh"
COOL_LOG=/data/local/tmp/SM/code/output/cooling_$(date +%Y%m%d_%H%M%S).txt   # 기기 안
PC_LOG=./run_step3alt_$(date +%Y%m%d_%H%M%S).txt                                 # 컴퓨터

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$PC_LOG"; }
dev() { adb shell "$1" | tr -d '\r'; }
devsu() { adb shell "su -c '$1'" | tr -d '\r'; }   # root로 실행

wait_boot() {
    adb wait-for-device
    until [ "$(dev 'getprop sys.boot_completed')" = 1 ]; do sleep 5; done
}

# 0) run_all.sh와 run_step23.sh가 모두 끝날 때까지 기다림 (all done이 두 번 찍혀야 시작)
#    매번 가장 최근 로그를 다시 찾음. run_step23 로그는 run_all 로그보다 나중에 생긴 것만 셈
#    둘 중 하나라도 멈춤이 찍히면 시작 안 함
log "waiting for run_all + run_step23 (all done x 2)"
while :; do
    A_LOG=$(ls -t ./run_all_*.txt 2>/dev/null | head -1)
    S_LOG=$(ls -t ./run_step23_*.txt 2>/dev/null | head -1)
    [ -n "$S_LOG" ] && [ -n "$A_LOG" ] && [ ! "$S_LOG" -nt "$A_LOG" ] && S_LOG=""
    for f in $A_LOG $S_LOG; do
        if grep -q "멈춤" "$f"; then
            log "$f 가 중간에 멈춤 -> step3alt도 시작 안 함"
            exit 1
        fi
    done
    n=0
    for f in $A_LOG $S_LOG; do grep -q "all done" "$f" && n=$((n + 1)); done
    [ $n -ge 2 ] && break
    sleep 60
done
log "all done x 2: $A_LOG, $S_LOG"

# 0-1) run_step23이 끝난 뒤 실험 shell을 기기에 올림 (이 폴더에 있는 SCRIPTS 파일)
# MSYS_NO_PATHCONV=1: Git Bash가 /data/... 경로를 Windows 경로로 바꾸지 않게 함
adb wait-for-device
for s in $SCRIPTS; do
    [ -f "./$s" ] || { log "script not found on PC: $s -> 멈춤"; exit 1; }
done
if ! MSYS_NO_PATHCONV=1 adb push $SCRIPTS "$DEV_DIR/" >> "$PC_LOG" 2>&1; then
    log "adb push failed -> 멈춤"
    exit 1
fi
log "pushed: $SCRIPTS"

prev_end=""
for s in $SCRIPTS; do
    log "===== $s ====="

    # 1) 재부팅
    t_reboot=$(date +%s)
    adb reboot
    wait_boot
    [ "$(devsu 'id -u')" = 0 ] || log "warning: su 실패 -> skin zone mode 변경이 실패할 수 있음"
    log "boot completed: $(( $(date +%s) - t_reboot )) s"
    devsu "mkdir -p /data/local/tmp/SM/code/output"

    # 2) 냉각 폴링
    COOL_OUT=$(devsu "cd $DEV_DIR && sh ./cool.sh $s $COOL_LOG")
    echo "$COOL_OUT"
    if ! echo "$COOL_OUT" | grep -q "cooling wait on device"; then
        log "cooling failed -> 멈춤"
        exit 1
    fi
    t_cool=$(date +%s)
    [ -n "$prev_end" ] && log "cooling total (앞 실험 끝 ~ 냉각 완료, 재부팅 포함): $(( t_cool - prev_end )) s"

    # 3) 실험 shell 실행
    pid=$(devsu "cd $DEV_DIR && nohup sh ./$s > ./${s%.sh}_console.txt 2>&1 < /dev/null & echo \$!")
    log "start: pid $pid"

    # 4) 끝날 때까지 확인 (USB가 끊기면 다시 붙을 때까지 기다렸다가 이어서 확인)
    while :; do
        sleep 30
        if [ "$(adb get-state 2>/dev/null)" != device ]; then
            adb wait-for-device
            continue
        fi
        [ "$(devsu "kill -0 $pid 2>/dev/null && echo run")" = run ] || break
    done
    prev_end=$(date +%s)
    log "end"
done
log "all done"