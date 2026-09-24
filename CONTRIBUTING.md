# CONTRIBUTING

OtoLog の開発・ビルド・リリースに関する情報。利用者向けの説明は [README.md](README.md) を参照。

## 必要環境

- macOS 26 以降（SpeechAnalyzer 必須）
- Xcode（Swift 6.2+ ツールチェーン）
- [mise](https://mise.jdx.dev/)

## ソースからのビルド

```bash
mise trust && mise install
mise run install   # ビルド → ~/Applications/OtoLog.app へ配置 → 起動
```

- `mise run bundle` — `dist/OtoLog.app` を組み立てる（配置・起動はしない）
- `mise run dist` — 配布用 `dist/OtoLog.zip` を作る（ad-hoc 署名）

## 開発コマンド

```bash
mise run test               # 単体テスト + swiftformat lint（TCC・ネットワーク不要）
mise run test:integration   # 実 SpeechAnalyzer の統合テスト（初回はモデルDL）
mise run test:claude        # 実 claude -p の統合テスト（課金あり・要ログイン）
mise run skill:install      # otolog-generate スキルを ~/.claude/skills へ symlink
swift run otolog-devtool <audio-file> [locale...]     # エンジン単体の検証CLI（カンマ区切りで自動検出）
swift run otolog-devtool export-templates <dir>       # 組み込みテンプレートの書き出し
swift run otolog-devtool migrate-daily <dir>          # 旧日次形式をセッション構造へ移行
swift run otolog-devtool migrate-structure <dir>      # 旧フラット構造（yyyy-MM-dd_HHmm_タイトル/）を移行
swift run otolog-devtool ctl <status|start|stop>      # 起動中アプリの制御（エージェント連携用）
```

`ctl` は起動中のアプリを Unix ドメインソケット（`$XDG_STATE_HOME/otolog/control.sock`、0600 で自ユーザーのみ）経由で操作する。
応答は JSON 1行（`{"ok":true,"state":"recording","sessionPath":"..."}`）で、`ok: false` は exit 1、アプリ未起動は exit 69。
エージェントや自動化から UI 操作（AX）なしで記録の開始・停止・状態確認ができる。
初回の「システム音声の録音」許可ダイアログだけは人の操作が必要。

旧フラット構造は移行しなくても読み取り互換で表示される。

### デバッグ

- `OTOLOG_TRACE=1` でエンジン内部のトレースが stderr に出る
- `OTOLOG_CLAUDE_DEBUG=1` で claude 呼び出しごとの診断ログを `$XDG_STATE_HOME/otolog/claude-logs/`（既定 `~/.local/state/...`）へ保存する。呼び出しタイムライン（`.log`: 引数・プロンプトサイズ・チャンク受信・終了/エラー）と claude CLI 内部ログ（`-cli.log`: API リクエスト・リトライ）の2ファイル1組。生成が進んでいるか・リトライで詰まっているかの切り分けに使う
  - GUI アプリで有効化する場合は `launchctl setenv OTOLOG_CLAUDE_DEBUG 1` してからアプリを再起動（戻すときは `unsetenv`）
- 記録の経緯は設定なしで常に `$XDG_STATE_HOME/otolog/recording.log`（既定 `~/.local/state/...`）へ追記される。記録が止まった原因の切り分けに使う
  - 1行に1件で、開始要求（経路・入力・認識ロケール）、状態遷移（failed は理由つき）、キャプチャの中断、保存と翻訳の失敗、閉じたセッションのディレクトリ名を残す。発話の本文は書かない
  - 同じ行を統合ログにも出す（`log show --last 1d --predicate 'subsystem == "com.bigdra50.OtoLog" AND category == "recording"'`）
  - キャプチャの中断には、止まった音源と、連続何回目の再起動か（`restart 1`）か諦めたこと（`giving up`）が付く
  - 同じ音源の再起動は連続3回まで。前回の再起動から1分以上動いていれば、次の中断は `restart 1` に戻る
  - 開始の途中（`preparing`）の中断もその時点で残し、再起動は `recording` に入ってから行う。開始がそのまま失敗や停止で終わったときは、この再起動は行われない
  - 保存先を確保した後に失敗すると、停止と同じく `stopping` を経てセッションを閉じてから `failed` になる。準備や保存先の確保での失敗は、閉じるものが無いので直接 `failed` になる
  - 閉じたセッションの行（`session finished`）は、失敗では1件以上保存できたときだけ出る

    ```text
    2026-07-29T13:40:03.123+0900 [ERROR] capture interrupted: マイク (restart 1): 音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。
    2026-07-29T14:10:44.001+0900 [ERROR] capture interrupted: マイク (restart 1): 音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。
    2026-07-29T14:10:45.320+0900 [ERROR] capture interrupted: マイク (restart 2): 音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。
    2026-07-29T14:10:46.518+0900 [ERROR] capture interrupted: マイク (restart 3): 音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。
    2026-07-29T14:10:47.702+0900 [ERROR] capture interrupted: マイク (giving up): 音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。
    2026-07-29T14:10:47.703+0900 [INFO] state: stopping
    2026-07-29T14:10:48.915+0900 [INFO] session finished: 2026-07-29/1300
    2026-07-29T14:10:48.916+0900 [ERROR] state: failed: マイク: 音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。
    ```

## プロジェクト構成

- `OtoLogCore` — コントラクト + 実装。全ロジックのテストはここ
- `OtoLogApp` — 薄い UI 層（テストなし）
- コントラクト（`Contracts/`）を境界に、キャプチャ源・エンジン・ストア・翻訳器は差し替え可能

## 設計上の要点（SpeechAnalyzer の落とし穴）

- `AssetInventory` の予約は冪等に行う（`ensureReserved`）。全予約解除→再予約は macOS のアセット管理を壊し、モデルDLが CancellationError で失敗する（[finnvoor/yap#32](https://github.com/finnvoor/yap/issues/32)）
- アセットは `installedLocales` でゲートせず `assetInstallationRequest` へ常に問い合わせる。volatileResults 構成には追加アセットが要る
- `transcriber.results` の購読は `analyzer.start` より先に張る。ライブ配信型で過去分を再送しない
- 統合テストは直列実行（`.serialized`）。AssetInventory への並行アクセスはハングする

## 署名と TCC

システム音声録音の許可（システム設定 > プライバシーとセキュリティ > 画面収録とシステム音声録音 の「System Audio Recording Only」）は「バンドルID + コード署名」に紐づく。画面そのものへのアクセス権は要求しない。
既定の ad-hoc 署名はビルドごとにハッシュが変わり、**リビルドのたびに許可が剥がれる**。
開発時は自己署名証明書での署名を推奨:

1. キーチェーンアクセス > 証明書アシスタント > 証明書を作成
2. 名前 `OtoLog Dev`、種類「自己署名ルート」、証明書のタイプ「コード署名」
3. `OTOLOG_CODESIGN_IDENTITY="OtoLog Dev" mise run install`

許可が壊れた場合のリセット: `tccutil reset AudioCapture com.bigdra50.OtoLog`（旧版の画面収録エントリが残っている場合は `tccutil reset ScreenCapture com.bigdra50.OtoLog`）

## リリースと配布

タグを push すると GitHub Actions（`.github/workflows/release.yml`）が macOS ランナーで zip をビルドして Release に添付し、本文に sha256 を出力する。

```bash
git tag v0.1.0 && git push origin v0.1.0
```

配布は Homebrew tap（別リポジトリ `bigdra50/homebrew-tap` の `Casks/otolog.rb`）経由。
リリースごとに Cask の `version` と `sha256` を Release 本文の値へ更新する（テンプレートは `packaging/homebrew/otolog.rb`）。
ローカルで zip だけ作るなら `mise run dist`（`dist/OtoLog.zip`）。

ad-hoc 署名・未公証のため、GitHub Releases 版は受領側で quarantine 除去が要る（Cask は postflight で自動除去）。
誰でも警告なく開ける正規配布にするには Apple Developer Program（年 $99）への加入が要る。加入すれば Developer ID Application 証明書での署名と公証が可能になり、quarantine 除去は不要になる。
