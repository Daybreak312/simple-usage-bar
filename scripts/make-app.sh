#!/bin/bash
# Build a release binary and wrap it into SimpleUsageBar.app (menu bar only).
# Usage: scripts/make-app.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/SimpleUsageBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/usagebar "$APP/Contents/MacOS/SimpleUsageBar"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# CFBundleIdentifier는 예전 그대로 둔다 — 바꾸면 알림 권한·defaults 도메인이
# 리셋되고 로그인 항목이 끊긴다. 사용자에게 보이는 이름만 SimpleUsageBar.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SimpleUsageBar</string>
    <key>CFBundleIdentifier</key><string>dev.daybreak.usagebar</string>
    <key>CFBundleName</key><string>SimpleUsageBar</string>
    <key>CFBundleDisplayName</key><string>SimpleUsageBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "생성됨: $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/SimpleUsageBar.app /Applications/UsageBar.app
    cp -R "$APP" /Applications/
    echo "설치됨: /Applications/SimpleUsageBar.app"
    echo "로그인 시 자동 시작: 시스템 설정 → 일반 → 로그인 항목에 SimpleUsageBar 추가"

    # 터미널용 CLI 링크 — 같은 바이너리가 인자에 따라 CLI로 동작한다.
    BIN=/Applications/SimpleUsageBar.app/Contents/MacOS/SimpleUsageBar
    for dir in /opt/homebrew/bin /usr/local/bin; do
        if [[ -d "$dir" && -w "$dir" ]]; then
            ln -sf "$BIN" "$dir/usagebar"
            echo "CLI 링크: $dir/usagebar"
            break
        fi
    done
fi
