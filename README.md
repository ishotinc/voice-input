# 音声入力（VoiceInput）

⌥Space を押して話し、もう一度押すと、カーソルのある場所に文字が入る Mac 用のメニューバーアプリです。
i-SHOT株式会社が社内で使っているものを、無料で公開しています。

- 紹介ページ: https://i-shot.jp/apps/voice-input/
- 入れ方・使い方・困ったとき: https://i-shot.jp/apps/voice-input/help/
- ダウンロード: [Releases](https://github.com/ishotinc/voice-input/releases/latest) の `VoiceInput-*-macOS-arm64.zip`

> **サポートはありません。** Issue・Pull Request・メールへの個別のお返事はいたしかねます。ご利用はご自身の責任でお願いいたします（下の「免責・サポートについて」をご覧ください）。
> Apple の開発元の署名を付けていないため、はじめて開くときに「開発元を確認できない」と表示されます。開き方はヘルプの「はじめて開くとき」をご覧ください。

## できること

- **話している間に文字にする** — 文字起こし（whisper.cpp）は Mac の中で動かし続け、話の切れ目ごとに先に文字にします。音声は外へ送りません
- **お客様の名前の漢字をまとめて覚える** — 「顧客資料フォルダを選ぶ…」で選んだフォルダの Markdown から人名・社名の表記を読み、その書き方に合わせます
- **開いている画面に合わせて仕上げる** — 入力欄のまわりの文字を手がかりに、ご自身の AI（Claude か OpenAI）が表記と言葉づかいを整えます（オフにできます）
- **AI の仕上げも録音中に始める** — 済んだ文から先に仕上げ、止めたときに残りだけを待ちます

## 2つのモード

| モード | 使うもの | 費用 |
|---|---|---|
| 高速入力モード | Mac の中だけ（AI もネットも使わない） | かかりません |
| 通常モード（AI 補正） | 次のどれか1つ（メニュー「AI の仕上げに使うもの」で選ぶ）<br>・Claude: Anthropic の API キー（「Claude APIキーを設定…」）か、Max プランでログインした Claude Code<br>・OpenAI: OpenAI の API キー（「OpenAI APIキーを設定…」）<br>・OpenAI: ChatGPT のプランでログインした Codex（`codex login`） | API キーは使った分だけ。Claude の Max プラン・ChatGPT のプランは追加料金なし |

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

AI（Claude Code など）に設置を任せる場合は、[SETUP_WITH_AI.md](SETUP_WITH_AI.md) をそのまま渡してください。

## 消し方

```sh
./uninstall.sh
rm -rf ~/.voice-input
rm -f ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/jp.ishot.voiceinput.meet.json
```

## 免責・サポートについて

- このソフトは現状のまま無料で提供しています。動作・正確さ・特定の目的への適合を保証するものではありません
- このソフトの利用、または利用できなかったことによって生じたいかなる損害についても、i-SHOT株式会社は責任を負いません
- 不具合の修正・機能の追加・質問への回答は行いません。このリポジトリは読み取り専用（アーカイブ）です。必要な変更は、各自でフォークしてお使いください

## ライセンス

MIT License（[LICENSE](LICENSE)）。同梱の `Resources/SKK-JISYO.L` は GNU GPL v2 以降、`Resources/addresses.json` は日本郵便の郵便番号データを加工したものです（[THIRD-PARTY-NOTICES](Resources/THIRD-PARTY-NOTICES.txt)）。

## v1.2.0 の変更

- 変換中も次の録音を開始できます。前の結果の自動貼り付けを抑え、履歴に残します。
- ⌥＋右クリックで最新5件の履歴から貼り付けられます（アクセシビリティの許可が必要）。履歴はメモリ内のみです。
- 更新時はアプリを終了して置き換え、必要に応じて権限を設定し直してください。
