#!/bin/bash
# Self-update: pull origin/main → rebuild → reinstall to /Applications → relaunch.
# git pull이 실행 중인 이 스크립트 파일 자체를 덮어쓸 수 있으므로, 먼저 /tmp로
# 복사해 그 사본을 실행한다 (스테이징). 실패 시 구동 중인 앱은 건드리지 않음.
set -Eeuo pipefail

if [[ "${USAGEBAR_UPDATE_STAGED:-}" != "1" ]]; then
    REPO="$(cd "$(dirname "$0")/.." && pwd)"
    # 스테이징 경로는 실행마다 유니크 — 고정 경로를 공유하면 동시 실행이
    # 서로의 스크립트를 덮어써 실행 중인 bash가 엉뚱한 오프셋을 읽는다.
    STAGED="$(mktemp /tmp/usagebar-update-staged.XXXXXX)"
    cp "$0" "$STAGED"
    USAGEBAR_UPDATE_STAGED=1 USAGEBAR_STAGED_PATH="$STAGED" exec /bin/bash "$STAGED" "$REPO"
fi

REPO="${1:?repo path}"
LOG=/tmp/usagebar-update.log
exec >>"$LOG" 2>&1

# launchd 스폰은 PATH가 최소라 명시 고정 (swift/git/open/brew 링크 경로 포함).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 낡은 스테이징 파일 청소 (정상 실행은 2분 내 끝난다).
find /tmp -maxdepth 1 -name 'usagebar-update-staged.*' -mmin +60 -delete 2>/dev/null || true

# 과거 세대 좀비 업데이트 프로세스 정리 — App Nap에 얼었다가 한참 뒤
# 깨어나 재설치·재시작·완료 알림을 반복하는 개체들 (30분 이상 경과분만).
for pid in $(pgrep -f 'usagebar-update-staged' 2>/dev/null); do
    [[ "$pid" == "$$" ]] && continue
    etime_s=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' \
        | awk -F'[-:]' '{n=NF; if (n==1) {print int($1); next}; s=$n + $(n-1)*60; if (n>=3) s+=$(n-2)*3600; if (n>=4) s+=$(n-3)*86400; print int(s)}')
    if [[ -n "$etime_s" && "$etime_s" -gt 1800 ]]; then
        kill -9 "$pid" 2>/dev/null || true
        echo "$(date '+%F %T') 좀비 업데이트 프로세스 제거: pid=$pid (경과 ${etime_s}s)"
    fi
done

# 동시 실행 방지 락 — launchd 잡·수동 실행·CLI가 겹칠 수 있다.
LOCK=/tmp/usagebar-update.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then
        echo "$(date '+%F %T') 스테일 락(30분+) 무시하고 진행"
    else
        echo "$(date '+%F %T') 다른 업데이트 실행 중 — 이번 실행 종료"
        exit 0
    fi
fi
trap 'rmdir /tmp/usagebar-update.lock 2>/dev/null || true; rm -f "${USAGEBAR_STAGED_PATH:-}"' EXIT

# 앱이 읽는 상태 파일 — 알림 권한이 없어도 진행/결과가 UI에 보이게 한다.
STATUS_FILE="$HOME/Library/Application Support/UsageBar/update-status.json"
status() { # status <state> <detail>
    local detail
    detail=$(printf '%s' "$2" | tr -d '"\\' | head -c 120)
    printf '{"state":"%s","detail":"%s","commit":"%s","at":%s}' \
        "$1" "$detail" "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')" "$(date +%s)" \
        > "$STATUS_FILE" 2>/dev/null || true
}

APP_BIN="/Applications/SimpleUsageBar.app/Contents/MacOS/SimpleUsageBar"

notify() {
    # 앱 명의(아이콘 포함)로 네이티브 알림. 앱이 아직 없으면 osascript 폴백.
    if [[ -x "$APP_BIN" ]]; then
        "$APP_BIN" notify "SimpleUsageBar" "$1" || true
    else
        /usr/bin/osascript -e "display notification \"$1\" with title \"SimpleUsageBar\"" >/dev/null 2>&1 || true
    fi
}

# set -e로 조용히 죽는 단계(오프라인 fetch 등)도 반드시 알림을 남긴다 —
# 무음 실패는 앱을 "업데이트 중…"에 가둬놓는 원인이었다. || 핸들러가 있는
# 단계는 ERR 트랩을 타지 않으므로 개별 메시지가 그대로 우선한다.
trap 'CMD=$BASH_COMMAND; echo "ERR: $CMD"; status failed "$CMD"; notify "업데이트 실패: $CMD (로그: /tmp/usagebar-update.log)"' ERR

echo "=== update run $(date '+%F %T') repo=$REPO"
cd "$REPO"
status running "pull·빌드 진행 중"

git fetch --quiet origin main
PREV_HEAD="$(git rev-parse HEAD)"
if git merge-base --is-ancestor origin/main HEAD; then
    # 이미 최신이면 재빌드·재설치·재시작 전부 불필요 — 예전엔 여기서도
    # 통째로 재설치해 "같은 해시로 업데이트 완료" 알림이 반복됐다.
    echo "이미 최신 (HEAD $(git rev-parse --short HEAD)) — 재설치 생략"
    status success "이미 최신 — 변경 없음"
    exit 0
else
    git pull --ff-only origin main || {
        status failed "로컬 변경과 충돌 — 레포 정리 필요"
        notify "업데이트 실패: 로컬 변경과 충돌 (로그: $LOG)"
        echo "pull 실패 — 로컬 커밋/변경이 origin/main과 갈라짐"
        exit 1
    }
fi

./scripts/make-app.sh --install || {
    # pull만 앞서가면 다음 확인에서 "이미 최신"으로 보여 영영 재시도하지
    # 않는다 — 되돌려서 "업데이트 있음" 상태를 유지해 다음 주기에 재시도.
    git reset --hard "$PREV_HEAD" >/dev/null 2>&1 || true
    status failed "빌드 오류 — 다음 주기에 재시도"
    notify "업데이트 실패: 빌드 오류 (로그: $LOG)"
    echo "빌드 실패 — $PREV_HEAD 로 롤백"
    exit 1
}

# Swap to the freshly installed bundle. Old instances die here; failure before
# this point never touches the running app. 패턴은 구명(UsageBar.app)도 포함.
pkill -f 'UsageBar.app/Contents/MacOS' 2>/dev/null || true
pkill -f '\.build/(debug|release)/usagebar$' 2>/dev/null || true
sleep 1
open /Applications/SimpleUsageBar.app
sleep 2
status success "설치·재시작 완료"
notify "업데이트 완료 — $(git rev-parse --short HEAD)"
echo "완료: $(git rev-parse --short HEAD)"
