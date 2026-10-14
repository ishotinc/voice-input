# 音声入力（VoiceInput）

⌥Space を押して話し、もう一度押すと、カーソルのある場所に文字が入る Mac 用のメニューバーアプリです。
i-SHOT株式会社が社内で使っているものを、無料で公開しています。

- 紹介ページ: https://i-shot.jp/apps/voice-input/
- 入れ方・使い方・困ったとき: https://i-shot.jp/apps/voice-input/help/
- ダウンロード: [Releases](https://github.com/ishotinc/voice-input/releases/latest) の `VoiceInput-*-macOS-arm64.zip`

> **サポートはありません。** Issue・Pull Request・メールへの個別のお返事はいたしかねます。ご利用はご自身の責任でお願いいたします。
> Apple の開発元の署名を付けていないため、はじめて開くときに「開発元を確認できない」と表示されます。開き方はヘルプの「はじめて開くとき」をご覧ください。

## できること

- **話している間に文字にする** — 文字起こし（whisper.cpp）は Mac の中で動かし続け、話の切れ目ごとに先に文字にします。音声は外へ送りません
- **お客様の名前の漢字をまとめて覚える** — 「顧客資料フォルダを選ぶ…」で選んだフォルダの Markdown から人名・社名の表記を読み、その書き方に合わせます
- **開いている画面に合わせて仕上げる** — 入力欄のまわりの文字を手がかりに、ご自身の Claude が表記と言葉づかいを整えます（オフにできます）
- **AI の仕上げも録音中に始める** — 済んだ文から先に仕上げ、止めたときに残りだけを待ちます
- **Google Meet の議事録** — Chrome 拡張で入退室を検知して録音し、話者を分けて要約・決定事項・TODO にまとめます

## 2つのモード

| モード | 使うもの | 費用 |
|---|---|---|
| 高速入力モード | Mac の中だけ（AI もネットも使わない） | かかりません |
| 通常モード（AI 補正）・議事録の要約 | ご自身の Anthropic API キー（メニュー「Claude APIキーを設定…」）か、Max プランでログインした Claude Code | API キーは使った分だけ。Max プランは追加料金なし |

## 動作環境

- macOS 14 以降、Apple シリコン（M1 以降）。Intel Mac は動作を確かめていません
- Homebrew と `whisper-cpp`、音声認識モデル `ggml-large-v3-turbo-q5_0.bin`（約 0.5GB）

## 入れ方（ダウンロード版）

```sh
brew install whisper-cpp
mkdir -p ~/.voice-input/models
curl -L -o ~/.voice-input/models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

Releases の zip を開き、`VoiceInput.app` を「アプリケーション」へ移して開きます。マイクとアクセシビリティの許可が必要です。詳しくは[ヘルプ](https://i-shot.jp/apps/voice-input/help/)をご覧ください。

## ソースからビルドする

Xcode（または Swift 5.9 以降のコマンドラインツール）が必要です。

```sh
./build.sh          # ビルド → 自己テスト → VoiceInput.app を作って署名
./install.sh        # ~/Applications に入れ、ログイン時に起動するよう登録
./finish-setup.sh   # 権限の確認と通しの試験
```

会議の議事録を使う場合は、続けて次を実行し、Chrome の `chrome://extensions` で「パッケージ化されていない拡張機能を読み込む」から `~/.voice-input/meet-extension` を選びます。

```sh
./setup-meeting-models.sh
./setup-meeting-asr.sh        # 任意（会議用の高精度モデル）
python3 meet-extension/install-bridge.py
```

AI（Claude Code など）に設置を任せる場合は、[SETUP_WITH_AI.md](SETUP_WITH_AI.md) をそのまま渡してください。

## 消し方

```sh
./uninstall.sh
rm -rf ~/.voice-input
rm -f ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/jp.ishot.voiceinput.meet.json
```

## ライセンス

MIT License（[LICENSE](LICENSE)）。同梱の `Resources/SKK-JISYO.L` は GNU GPL v2 以降、`Resources/addresses.json` は日本郵便の郵便番号データを加工したものです（[THIRD-PARTY-NOTICES](Resources/THIRD-PARTY-NOTICES.txt)）。
