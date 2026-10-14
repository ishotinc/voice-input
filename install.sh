#!/bin/bash
# ログイン時に常駐させる（launchd に登録する）。
set -euo pipefail

cd "$(dirname "$0")"
DIR="$(pwd)"
LABEL="com.ishot.voice-input"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUILT="$DIR/VoiceInput.app"
# 動かす場所は ~/Applications。ソースのフォルダに置いたままだと、
# アクセシビリティの「+」のファイル選択から辿りにくく、git clean で消えることもある。
APP="$HOME/Applications/VoiceInput.app"

if [ ! -d "$BUILT" ]; then
  echo "VoiceInput.app がありません。先に ./build.sh を実行してください。" >&2
  exit 1
fi

echo "==> ~/Applications へ入れる"
mkdir -p "$HOME/Applications"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "VoiceInput.app/Contents/MacOS/VoiceInput" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "$BUILT" "$APP"

echo "==> LaunchAgent を書き出す: $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/VoiceInput</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.voice-input/launchd.err.log</string>
    <key>StandardOutPath</key>
    <string>$HOME/.voice-input/launchd.out.log</string>
</dict>
</plist>
PLISTEOF

mkdir -p "$HOME/.voice-input"
echo "==> 登録し直す"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

sleep 1
echo
launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -E "state|pid" | head -3 || true
echo
echo "常駐しました: ${APP}"
echo "メニューバーにマイクのアイコンが出ていれば動いています。"
echo
echo "権限は「${APP}」に対して入れます。"
echo "アクセシビリティの一覧に出てこないときは、メニューバーのアイコン →"
echo "「アプリを Finder で表示」で開いた Finder から、一覧へドラッグしてください。"
echo
echo "外すとき: ./uninstall.sh"
