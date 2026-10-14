#!/bin/bash
# VoiceInput.app を組み立てる。ビルド → .app 化 → ad-hoc 署名まで。
set -euo pipefail

cd "$(dirname "$0")"
APP="VoiceInput.app"
BUNDLE_ID="com.ishot.voice-input"

echo "==> ビルド"
# アプリ本体にビルドした場所のフルパス（ユーザー名を含む）を残さない
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$(pwd)=."

echo "==> 自己テスト"
./.build/release/VoiceInput --selftest

echo "==> .app を組み立て"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceInput "$APP/Contents/MacOS/VoiceInput"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/addresses.json "$APP/Contents/Resources/addresses.json"
cp Resources/addresses.source.json "$APP/Contents/Resources/addresses.source.json"
cp Resources/terms.json "$APP/Contents/Resources/terms.json"
cp Resources/meeting-vad.py "$APP/Contents/Resources/meeting-vad.py"
cp Resources/meeting-diarize.py "$APP/Contents/Resources/meeting-diarize.py"

# アドホック署名（-）はビルドのたびに cdhash が変わり、macOS が「別のアプリ」とみなして
# 入れた権限を捨てる。実測で3回外れた。証明書があるなら必ずそちらで署名する。
# 環境変数 VOICEINPUT_IDENTITY で明示指定もできる。
IDENTITY="${VOICEINPUT_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
fi

mkdir -p "$APP/Contents/Resources"
cp -R Resources/. "$APP/Contents/Resources/"

echo "==> 署名"
if [ -n "$IDENTITY" ]; then
  echo "    証明書で署名します（権限がビルドをまたいで残ります）"
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
  echo "    ⚠️ 証明書が見つからないのでアドホック署名にします"
  echo "       ビルドのたびに権限が外れます（security find-identity -v -p codesigning）"
  codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "できあがり: $(pwd)/$APP"
echo "起動:       open $(pwd)/$APP"

# 権限の状態は「アプリ自身が起動時に書いたログ」で見る。
# ターミナルから --check を叩くと、ターミナル側の許可で通ってしまい当てにならない。
LOG="$HOME/.voice-input/voice-input.log"
PERM=""
if launchctl print "gui/$UID/com.ishot.voice-input" >/dev/null 2>&1; then
  # ビルドでは利用中のアプリを再起動しない。更新時のみinstall.shで再起動する。
  PERM=$(grep "権限 " "$LOG" 2>/dev/null | tail -1)
fi

echo
echo "==> 権限の状態（アプリ自身が見たもの）"
if [ -n "$PERM" ]; then
  echo "    ${PERM#*] }"
else
  echo "    まだ常駐していません。./install.sh を実行してください。"
fi

if echo "$PERM" | grep -qE "マイク=×|アクセシビリティ=×"; then
  cat <<'WARN'

  ⚠️ 必須の権限が外れています。

  このアプリはアドホック署名（codesign -s -）なので、ビルドし直すたびに署名が変わり、
  macOS は「別のアプリ」とみなして許可を捨てます。実測で確認済み（2026-09-04）。

  ビルド後は毎回、メニューバーのアイコン →「権限を確認…」から入れ直してください。
  古い許可が残って外せないときは:
      tccutil reset Microphone com.ishot.voice-input
      tccutil reset Accessibility com.ishot.voice-input
WARN
fi
