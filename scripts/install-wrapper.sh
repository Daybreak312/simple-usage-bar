#!/bin/bash
# usagebar-claude 래퍼 + 관측기 설치 (make-app.sh --install이 호출).
#   scripts/install-wrapper.sh <usagebar 실행 파일>
#
# 앱 번들 밖 고정 경로 ~/Library/Application Support/UsageBar/bin/ (0700)에 둔다.
# make-app.sh가 번들을 rm -rf 후 복사하므로, 번들 안 경로를 부르면 업데이트
# 순간의 claude 호출이 깨진다. 같은 디렉터리 임시 파일 + mv(rename)라 실행 중인
# 호출은 옛 파일을, 새 호출은 새 파일을 본다 — 빈 순간이 없다.
#
# 시험용 env: USAGEBAR_SUPPORT_BIN(설치 디렉터리), USAGEBAR_LINK_DIRS(링크 후보, 공백 구분)
set -euo pipefail
cd "$(dirname "$0")/.."

OBSERVER_SRC="${1:?usagebar 실행 파일 경로}"
SUPPORT_BIN="${USAGEBAR_SUPPORT_BIN:-$HOME/Library/Application Support/UsageBar/bin}"
LINK_DIRS="${USAGEBAR_LINK_DIRS:-/opt/homebrew/bin /usr/local/bin}"

mkdir -p "$SUPPORT_BIN"
chmod 700 "$SUPPORT_BIN"

install_atomic() { # install_atomic <원본> <설치 이름>
    local tmp
    tmp="$(mktemp "$SUPPORT_BIN/.$2.XXXXXX")"
    if ! { cp "$1" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$SUPPORT_BIN/$2"; }; then
        rm -f "$tmp"
        return 1
    fi
}
# 관측기 먼저 — 새 래퍼가 옛 관측기를 만나는 순간은 있어도 그 반대는 없게.
install_atomic "$OBSERVER_SRC" usagebar
install_atomic scripts/usagebar-claude usagebar-claude
echo "래퍼 설치: $SUPPORT_BIN/usagebar-claude (관측기 $SUPPORT_BIN/usagebar)"

# usagebar 링크와 같은 규칙: 첫 번째 쓰기 가능한 디렉터리. 대상이 고정 경로라 이미
# 맞으면 건드리지 않는다 (ln -sf는 지웠다 다시 만들어 그 찰나의 호출이 실패할 수 있다).
for dir in $LINK_DIRS; do
    if [[ -d "$dir" && -w "$dir" ]]; then
        if [[ "$(readlink "$dir/usagebar-claude" 2>/dev/null)" != "$SUPPORT_BIN/usagebar-claude" ]]; then
            ln -sfn "$SUPPORT_BIN/usagebar-claude" "$dir/usagebar-claude"
        fi
        echo "래퍼 링크: $dir/usagebar-claude"
        break
    fi
done
