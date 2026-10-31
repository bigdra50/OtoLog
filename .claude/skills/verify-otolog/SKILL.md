---
name: verify-otolog
description: OtoLog（macOS のメニューバー常駐の文字起こしアプリ）を、普段使いのインスタンスと設定・許可・保存先を共有しない検証用インスタンスで起動し、制御ソケット（otolog-devtool ctl）、Accessibility、読み上げ音声で実際に操作して、記録・無音での自動停止・ライブラリ・生成の振る舞いを証拠つきで確かめる。アプリの変更が実機で動くかを確かめるとき、記録の不具合を再現するとき、ポップオーバーやライブラリの画面を撮るときに使う。
---

# verify-otolog

OtoLog の検証用インスタンスを起動し、利用者と同じ経路で操作して、結果をファイルとスクリーンショットで残す。
コマンドはリポジトリのルートで実行する。

```bash
V=.claude/skills/verify-otolog/scripts/otolog-verify
```

Bash の呼び出しをまたぐとシェルの変数は消えるので、`V=...` は呼び出しごとに先頭へ書く。
機能ごとの手順は [features/README.md](features/README.md) にある。

## Isolation

| 項目 | 普段使いの OtoLog | 検証用インスタンス |
| --- | --- | --- |
| bundle ID と表示名 | `com.bigdra50.OtoLog`、OtoLog | `com.bigdra50.OtoLog.verify`、OtoLog Verify |
| バンドル | `/Applications` か `~/Applications` の `OtoLog.app` | `~/.local/state/otolog-verify/app/OtoLogVerify.app` |
| 設定（UserDefaults のドメイン） | `com.bigdra50.OtoLog` | `com.bigdra50.OtoLog.verify` |
| 保存先 | 設定の保存先 | `<run>/sessions` |
| 制御ソケット、recording.log、ui.log | `~/.local/state/otolog/` | `<run>/state/otolog/` |
| テンプレート、プレイブック、前提知識、補正辞書 | `~/.config/otolog/` | `<run>/config/otolog/`（空） |
| システム音声の録音の許可（TCC） | `com.bigdra50.OtoLog` の行 | `com.bigdra50.OtoLog.verify` の行 |

`<run>` は `~/.local/state/otolog-verify/runs/<run-id>` を指す。
`$XDG_STATE_HOME` があれば、`~/.local/state` はその値に置き換わる。

共有するものと、その扱い:

- システム音声
  - 検証用インスタンスは、自分以外のすべてのプロセスの音を記録する
  - 普段使いの OtoLog が記録中なら、読み上げの音声はそちらの記録にも入る。`$V say` はそのとき音を流さずに失敗する
- メニューバー
  - 同じ耳のアイコンが 2 つ並ぶ
  - `$V ax` は PID で対象を決めるので、普段使いのアイコンは押さない

してはいけないこと:

- 普段使いの OtoLog を操作しない
  - 既定のソケットへ `otolog-devtool ctl start` や `stop` を送らない。`$V` が普段使いへ送るのは status だけ
  - `pkill OtoLog` や `osascript -e 'quit app "OtoLog"'` を実行しない
- 検証用バンドルを bundle ID `com.bigdra50.OtoLog` のまま起動しない。設定と TCC の許可が普段使いと混ざる
- `Contents/MacOS/OtoLog` をシェルから直接起動しない。TCC の許可がターミナルに付く
- 検証用インスタンスを 2 つ同時に動かさない（`$V launch` が断る）

## Launch

```bash
$V build    # scripts/make-app.sh、otolog-devtool のビルド、検証用バンドルの組み立て、AX ヘルパーのコンパイル
$V launch   # run を作り、設定を書き、open -n -g --env で起動して ready を待つ
```

- build は初回と、ソースを変えた後に実行する。初回は約 1 分、差分が無ければ約 10 秒かかる
  - build は `dist/OtoLog.app` を作り直す。インストール済みの OtoLog は変えない
- launch は設定ドメインを作り直し、次の値を書く
  - 保存先 `<run>/sessions`、聞き取る言語 `ja-JP`、入力 `system`、停止時の自動処理 `none`、翻訳 オフ
  - 無音で自動停止は既定の 30 分のまま
  - `--silence-minutes N` は無音で自動停止するまでの分数を、`--locale ID` は聞き取る言語を変える
- 準備ができたしるしは、launch が出す `otolog-verify: ready: pid=<PID> socket=<path>` の行
  - 検証用のソケットへの `ctl status` が `{"ok":true,"state":"idle"}` を返した時点で出る
  - 20 秒で出なければ launch は失敗する。`<run>/app.log` を読み、doctor を実行する
- launch は run のパスを export 文で出す。後からは `eval "$($V env)"` で読み込める
- アプリは設定を起動時に一度だけ読む。起動後に変えるときは `$V relaunch --silence-minutes 1` のように relaunch に付ける

### システム音声の録音の許可

doctor の tcc 行が WARN のときは、記録を確かめる前に人の操作が要る。

1. `$V ctl start` を実行する
   - 画面に「OtoLog Verify」の許可ダイアログが出る
   - ctl は 15 秒で exit 75 を返し、`$V ctl status` は `preparing` のまま
2. ダイアログの「許可」を押すようユーザーに頼み、押されるまで待つ
   - エージェントはダイアログを押さない。AX でもクリックでも押さない
3. `$V relaunch` で再起動する
   - 許可した直後のプロセスは、recording になっても音を取れない
4. `$V doctor` の tcc 行が OK になったことを確かめる

- 許可は検証用バンドルの cdhash に結び付く
  - ソースとビルド番号（コミット数）が同じなら、build し直しても cdhash は変わらず、許可は残る
  - コミットやソースの変更で cdhash が変わると、もう一度許可が要る
- 拒否したときは doctor が `denied(auth_value=0)` を出す
  - システム設定 > プライバシーとセキュリティ > 画面収録とシステム音声録音 で OtoLog Verify を許可し、`$V relaunch` する
- `OTOLOG_CODESIGN_IDENTITY` に安定した署名 ID を渡して build すると、ビルドが変わっても許可が残る（make-app.sh と同じ変数）

## Doctor

```bash
$V doctor
```

最初に操作する前と、操作が失敗した後に実行する。
doctor は読むだけで、何も変えない。
NG が 1 つでもあれば exit 1 を返す。

| 行 | 確かめること | NG か WARN のとき |
| --- | --- | --- |
| bundle | 検証用バンドルと AX ヘルパーが、今のチェックアウトから作られたか | WARN なら `$V cleanup && $V build && $V launch` |
| bundle id | `com.bigdra50.OtoLog.verify` か | `$V build` |
| devtool | `.build/release/otolog-devtool` があるか | `$V build` |
| run | launch した run があるか | `$V launch` |
| process | 検証用の実行ファイルの PID が 1 つだけで、run の pid と一致するか | `$V cleanup && $V launch` |
| env | そのプロセスの `XDG_STATE_HOME` が run を指すか | `$V cleanup && $V launch` |
| ctl | 検証用のソケットが応答するか | `<run>/app.log` を読み、`$V relaunch` |
| save dir | 設定の保存先が run を指すか | `$V cleanup && $V launch` |
| real OtoLog | 普段使いの OtoLog の状態 | WARN（記録中）なら、終わるまで `$V say` を使わない |
| tcc | TCC.db の許可が今の検証用バンドルに当たるか | 上の「システム音声の録音の許可」 |
| terminal perms | このターミナルの Accessibility と画面収録の許可 | WARN なら `$V ax` と `$V shot` が使えない |
| voice | 読み上げの声があるか（既定 Kyoko） | `OTOLOG_VERIFY_VOICE` で日本語の声を指定する |

- tcc 行は TCC.db を読む。このターミナルにフルディスクアクセスが無いと WARN（unreadable）になる
  - そのときは、確定セグメントが書かれるかで許可の有無を判断する

## Drive

操作の経路は 3 つある。

- 制御ソケット `$V ctl <status|start|stop>`
  - アプリが自動化のために持つ経路で、ポップオーバーの記録ボタンと同じ操作をする
  - 応答は JSON 1 行。exit 0 は ok、1 は ok:false、69 は接続できない、75 は 15 秒で応答が無い
  - exit 75 のとき、アプリは処理を続けていることがある。`$V ctl status` で状態を確かめる
- Accessibility `$V ax <subcommand>`
  - 検証用インスタンスの PID を指定して操作する
  - ボタンは accessibilityLabel（AXDescription）か help で、ポップアップは今の値で、一覧の行は表示中の文字列で指定する
  - 押した後は `$V ax wait` で次の状態を待つ。固定の sleep で待たない
- 読み上げ `$V say "<日本語の文>"`
  - 2 秒待ってからシステム音声で流し、文と時刻を evidence に残す。記録を始めた直後の取りこぼしを避けるため
  - 普段使いの OtoLog が記録中なら、音を流さずに失敗する

`$V ax` のサブコマンド:

| コマンド | 働き |
| --- | --- |
| `popover open`、`popover close` | ポップオーバーを開いた状態か閉じた状態にし、中のボタンが出るまで待つ。今の状態と同じなら何もしない |
| `status-item` | メニューバーのアイコンを押し、ポップオーバーの開閉を切り替える。今の状態が分からないときは popover を使う |
| `press "<label>"` | AXDescription、AXTitle、AXHelp のどれかが一致する最初の要素を押し、押す前の要素を出す |
| `press "value=<値>"` | AXValue が一致する要素を押す（ポップアップを開く） |
| `press "subrole=AXCloseButton"` | ウィンドウの閉じるボタンを押す |
| `select "<文字列>"` | その文字列を表示している一覧の行を選ぶ |
| `wait "<label>" [秒]` | 一致する要素が現れるまで待つ（既定 10 秒）。label は press と同じ書き方 |
| `wait-gone "<label>" [秒]` | 一致する要素が無くなるまで待つ |
| `tree` | AX ツリーを 1 要素 1 行で出す。ラベルを探すときに使う |
| `windows` | 画面上のウィンドウの ID と位置を出す |
| `terminate [秒]` | 通常の終了要求を送り、終わるまで待つ |

ポップオーバーの主なラベル:

| 要素 | 指定のしかた |
| --- | --- |
| 記録ボタン | `記録を開始`、記録中と準備中は `記録を停止`。停止中は `記録を開始` が無効のまま出る |
| 状態の表示 | AXStaticText の値 `待機中`、`準備中`、`記録中`、`停止中`、`エラー`。止め終わったかは `$V ax wait "value=待機中"` で待つ |
| 入力の選択 | help `記録する音源を選ぶ` |
| ツールバー | `ライブラリ`、`最新の記録を開く`、`生成`（開くと `生成を閉じる`）、`設定`（開くと `設定を閉じる`） |

記録して止める最小の手順:

```bash
$V ctl start      # {"ok":true,"sessionPath":"<yyyy-MM-dd>\/<HHmm>","state":"recording"}
$V say "これは OtoLog の検証用の録音です。今日は晴れています。"
$V wait-segment 40
$V ctl stop       # {"ok":true,"sessionPath":"<yyyy-MM-dd>\/<HHmm>","state":"idle"}
$V check-session --end-reason stopped --min-segments 1 --via control
```

- ctl の応答の JSON は `/` を `\/` と書く。文字列で比べるときは `plutil -extract state raw -o - -` で値を取り出す
- 確定セグメントは、読み上げが終わってから 5〜15 秒で transcript.jsonl に書かれる
- 認識結果は読み上げた文と一致しない。英字の固有名詞は崩れる（OtoLog が「トログえ」になる）
  - check-session は、日本語の text があるかで判定する

## Evidence

証拠は `~/.local/state/otolog-verify/evidence/<run-id>/` に置く。
cleanup はここを消さない。

| ファイル | 中身 | 作るコマンド |
| --- | --- | --- |
| `run.txt` | ソースの指紋、git、ビルド番号、cdhash、起動時刻、設定 | launch |
| `ctl.log` | ctl を呼んだ時刻、exit、応答 | ctl、relaunch、cleanup |
| `actions.log` | 読み上げた文と時刻 | say |
| `<name>.ax.txt` と `<name>-<windowID>.png` | AX ツリーと、画面上の各ウィンドウのスクリーンショット | `shot <name>` |
| `snapshot-<label>/` | sessions（transcript.jsonl、transcript.md、meta.json）、recording.log、ui.log、app.log、設定 | `evidence <label>`、cleanup（`snapshot-final`） |

証明の基準:

- 利用者と同じ経路で操作する
  - セッションのファイルを手で作らない
  - 設定は launch と relaunch で、起動する前に書く。動いているアプリの内部は触らない
- 操作と、その結果の状態の両方を残す
  - 画面の状態は `$V shot` で、保存された状態は `$V check-session` と `$V evidence` で残す
- ctl が recording を返しただけでは、記録できた証明にならない
  - TCC の許可が無いと、recording のまま音が入らない
  - 確定セグメントが transcript.jsonl に書かれたことで示す
- `$V check-session` は最新のセッションについて、次の項目を確かめる
  - meta.json の終わり方と終了時刻
  - transcript の行数と、日本語の text があるか
  - recording.log の開始要求、閉じたセッションのパス、最後の `state: idle`
- 証拠の名前に、機能の ID と使った経路（ctl、popover、library）を入れる

## Cleanup

```bash
$V cleanup
```

- 記録が開いていれば ctl stop で閉じ、通常の終了要求で検証用インスタンスを止める。20 秒で終わらなければ SIGTERM を送る
- `snapshot-final` を evidence に作ってから、run のディレクトリと設定ドメイン `com.bigdra50.OtoLog.verify` を消す
- 最後に `evidence: <path>` を出す。cleanup の後もそのパスが残っていることを確かめる
- 検証用バンドル（`app/`）と AX ヘルパー（`bin/`）は残す。cdhash を保ち、TCC の許可を使い続けるため
- 失敗した試行の後も、次の launch の前に cleanup する

すべて消すときは次を実行する。
消した後の記録には、もう一度許可が要る。

```bash
$V cleanup
rm -rf ~/.local/state/otolog-verify/app ~/.local/state/otolog-verify/bin
tccutil reset AudioCapture com.bigdra50.OtoLog.verify
```

`tccutil reset` には検証用の bundle ID を必ず付ける。
付けないと、普段使いの OtoLog を含むすべてのアプリの許可が消える。

## Helpers

| ファイル | 役割 |
| --- | --- |
| `scripts/otolog-verify` | このファイルのコマンドすべて。`$V help` で一覧を出す |
| `scripts/ax.swift` | Accessibility と CGWindow の操作。build が `~/.local/state/otolog-verify/bin/otolog-verify-ax` へコンパイルし、`$V ax` と `$V shot` が呼ぶ。書き換えたら `$V build` し直す（doctor の bundle 行が WARN になる） |

ほかのサブコマンド:

| コマンド | 働き |
| --- | --- |
| `$V wait-segment [秒]` | 最新のセッションの transcript.jsonl に行が書かれるまで待ち、中身を出す（既定 30 秒） |
| `$V session` | 最新のセッション（meta.json の startedAt が最も新しいもの）のディレクトリを出す |
| `$V check-session [--end-reason R] [--min-segments N] [--via control\|popover]` | 最新のセッションを確かめ、PASS か FAIL を行ごとに出す。FAIL があれば exit 1 |
| `$V shot <name>` | AX ツリーと、検証用インスタンスの画面上のウィンドウを evidence に保存する |
| `$V evidence [label]` | sessions、ログ、設定を `snapshot-<label>/` にコピーする |
| `$V relaunch [--silence-minutes N] [--locale ID]` | 同じ run のまま再起動する |
| `$V env` | run のパスと `OTOLOG_CONTROL_SOCKET` を export 文で出す |

`OTOLOG_VERIFY_ROOT` は `~/.local/state/otolog-verify` を、`OTOLOG_VERIFY_VOICE` は読み上げの声を変える。
制御ソケットのパスが 104 バイトを超える置き場では、launch が失敗する。
