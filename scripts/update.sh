#!/bin/bash
# Self-update: pull origin/main → rebuild → reinstall to /Applications → relaunch.
# git pull이 실행 중인 이 스크립트 파일 자체를 덮어쓸 수 있으므로, 먼저 /tmp로
# 복사해 그 사본을 실행한다 (스테이징). 실패 시 구동 중인 앱은 건드리지 않음.
set -euo pipefail

if [[ "${USAGEBAR_UPDATE_STAGED:-}" != "1" ]]; then
    REPO="$(cd "$(dirname "$0")/.." && pwd)"
    cp "$0" /tmp/usagebar-update-staged.sh
    USAGEBAR_UPDATE_STAGED=1 exec /bin/bash /tmp/usagebar-update-staged.sh "$REPO"
fi

REPO="${1:?repo path}"
LOG=/tmp/usagebar-update.log
exec >>"$LOG" 2>&1

APP_BIN="/Applications/SimpleUsageBar.app/Contents/MacOS/SimpleUsageBar"

notify() {
    # 앱 명의(아이콘 포함)로 네이티브 알림. 앱이 아직 없으면 osascript 폴백.
    if [[ -x "$APP_BIN" ]]; then
        "$APP_BIN" notify "SimpleUsageBar" "$1" || true
    else
        /usr/bin/osascript -e "display notification \"$1\" with title \"SimpleUsageBar\"" >/dev/null 2>&1 || true
    fi
}

echo "=== update run $(date '+%F %T') repo=$REPO"
cd "$REPO"

git fetch --quiet origin main
if git merge-base --is-ancestor origin/main HEAD; then
    echo "이미 최신 (HEAD $(git rev-parse --short HEAD))"
else
    git pull --ff-only origin main || {
        notify "업데이트 실패: 로컬 변경과 충돌 (로그: $LOG)"
        echo "pull 실패 — 로컬 커밋/변경이 origin/main과 갈라짐"
        exit 1
    }
fi

./scripts/make-app.sh --install || {
    notify "업데이트 실패: 빌드 오류 (로그: $LOG)"
    exit 1
}

# Swap to the freshly installed bundle. Old instances die here; failure before
# this point never touches the running app. 패턴은 구명(UsageBar.app)도 포함.
pkill -f 'UsageBar.app/Contents/MacOS' 2>/dev/null || true
pkill -f '\.build/(debug|release)/usagebar$' 2>/dev/null || true
sleep 1
open /Applications/SimpleUsageBar.app
sleep 2
notify "업데이트 완료 — $(git rev-parse --short HEAD)"
echo "완료: $(git rev-parse --short HEAD)"
