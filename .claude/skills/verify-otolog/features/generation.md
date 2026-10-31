# 生成

記録済みのセッションを claude CLI（`claude -p`）で処理し、議事録や要約などの生成物をセッションのディレクトリへ書く。
ポップオーバーの「生成」パネルで対象のセッションを選び、単発ならテンプレートを、プレイブックならプレイブックを選んで実行する。
タイトル生成は、セッションのディレクトリ名をタイトルに変える。

## Sub-features

- `generate-panel` 「生成」でパネルが開き、対象のポップアップ（最新のセッション）、単発とプレイブックの切り替え、テンプレートのポップアップ（既定は「誤認識の補正」）、「タイトルを生成」、「生成を実行」が出る
- `generate-pick` 対象とテンプレートをポップアップで選ぶ
- `generate-template` 単発で実行すると、`<テンプレートID>.md` がセッションのディレクトリに書かれる
- `generate-title` 「タイトルを生成」で、ディレクトリ名と meta.json の title がタイトルになる
- `generate-playbook` プレイブックを実行すると、タスクが依存順に走り、状態が meta.json の pipeline に残る
- `generate-open-session-guard` 記録中のセッションには「タイトルを生成」が出ず、プレイブックは「記録停止後に実行できます」と出して実行させない

テンプレートの表示名と ID（生成物のファイル名）:

| 表示名 | ID |
| --- | --- |
| 誤認識の補正 | `correct` |
| 議事録 | `minutes` |
| 講義ノート | `lecture` |
| ダイジェスト | `digest` |
| 要約 | `summary` |
| 用語集 | `glossary` |
| 参考資料集 | `references` |
| 質疑応答の抽出 | `qa` |
| 追試検討 | `repro` |
| 共有パッケージ | `share` |
| アクションアイテム | `actions` |
| フォローアップ下書き | `followup` |
| 現況メモの更新 | `situation` |

組み込みのプレイブックは、講演（`lecture`）と会議（`meeting`）。

## How to get to it (user POV)

- ポップオーバーのツールバーの右側の「生成」（きらめきのアイコン）
- ライブラリのツールバーの「生成」メニュー
- 設定の「停止時の自動処理」を「タイトル生成」か「タイトル生成 + プレイブック」にして記録を止める
- ターミナルで `otolog-devtool run-playbook <保存先> <セッション> [playbookID]` を実行する

## Driving it with otolog-verify

Preconditions:

- この run に、発話のあるセッションがある（[記録の開始と停止](./recording.md)）
- 検証用インスタンスは idle
- `~/.local/bin/claude`（設定の「claude パス」の既定）がログイン済み
- 「生成を実行」と「タイトルを生成」はユーザーの課金か利用枠を使う。押す前にユーザーの了解を得る

- パネルを開く
  - `$V ax popover open`、`$V ax press "生成"`、`$V ax wait "生成を実行" 5`
  - `$V ax tree` に次の要素が出る
    - 対象のポップアップ（value `<MM/dd> <セッション名>`）
    - `単発` と `プレイブック`（AXRadioButton）
    - テンプレートのポップアップ（value `誤認識の補正`）
    - `タイトルを生成` と `生成を実行`
- 対象を選ぶ
  - `$V ax press "value=<今の対象>"`、`$V ax press "<MM/dd> <セッション名>"`
  - `$V ax wait "value=<MM/dd> <セッション名>" 5` が `found:` を出す
- テンプレートを選ぶ
  - `$V ax press "value=誤認識の補正"`、`$V ax press "議事録"`
  - `$V ax wait "value=議事録" 5` が `found:` を出す
- 生成を実行する（claude を呼ぶ）
  - `$V ax press "生成を実行"`
  - パネルに「議事録 を生成中…」が出て、終わると `minutes.md` と「生成物を開く」が出る
  - `ls "$($V session)"` に `minutes.md` がある
- タイトルを生成する（claude を呼ぶ）
  - `$V ax press "タイトルを生成"`
  - 終わると、セッションのディレクトリ名と `plutil -extract title raw -o - "$($V session)/meta.json"` の出力が同じタイトルになる
- 証拠を残す
  - `$V shot generate-done`、`$V evidence generate`
- パネルを閉じる
  - `$V ax press "生成を閉じる"`、`$V ax popover close`

## Gotchas

- 「生成を実行」と「タイトルを生成」は、パネルを開いて選ぶところまでなら claude を呼ばない
- 検証用の `XDG_CONFIG_HOME` は空なので、ユーザー定義のテンプレート、プレイブック、前提知識、補正辞書は読まれない（組み込みだけ）
- ユーザーグローバルの `~/.claude/CLAUDE.md` は、claude の呼び出しにも適用される
- ポップアップで選んだ値は、すぐには AX に出ない。`$V ax wait "value=<値>"` で待ってから次へ進む
- 記録中のセッションには「タイトルを生成」が出ない。止めてから操作する
- launch は停止時の自動処理を none にする。停止時の自動実行を確かめるときは、設定の「停止時の自動処理」を変えてから記録する
- 15 万字を超えるセッションはエラーになる
