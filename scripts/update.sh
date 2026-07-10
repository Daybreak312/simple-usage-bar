#!/bin/bash
# Self-update: pull origin/main → rebuild → reinstall to /Applications → relaunch.
# Designed to be launched detached from the running app (the app is killed and
# reopened at the very end, so a failure anywhere leaves the old app running).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/usagebar-update.log
exec >>"$LOG" 2>&1

notify() {
    /usr/bin/osascript -e "display notification \"$1\" with title \"UsageBar\"" >/dev/null 2>&1 || true
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
# this point never touches the running app.
pkill -f 'UsageBar.app/Contents/MacOS/UsageBar' 2>/dev/null || true
pkill -f '\.build/(debug|release)/usagebar$' 2>/dev/null || true
sleep 1
open /Applications/UsageBar.app
notify "업데이트 완료 — $(git rev-parse --short HEAD)"
echo "완료: $(git rev-parse --short HEAD)"
