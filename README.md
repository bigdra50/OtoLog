# OtoLog

[![Release](https://img.shields.io/github/v/release/bigdra50/OtoLog?sort=semver)](https://github.com/bigdra50/OtoLog/releases/latest)
[![Release workflow](https://github.com/bigdra50/OtoLog/actions/workflows/release.yml/badge.svg)](https://github.com/bigdra50/OtoLog/actions/workflows/release.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-fa7343?logo=swift&logoColor=white)
[![Homebrew tap](https://img.shields.io/badge/brew-bigdra50%2Ftap%2Fotolog-informational?logo=homebrew&logoColor=white)](https://github.com/bigdra50/homebrew-tap)

Mac から出る任意の音声をリアルタイム文字起こしして記録セッション（講演・会議など開始〜停止の単位）ごとに保存する、メニューバー常駐アプリ。
録音・認識・保存はすべてオンデバイス（Apple SpeechAnalyzer）で完結し、クラウド送信はない。

- キャプチャ: ScreenCaptureKit のシステム音声（BlackHole 等の仮想ドライバ不要、音声ルーティング無変更）
- 認識: macOS 26 SpeechAnalyzer（日本語対応、volatile 結果によるライブ字幕付き）
- 保存: セッションごとのディレクトリに transcript.md（人が読む用）+ transcript.jsonl（後処理用の生セグメント）+ meta.json

## 必要環境

- macOS 26 以降（SpeechAnalyzer 必須）
- ビルドには Xcode（Swift 6.2+ ツールチェーン）と mise

## セットアップ

```bash
mise trust && mise install
mise run install   # ビルド → ~/Applications/OtoLog.app へ配置 → 起動
```

初回の使い方:

1. メニューバーの耳アイコンをクリック → 「開始」
2. 画面収録の許可ダイアログを許可する（システム音声キャプチャに必要）
3. ポップオーバーの「アプリを再起動」を押す（許可直後のプロセスではキャプチャできないため）
4. もう一度「開始」→ アイコンが波形アニメーションになり記録開始
5. 「停止」でセッションが閉じ、保存先にセッションディレクトリができる

動作確認は `say -v Kyoko "こんにちは"` などでシステム音声を鳴らすとよい。

## 使い方

| 操作 | 場所 |
| --- | --- |
| 記録の開始 / 停止 | ポップオーバーのボタン |
| ライブ字幕 | ポップオーバー（volatile 結果。保存されるのは確定分のみ） |
| 記録の閲覧（ライブラリ） | ポップオーバーの「ライブラリ」→ 専用ウィンドウ |
| 最新の記録を開く | ポップオーバー（セッションが無ければ保存先フォルダを開く） |
| 生成 / タイトル生成 | ポップオーバー内の「生成」 |
| 言語 / 保存先 / claude パス / 停止時の自動処理 / ログイン時起動 | ポップオーバー内の「設定」 |

### ライブラリ（ビューワー）

セッション一覧から選んで、文字起こしと生成物をアプリ内で閲覧できる。

- 文字起こしは正本 jsonl を時刻付きリストで表示（テキスト選択可）
- 生成物（要約・用語集など）は Markdown をレンダリング表示（[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) の GitHub テーマ）
- ツールバーからセッションフォルダを Finder で、表示中のファイルを既定エディタで開ける

アイコンの状態: 耳=待機、下矢印=モデル準備中、波形アニメーション=記録中、警告=エラー。

## 保存形式

```
<保存先>/
  2026-07-29/                       # 日付フォルダ
    ボクセル技術講演/                # セッション（タイトル名。未タイトルは HHmm、同日重複は -2 連番）
      transcript.jsonl              # 正本（1行1確定セグメントの JSON、ISO8601 ミリ秒）
      transcript.md                 # 人が読む用（- **HH:mm:ss** 本文）
      meta.json                     # タイトル・開始/終了時刻・sessionID など
      minutes.md 等                 # 生成物（再実行で上書きされる派生物）
  briefs/                           # 事前ブリーフ
```

- セッションは開始〜停止の1単位。日を跨いでも同一ディレクトリに記録され続ける
- タイトルは停止後に claude で自動生成できる（設定「停止時の自動処理」）。手動は「生成」内の「タイトル生成」から。**ディレクトリ名がタイトルにリネーム**され、meta.json・md 見出しもまとめて更新される
- 移行: 旧日次形式は `swift run otolog-devtool migrate-daily <保存先>`、旧フラット構造（yyyy-MM-dd_HHmm_タイトル/）は `swift run otolog-devtool migrate-structure <保存先>`。旧フラット構造は移行しなくても読み取り互換で表示される

## 生成（後処理）

記録済みのセッションを `claude -p`（Claude CLI）で後処理し、生成物をセッションディレクトリへ書き出せる。
ポップオーバーの「生成」から対象セッションとテンプレートを選んで実行する。

- transcript.jsonl は不変の正本、生成物 `<テンプレートID>.md` は再実行で上書きされる派生物
- 組み込みテンプレート: 誤認識の補正（correct）/ 議事録（minutes）/ 講義ノート（lecture）/ ダイジェスト（digest）
- ユーザー定義テンプレートは `~/.config/otolog/templates/<id>.md` に置く。最初の `# 見出し` が表示名、残りが生成指示。同 id は組み込みを上書き
- 記録中でも実行できる（その時点までの内容で生成される）
- 前提: [Claude CLI](https://docs.anthropic.com/claude-code) がログイン済みであること。パスは設定で変更できる（既定 `~/.local/bin/claude`）

制約と挙動:

- モデルは指定せず CLI の既定に従う（タイトル生成のみ haiku）。ユーザーグローバルの `~/.claude/CLAUDE.md` も適用される
- ログが15万字を超えるセッションは明示エラーになる（分割生成は未対応）
- claude はツール全無効・セッション非永続で呼ぶため、ログ由来のプロンプトインジェクションが起きても被害はテキスト出力に限られる

### プレイブック（マルチエージェント後処理）

「生成」のプレイブックモードで、複数の生成タスクを依存順に並列実行できる（同時実行は2）。

- 組み込み:
  - 講演（lecture）: 校正 → 要約 / 用語集 / 参考資料 / 質疑 / 追試検討 → 共有パッケージ
  - 会議（meeting）: 校正 → 議事録 / アクションアイテム → フォローアップ下書き
- 校正結果は下流タスクのログ入力として再利用され、統合タスク（共有・フォローアップ）は依存成果物を受け取る
- 用語集・参考資料・追試検討のみ Web 検索を許可して実行する（他タスクはツール全無効のまま）
- タスクごとに model（haiku / sonnet / opus）を指定。失敗タスクの下流だけスキップされ、パネルから失敗分のみ再実行できる
- 実行状態は meta.json に記録され、アプリを再起動しても結果を確認できる
- 停止時の自動実行: 設定「停止時の自動処理」を「タイトル生成 + プレイブック」にする。プレイブックは既定で記録内容から自動判定される（haiku が候補の説明と照合。判定不能なら実行せず手動対処を促す）。固定のプレイブックを選ぶこともできる
- 目安: 1時間の講演で lecture 完走 ≈ 7〜10分

ユーザー定義プレイブックは `~/.config/otolog/playbooks/<id>.json`:

```json
{
  "displayName": "ポッドキャスト",
  "description": "ポッドキャストやラジオ番組など、会話形式の音声コンテンツの記録",
  "tasks": [
    {"templateID": "correct", "model": "sonnet"},
    {"templateID": "digest", "model": "haiku", "dependsOn": ["correct"]},
    {"templateID": "references", "model": "sonnet", "web": true, "dependsOn": ["correct"]}
  ]
}
```

description は自動判定の判定材料になる（id `auto` は予約語）。

### エージェントからの生成（スキル）

`mise run skill:install` で Claude Code 用スキル `otolog-generate` を `~/.claude/skills` へ symlink する。
以後 Claude Code から「さっきの講演を議事録にして」等でアプリと同じ規約の生成物を作れる。
スキル同梱のテンプレートは Swift 定数（正本）からの書き出しで、ドリフトはテストが検知する。

## 開発

```bash
mise run test               # 単体テスト + swiftformat lint（TCC・ネットワーク不要）
mise run test:integration   # 実 SpeechAnalyzer の統合テスト（初回はモデルDL）
mise run test:claude        # 実 claude -p の統合テスト（課金あり・要ログイン）
mise run bundle             # dist/OtoLog.app を組み立て
mise run install            # ~/Applications へ配置して起動
mise run skill:install      # otolog-generate スキルを ~/.claude/skills へ symlink
swift run otolog-devtool <audio-file> [locale]        # エンジン単体の検証CLI
swift run otolog-devtool export-templates <dir>       # 組み込みテンプレートの書き出し
swift run otolog-devtool migrate-daily <dir>          # 旧日次形式をセッション構造へ移行
```

- `OTOLOG_TRACE=1` でエンジン内部のトレースが stderr に出る
- `OTOLOG_CLAUDE_DEBUG=1` で claude 呼び出しごとの診断ログを `$XDG_STATE_HOME/otolog/claude-logs/`（既定 `~/.local/state/...`）へ保存する。呼び出しタイムライン（`.log`: 引数・プロンプトサイズ・チャンク受信・終了/エラー）と claude CLI 内部ログ（`-cli.log`: API リクエスト・リトライ）の2ファイル1組。生成が進んでいるか・リトライで詰まっているかの切り分けに使う
  - GUI アプリで有効化する場合は `launchctl setenv OTOLOG_CLAUDE_DEBUG 1` してからアプリを再起動（戻すときは `unsetenv`）
- 構成: `OtoLogCore`（コントラクト + 実装、全ロジックのテストはここ）/ `OtoLogApp`（薄い UI 層、テストなし）
- コントラクト（`Contracts/`）を境界に、キャプチャ源・エンジン・ストアは差し替え可能

### 設計上の要点（SpeechAnalyzer の落とし穴）

- `AssetInventory` の予約は冪等に行う（`ensureReserved`）。全予約解除→再予約は macOS のアセット管理を壊し、モデルDLが CancellationError で失敗する（[finnvoor/yap#32](https://github.com/finnvoor/yap/issues/32)）
- アセットは `installedLocales` でゲートせず `assetInstallationRequest` へ常に問い合わせる。volatileResults 構成には追加アセットが要る
- `transcriber.results` の購読は `analyzer.start` より先に張る。ライブ配信型で過去分を再送しない
- 統合テストは直列実行（`.serialized`）。AssetInventory への並行アクセスはハングする

## 署名と TCC

画面収録の許可は「バンドルID + コード署名」に紐づく。
既定の ad-hoc 署名はビルドごとにハッシュが変わり、**リビルドのたびに許可が剥がれる**。
日常利用では自己署名証明書での署名を推奨:

1. キーチェーンアクセス > 証明書アシスタント > 証明書を作成
2. 名前 `OtoLog Dev`、種類「自己署名ルート」、証明書のタイプ「コード署名」
3. `OTOLOG_CODESIGN_IDENTITY="OtoLog Dev" mise run install`

許可が壊れた場合のリセット: `tccutil reset ScreenCapture com.bigdra50.OtoLog`

## 配布

Apple Developer Program 未加入のため公証（notarization）は行わず、ad-hoc 署名の zip を配る。
未署名扱いなので、初回起動時だけ Gatekeeper の quarantine 属性を外す必要がある。

### インストール（Homebrew 推奨）

```bash
brew install --cask bigdra50/tap/otolog
```

Cask 側で quarantine 属性を自動で外すため、追加操作なしで起動できる。
更新は `brew upgrade --cask otolog`。

### インストール（GitHub Releases）

1. [Releases](https://github.com/bigdra50/OtoLog/releases) から `OtoLog.zip` を取得して展開し、`OtoLog.app` を `/Applications` などへ移動する
2. quarantine 属性を外す（付いたままだと「開発元を検証できない」「壊れている」等で開けない）:

   ```bash
   xattr -dr com.apple.quarantine /Applications/OtoLog.app
   ```

3. 起動し、初回に画面収録の許可を一度与える

### リリースの作り方

タグを push すると GitHub Actions（`.github/workflows/release.yml`）が zip をビルドして Release に添付し、本文に sha256 を出力する。

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Homebrew tap は別リポジトリ `bigdra50/homebrew-tap` に `Casks/otolog.rb` を置く（テンプレートは `packaging/homebrew/otolog.rb`）。リリースごとに Cask の `version` と `sha256` を Release 本文の値へ更新する。

ローカルで zip だけ作るなら `mise run dist`（`dist/OtoLog.zip`）。

誰でも警告なく開ける正規配布にするには Apple Developer Program（年 $99）への加入が要る。加入すれば Developer ID Application 証明書での署名と公証が可能になり、quarantine 除去は不要になる。

## 既知の制約

- ノッチのある MacBook でメニューバーが混んでいると、アイコンが OS によって非表示になる（本アプリに限らない挙動）。メニューバーの空きを作るか、[Ice](https://github.com/jordanbaird/Ice) 等の管理ツールを使う
- ScreenCaptureKit を使うため、記録中はメニューバーに紫の収録インジケータが出る。「システム音声の録音のみ」権限（CoreAudio process tap）への移行は将来課題
- 記録開始直後の約2秒は取りこぼす（モデルロードとキャプチャ起動のため）
- 保存されるのはシステム音声のみ。マイク（自分の声）の同時記録は将来対応

## クレジット

キャプチャと認識のパイプラインは [finnvoor/yap](https://github.com/finnvoor/yap)（CC0-1.0）の実装を参考にした。
