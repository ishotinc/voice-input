#!/bin/bash
# 実機での確認を1コマンドにまとめたもの。
# ビルド直後と、権限をいじったあとに回す。
set -uo pipefail
cd "$(dirname "$0")"
BIN="./VoiceInput.app/Contents/MacOS/VoiceInput"

if [ ! -x "$BIN" ]; then
  echo "VoiceInput.app がありません。先に ./build.sh を実行してください。" >&2
  exit 1
fi

fail=0
run() {
  echo
  echo "───── $1"
  shift
  "$@" || fail=1
}

run "1. 環境と権限" "$BIN" --check
run "2. 整形ルールの自己テスト" "$BIN" --selftest
run "3. クリップボードの復元" "$BIN" --clipboard-test

echo
echo "───── 4. マイクから録って文字起こし（5秒 話してください）"
echo "     例:「ウタゲのファネルのリード数を調べて」"
read -r -p "     準備ができたら Enter（飛ばすなら s + Enter）: " ans
if [ "$ans" != "s" ]; then
  "$BIN" --mic-test 5 || fail=1
fi

echo
echo "───── 5. TextEdit に実際に貼り付ける"
read -r -p "     実行しますか（Enter で実行 / s + Enter で飛ばす）: " ans
if [ "$ans" != "s" ]; then
  "$BIN" --paste-test || fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "✅ 通ったところまで問題なし"
else
  echo "❌ 失敗したものがあります。上を確認してください"
fi
exit $fail
