#!/bin/bash
# 残りの許可を入れて、入ったところで通し確認まで自動でやる。
#
# 権限の状態は「アプリ自身が起動時に書いたログ」で見る。
# ターミナルから --check を叩くと、ターミパル側の許可で通ってしまい当てにならない。
set -uo pipefail
cd "$(dirname "$0")"

LABEL="com.ishot.voice-input"
LOG="$HOME/.voice-input/voice-input.log"
BIN="$HOME/Applications/VoiceInput.app/Contents/MacOS/VoiceInput"

if [ ! -x "$BIN" ]; then
  echo "~/Applications/VoiceInput.app がありません。./build.sh のあと ./install.sh を実行してください。" >&2
  exit 1
fi

# アプリを起動し直して、いまの権限をログに書かせる
snapshot_permissions() {
  launchctl kickstart -k "gui/$UID/$LABEL" >/dev/null 2>&1
  sleep 2
  grep "権限 " "$LOG" | tail -1
}

echo "==> いまの権限"
LINE=$(snapshot_permissions)
echo "    ${LINE#*] }"

need_mic=0;  echo "$LINE" | grep -q "マイク=×" && need_mic=1
need_ax=0;   echo "$LINE" | grep -q "アクセシビリティ=×" && need_ax=1

if [ $need_mic -eq 0 ] && [ $need_ax -eq 0 ]; then
  echo "    必須の権限はそろっています。"
else
  echo
  echo "==> 足りない権限を入れてください"
  [ $need_mic -eq 1 ] && echo "    ・マイク          … 出てくるダイアログで「許可」を押す"
  [ $need_ax  -eq 1 ] && echo "    ・アクセシビリティ … 一覧の VoiceInput のスイッチを入れる"
  echo

  if [ $need_ax -eq 1 ]; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  fi

  echo "    待っています（最大5分／Ctrl-C で中断）"
  echo "    一覧に VoiceInput が出てこないときは、開いた Finder から一覧へドラッグしてください。"
  open -R "$HOME/Applications/VoiceInput.app" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    sleep 10
    LINE=$(snapshot_permissions)
    ok=1
    echo "$LINE" | grep -q "マイク=×" && ok=0
    echo "$LINE" | grep -q "アクセシビリティ=×" && ok=0
    if [ $ok -eq 1 ]; then echo "    そろいました。"; break; fi
    # 端末なら同じ行を上書きし、ログに流すときは10回に1回だけ出す
    if [ -t 1 ]; then
      printf "\r    %s (%d/30)" "${LINE#*] }" "$i"
    elif [ $((i % 10)) -eq 0 ]; then
      echo "    まだです: ${LINE#*] } (${i}/30)"
    fi
  done
  echo
  if echo "$LINE" | grep -qE "マイク=×|アクセシビリティ=×"; then
    echo "❌ まだ足りません: ${LINE#*] }"
    echo "   許可を入れてから、もう一度 ./finish-setup.sh を実行してください。"
    exit 1
  fi
fi

echo
echo "==> 通し確認"
"$BIN" --selftest | tail -1
"$BIN" --clipboard-test
"$BIN" --paste-test || exit 1

echo
echo "==> 最後に、実際に話して確かめてください"
echo "    1. Claude Code のターミナルなど、文字を入れたい場所にカーソルを置く"
echo "    2. ⌥Space を押して「ウタゲのファネルのリード数を調べて」と話す"
echo "    3. もう一度 ⌥Space"
echo "    → UTAGE のファネルのリード数を調べて  が入れば完成です"
echo
echo "    入らなければ: tail -20 $LOG"
