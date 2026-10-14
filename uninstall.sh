#!/bin/bash
# 常駐をやめる。設定と辞書（~/.voice-input）は消さない。
set -euo pipefail
LABEL="com.ishot.voice-input"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "VoiceInput.app/Contents/MacOS/VoiceInput" 2>/dev/null || true
rm -rf "$HOME/Applications/VoiceInput.app"
echo "常駐を外しました。設定と用語辞書は ~/.voice-input に残しています。"
