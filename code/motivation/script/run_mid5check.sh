#!/bin/bash
# 실험2 CPU2+CPU3 다시 실행 + MID5 클러스터 주파수 확인 대표 shell (컴퓨터에서 실행)
#   지금 도는 run_step3b.sh가 5번째 실행(2회차 B)에 들어가면 run_step3b.sh를 끄고 시작
#   mid5check.sh를 기기에 올리고 (step2_core23.sh는 기기에 있던 것을 그대로 씀), 적힌 차례대로 하나마다 아래를 반복
#   SCRIPTS 항목은 "shell:인자" 또는 "shell" (default = 기본 설정, min_max = policy5 min을 max로 올림)
#   재부팅 -> 부팅 완료 -> 냉각 폴링(cool.sh) -> 실험 shell 실행(nohup) -> 끝날 때까지 확인
# 실험 shell은 기기에서 nohup으로 돌아서, USB가 잠깐 끊겨도 그 실행은 계속 돎 (다시 붙으면 이어서 확인)
# 기기 명령은 모두 su -c로 root 권한으로 돌림 (처음 한 번 기기 화면에서 shell의 su 허용 필요)
# 냉각 시간: 앞 실험이 끝난 시각 ~ 냉각 조건을 만족한 시각 (재부팅 시간 포함)을 로그에 남김
PATH="$(cd "$(dirname "$0")" && pwd):$PATH"   # 이 폴더의 adb.exe를 먼저 씀
DEV_DIR=/data/local/tmp/SM/code/motivation/script
SCRIPTS="step2_core23.sh mid5check.sh:default mid5check.sh:min_max"
PUSH_LIST="mid5check.sh"   # 기기에 올릴 파일
COOL_LOG=/data/local/tmp/SM/code/output/cooling_$(date +%Y%m%d_%H%M%S).txt   # 기기 안
PC_LOG=./run_mid5check_$(date +%Y%m%d_%H%M%S).txt                                # 컴퓨터

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$PC_LOG"; }
dev() { adb shell "$1" | tr -d '\r'; }
devsu() { adb shell "su -c '$1'" | tr -d '\r'; }   # root로 실행

wait_boot() {
    adb wait-for-device
    until [ "$(dev 'getprop sys.boot_completed')" = 1 ]; do sleep 5; done
}

# 0) run_step3b.sh가 5번째 실행(2회차 B)에 들어가면 run_step3b.sh를 끄고 시작
#    4번째 실행(2회차 A)까지는 끝까지 돌고 저장된 뒤라 결과는 남음 (로그에 "===== 5:"가 찍히는 건 4번째가 "end"를 찍은 다음)
#    돌고 있는지는 Git Bash 프로세스 목록(/proc/*/cmdline)에서 run_step3b.sh를 찾아서 봄 (다른 Git Bash 창에서 돌려도 보임)
step3b_pids() {
    for f in /proc/[0-9]*/cmdline; do
        tr '\0' ' ' < "$f" 2>/dev/null | grep -q 'run_step3b[.]sh' && { p=${f#/proc/}; echo ${p%/cmdline}; }
    done
}
log "waiting for run_step3b.sh 5번째 실행"
while :; do
    S_LOG=$(ls -t ./run_step3b_*.txt 2>/dev/null | head -1)
    if [ -n "$S_LOG" ] && grep -q "===== 5:" "$S_LOG"; then
        for p in $(step3b_pids); do kill $p 2>/dev/null; done
        sleep 5
        log "run_step3b.sh 끔 (5번째 실행 시작 전): $S_LOG"
        break
    fi
    if [ -z "$(step3b_pids)" ]; then
        log "run_step3b.sh가 5번째 실행 전에 끝남 (${S_LOG:-로그 없음}) -> 시작 안 함"
        exit 1
    fi
    sleep 20
done

# 0-1) 실험 shell을 기기에 올림 (이 폴더에 있는 SCRIPTS 파일)
# MSYS_NO_PATHCONV=1: Git Bash가 /data/... 경로를 Windows 경로로 바꾸지 않게 함
adb wait-for-device
for s in $PUSH_LIST; do
    [ -f "./$s" ] || { log "script not found on PC: $s -> 멈춤"; exit 1; }
done
if ! MSYS_NO_PATHCONV=1 adb push $PUSH_LIST "$DEV_DIR/" >> "$PC_LOG" 2>&1; then
    log "adb push failed -> 멈춤"
    exit 1
fi
log "pushed: $PUSH_LIST"

prev_end=""
k=0
for item in $SCRIPTS; do
    k=$((k + 1))
    s=${item%%:*}; a=${item#*:}; [ "$a" = "$item" ] && a=""
    tag=${s%.sh}${a:+_$a}   # 냉각 로그와 console 파일 이름용
    log "===== $k: $s $a ====="

    # 1) 재부팅
    t_reboot=$(date +%s)
    adb reboot
    wait_boot
    [ "$(devsu 'id -u')" = 0 ] || log "warning: su 실패 -> skin zone mode 변경이 실패할 수 있음"
    log "boot completed: $(( $(date +%s) - t_reboot )) s"
    devsu "mkdir -p /data/local/tmp/SM/code/output"

    # 2) 냉각 폴링
    COOL_OUT=$(devsu "cd $DEV_DIR && sh ./cool.sh $tag $COOL_LOG")
    echo "$COOL_OUT"
    if ! echo "$COOL_OUT" | grep -q "cooling wait on device"; then
        log "cooling failed -> 멈춤"
        exit 1
    fi
    t_cool=$(date +%s)
    [ -n "$prev_end" ] && log "cooling total (앞 실험 끝 ~ 냉각 완료, 재부팅 포함): $(( t_cool - prev_end )) s"

    # 3) 실험 shell 실행
    pid=$(devsu "cd $DEV_DIR && nohup sh ./$s $a > ./${tag}_console.txt 2>&1 < /dev/null & echo \$!")
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