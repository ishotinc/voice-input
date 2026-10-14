# AI に設置を任せるときの手順書

この文書は Claude Code などのコーディング AI にそのまま渡してお使いください。AI は上から順に実行し、各手順の「確かめ方」で結果を確認してから次へ進みます。

## 前提の確認

1. `sw_vers -productVersion` が 14 以上、`uname -m` が `arm64` であること。満たさなければ止めて利用者に伝える
2. `brew -v` が通ること。通らなければ https://brew.sh の手順で Homebrew を入れる（利用者の同意を得てから）

## 文字起こしの部品

```sh
brew install whisper-cpp
mkdir -p ~/.voice-input/models
curl -L -o ~/.voice-input/models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

確かめ方: `which whisper-cli` がパスを返し、モデルのファイルが 500MB 前後あること。

## アプリ

ソースからビルドする場合（このリポジトリを clone したフォルダで）:

```sh
./build.sh && ./install.sh
```

- `build.sh` は自己テストを回す。「全 N 件通過」でなければ止めて、失敗した項目を利用者に伝える
- 証明書が無い Mac ではアドホック署名になり、ビルドし直すたびにマイクとアクセシビリティの許可が外れる。そのことを利用者に伝える

## 権限（利用者の操作が要る）

AI はシステム設定を代わりに操作しない。利用者に次を頼む。

1. メニューバーの音声入力のアイコン →「権限を確認…」
2. 「マイク」と「アクセシビリティ」で VoiceInput をオンにする

確かめ方: `./finish-setup.sh` を実行し、案内どおりに ⌥Space で話してもらう。

## AI 補正（任意）

次のどちらかを利用者に選んでもらう。AI は API キーを代わりに入力しない。

- Anthropic の API キー: メニュー「Claude APIキーを設定…」に利用者自身が貼り付ける
- Claude Code の Max プラン: 利用者がターミナルで `claude` を開いてログインする

## 会議の議事録（任意）

```sh
./setup-meeting-models.sh
./setup-meeting-asr.sh
python3 meet-extension/install-bridge.py
```

Chrome 拡張の読み込み（`chrome://extensions` → デベロッパーモード → `~/.voice-input/meet-extension`）は利用者に頼む。

## 守ること

- 利用者の API キー・パスワード・Google の認証情報を、AI が読み上げたりファイルに書いたりしない
- システム設定・セキュリティ設定を AI が変更しない
- 問い合わせ先はありません。動かないときは `~/.voice-input/voice-input.log` を読んで原因を調べる
