# ZundaNavi（ずんだもん案内アプリ）

声（または文字）＋GPS をメイン PC の旅ナビサーバー（trip-copilot）に送り、返事をずんだもん声で耳に流す iPhone アプリ。
SwiftUI・標準フレームワークのみ・iOS 17 以上。GitHub Actions で署名なし ipa を作り、SideStore ソースで配る。

## 入れ方（SideStore）

1. iPhone で **LocalDevVPN を Connect**（SideStore の署名に必要）
2. SideStore → Sources → ＋ → 次の URL を登録
   `https://raw.githubusercontent.com/arima0216/zundanavi/main/source.json`
3. Browse から ZundaNavi を Install（無料 Apple ID は SideStore 本体を含めて 3 アプリまで）
4. 以後の更新は SideStore → Updates を下に引っ張って Update

## 最初の設定

1. アプリを開く → 権限ダイアログを順に許可: マイク → 音声認識 → 位置（「使用中のみ」→ あとで「常に」へ変更を求められる）
2. iPhone の Tailscale を ON
3. 「設定」タブ → サーバー URL（例 `http://<メインPC の Tailscale IP>:47400`）とトークンを入力（トークンは Keychain に保存）
4. 「接続テスト」→ `OK: OK (whisper: ..., voicevox: ..., brain: ...)` が出れば開通

## 使い方

- **ナビ**タブの大ボタン: 押している間だけ録音、離すと送信。1 回タップすると録音開始→無音 1.2 秒で自動送信（もう一度タップでも送信）
- **ウェイクワード**: 「ふぇーぶる、今どこ？」のように呼びかける（端末内の認識のみ。音声を外に出さない）。ウェイク語の後の「ナビを開始して」「ナビを終了して」「静かにして」はボタンと同じ扱い
- 「文字で聞く」欄、「ナビ開始」「ナビ終了」「静かに(10分)」ボタン、カメラ／写真ボタン（入力欄の文字は写真のメモとして一緒に送る）
- **履歴**タブ: 会話の往復。行をタップすると音声をもう一度鳴らす。下に引っ張るとサーバーの履歴で補完
- **設定**タブ: マイク（イヤホン HFP ／本体）、GPS 送信、電池ログ（5 分ごとに CSV、共有ボタンで書き出し）

## 開発

- `Sources/Core` は Foundation だけのロジック（モデル・multipart・WAV・ウェイク語・コマンド振り分け）。CI で `swiftc` テスト（`Tests/LogicTests/main.swift`）
- `Sources/Services` は音声・GPS・WS・API、`Sources/App` は司令塔 `AppModel`、`Sources/Views` は画面
- `project.yml`（XcodeGen）の `MARKETING_VERSION` を上げて `git push` すると Release `v<版>` と `source.json` が自動更新される
- アイコンは `python tools/make_icon.py` で再生成
- サーバーの API 契約は trip-copilot 側の `docs/briefs/WP-2-ios-core.md`「API 契約 v1」

このリポジトリにトークン・旅程・個人情報は入れない。既定 URL はプレースホルダ（Tailscale 内アドレス）。
