# 記録の開始と停止

利用者はポップオーバーの記録ボタンか `otolog-devtool ctl` で記録を始め、止めるまでシステム音声の発話を文字起こしして保存する。
確定した発話は `<保存先>/<yyyy-MM-dd>/<HHmm>/` の transcript.jsonl と transcript.md に書かれ、止めると meta.json に終わり方が入る。
開始から閉じるまでの経緯は recording.log に残る。

## Sub-features

- `record-start-ctl` ctl start で記録を始め、recording を返す
- `record-start-popover` ポップオーバーの「記録を開始」で記録を始める
- `record-reject-double-start` 記録中の ctl start を ok:false で断る
- `record-live` 記録中のポップオーバーに「記録中」と、確定した発話の文が出る
- `record-segment` 確定した発話が transcript.jsonl と transcript.md に書かれる
- `record-stop-ctl` ctl stop でセッションを閉じ、meta.json の endReason を stopped にする
- `record-stop-popover` 「記録を停止」でセッションを閉じる
- `record-close-on-quit` 記録中にアプリを終了すると、記録を閉じてから終わる
- `record-status` ctl status が状態と最新のセッションを返す
- `record-log` recording.log に開始要求、状態の遷移、閉じたセッションのパスが残る

状態（ctl status の state）と遷移:

| 状態 | 移れる先 |
| --- | --- |
| `idle` | `preparing` |
| `preparing` | `recording`、`stopping`、`failed` |
| `recording` | `stopping` |
| `stopping` | `idle`、`failed` |
| `failed` | `preparing` |

## How to get to it (user POV)

- メニューバーの耳のアイコンを押してポップオーバーを開き、右上の丸いボタン（「記録を開始」「記録を停止」）を押す
- ターミナルで `otolog-devtool ctl start`、`ctl stop`、`ctl status` を実行する
- 記録中に、ログアウト、シャットダウン、quit の Apple Event でアプリを終了する

## Driving it with otolog-verify

Preconditions:

- [README](./README.md) の Baseline preconditions を満たす
- `$V ctl status` が `"state":"idle"` を返す

- ctl で始める
  - `$V ctl start`
  - exit 0 と `{"ok":true,"sessionPath":"<yyyy-MM-dd>\/<HHmm>","state":"recording"}` が返る
- 二重の開始を断る
  - 記録中にもう一度 `$V ctl start`
  - exit 1 と、`"error":"既に記録中です"`、`"ok":false`、`"state":"recording"` を含む JSON が返る
- 発話を流す
  - `$V say "これは OtoLog の検証用の録音です。今日は晴れています。"`
  - `$V wait-segment 40` が、`"source":"system"` と日本語の `"text"` を含む JSON 行を出す
- ライブ字幕を撮る
  - `$V ax popover open`、`$V ax wait "記録を停止" 5`、`$V shot record-live-ctl`、`$V ax popover close`
  - スクリーンショットに「記録中」、赤い停止ボタン、灰色になった入力欄、確定した発話の文が写る
- ctl で止める
  - `$V ctl stop`
  - exit 0 と `"state":"idle"` が返る
  - `$V check-session --end-reason stopped --min-segments 1 --via control` の 8 行がすべて PASS
- ポップオーバーで始めて止める
  - `$V ax popover open`、`$V ax press "記録を開始"`、`$V ax wait "記録を停止" 15`
  - `$V ctl status` が `"state":"recording"` を返す
  - 発話を流して `$V wait-segment 40` の後に、`$V ax press "記録を停止"`、`$V ax wait "value=待機中" 15`、`$V ax popover close`
  - `$V check-session --end-reason stopped --min-segments 1 --via popover` の 8 行がすべて PASS
- 終了で閉じる
  - `$V ctl start` で始め、発話を流して `$V wait-segment 40` の後に `$V ax terminate 20`
  - `terminated: <PID>` が出る
  - `$V check-session --end-reason stopped --min-segments 1 --via control` の 8 行がすべて PASS
  - 続けて操作するときは `$V relaunch` で起動し直す
- 証拠を残す
  - `$V evidence recording`
  - `snapshot-recording/sessions/<yyyy-MM-dd>/` の下に、セッションごとの transcript.jsonl、transcript.md、meta.json がある

## Gotchas

- ctl が recording を返しても、TCC の許可が無ければ音は入らない
  - wait-segment が時間切れになったら、doctor の tcc 行を見る
- 許可した直後のプロセスは、recording になっても無音のまま
  - そのプロセスでは、閉じるのに 90 秒かかった例がある
  - 許可したら relaunch してから記録する
- 許可ダイアログが出ている間、ctl start は exit 75 を返し、state は preparing のまま
- 認識結果は読み上げた文と一致しない
  - 英字の固有名詞は崩れる（OtoLog が「トログえ」に、ポップオーバーが「トップオーバー」になる）
  - 判定は check-session の「日本語の text があるか」で行う
- 検証用インスタンスは、ユーザーが再生している音も記録する
  - 動画や会議の音が流れていると、読み上げ以外の行が増える
- 止め忘れた記録は、無音で自動停止するまで続く（launch の既定は 30 分）
- ポップオーバーは、ほかの場所をクリックすると閉じる
  - `$V ax popover open` は閉じていれば開き直すので、押す前に毎回呼んでよい
- 停止中（stopping）の記録ボタンは、無効のまま `記録を開始` と出る
  - `$V ax wait "記録を開始"` は止め終わる前に返る。止め終わりは `$V ax wait "value=待機中"` で待つ
- 「最新の記録を開く」は transcript.md を既定のアプリで開き、ユーザーの画面にウィンドウが増える
- マイクを含む入力（システム音声 + マイク、マイクのみ）は、この手順では確かめていない
  - 検証用の bundle ID には、マイクの許可が別に要る
- 記録中の終了では、アプリは閉じ終わるのを最大 15 秒待ってから終わる
