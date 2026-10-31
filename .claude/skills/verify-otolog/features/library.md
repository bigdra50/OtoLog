# ライブラリ

ポップオーバーの「ライブラリ」で、専用のウィンドウ「OtoLog ライブラリ」が開く。
サイドバーには保存先のセッションが日付ごとに新しい順で並び、選んだセッションの文字起こしと生成物が右側に出る。

## Sub-features

- `library-open` 「ライブラリ」でウィンドウが開き、最新のセッションが選ばれている
- `library-list` サイドバーに「前提知識」と、日付の見出しの下のセッション（名前と「<HH:mm>・<N>分」）が並ぶ
- `library-select` 行を選ぶと、右側に名前、時間帯、「文字起こし」、時刻つきの発話が出る
- `library-reload` ツールバーの「一覧を更新」で、開いたまま一覧を読み直す
- `library-knowledge` 「前提知識」を選ぶと、前提知識の画面が出る
- `library-close` ウィンドウを閉じる
- `library-copy-path` ツールバーの「パスをコピー」で、表示中のファイルのパスをクリップボードへコピーする
- `library-trash` 行の削除アイコンか右クリックの「ゴミ箱に入れる」で、確認の後にセッションをゴミ箱へ移す

## How to get to it (user POV)

- ポップオーバーのツールバーの左端の「ライブラリ」（本のアイコン）
- ウィンドウのサイドバーの行と、ツールバーのボタン（生成アクティビティ、一覧を更新、サイドバーの開閉、生成、パスをコピー、外部アプリで開く）

## Driving it with otolog-verify

Preconditions:

- この run で [記録の開始と停止](./recording.md) を 2 回以上通し、発話のあるセッションが 2 つ以上ある
- 検証用インスタンスは idle

- 開く
  - `$V ax popover open`、`$V ax press "ライブラリ"`、`$V ax wait "一覧を更新" 10`
  - `$V ax tree | grep '^AXWindow'` が `title="OtoLog ライブラリ"` を含む行を出す
- 一覧を確かめる
  - `$V ax tree | grep -E 'AXHeading|AXStaticText value="[0-9]{4}(-[0-9]+)?"'`
  - 日付の見出し（`AXHeading desc="<yyyy-MM-dd>"`）の下に、セッション名が新しい順に並ぶ
  - 最新のセッション名は 2 回出る（サイドバーの行と右側の見出し）
- 別のセッションを選ぶ
  - 2 番目に新しいセッション名を `<name>` として、`$V ax select "<name>"`
  - `$V ax tree | grep -c 'AXStaticText value="<name>"'` が 2 を出す
  - 右側の `AXStaticText value="<HH:mm:ss>"` の時刻が、そのセッションの transcript.jsonl の finalizedAt をローカル時刻にしたものと一致する
  - `$V shot library-select`。スクリーンショットに時刻と発話の文が写る
- 一覧を読み直す
  - ウィンドウを開いたまま、[記録の開始と停止](./recording.md) の「ctl で始める」「発話を流す」「ctl で止める」を通す
  - 新しいセッション名を `<new>` として（`basename "$($V session)"`）、`$V ax tree | grep -c 'AXStaticText value="<new>"'` が 0 を出す
  - `$V ax press "一覧を更新"` の後、`$V ax wait "value=<new>" 5` が `found:` を出す
- 前提知識を開く
  - `$V ax select "前提知識"`、`$V ax wait "value=まだありません。提案を保存すると貯まります。" 5`
  - `$V ax tree` に `候補を集める` と `knowledge.md を開く` の要素が出る
- 閉じる
  - `$V ax press "subrole=AXCloseButton"`、`$V ax wait-gone "OtoLog ライブラリ" 5`
  - `gone: OtoLog ライブラリ` が出る
  - `$V ax popover close`
- パスのコピーとゴミ箱は、この手順では操作しない（Gotchas）

## Gotchas

- 「ライブラリ」はウィンドウを前面に出し、ユーザーが使っているアプリからフォーカスを移す
- 文字起こしの本文は AX ツリーに出ない（時刻だけが出る）。本文はスクリーンショットで確かめる
- `$V ax select` は、その文字列を表示している最初の行を選ぶ
- 「前提知識」は `<run>/config/otolog/knowledge.md` を読む。launch した直後は空
- 「パスをコピー」はユーザーのクリップボードを上書きする
- 「ゴミ箱に入れる」はセッションを `~/.Trash` へ移す。run の外に出るので cleanup では消えない
- 「外部アプリで開く」と「Finder で表示」は、ユーザーの画面に別のアプリのウィンドウを開く
- 閉じるボタンを押した直後は、`$V ax windows` にまだウィンドウが出る（閉じるアニメーションの間）。閉じたかは `$V ax wait-gone` で見る
