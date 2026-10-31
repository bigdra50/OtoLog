# 無音での自動停止

記録中に、文字か数字を含む文字起こしが設定の時間だけ届かないと、アプリが記録を止める。
止め方は停止ボタンと同じで、meta.json の endReason は autoStopped になる。
ポップオーバーには止めた時刻の知らせが出て、次の記録を始めるまで残る。

## Sub-features

- `autostop-fire` 無音が設定の分数続くと止まる（判定は 15 秒ごと）
- `autostop-meta` meta.json の endReason が autoStopped になり、endedAt が入る
- `autostop-log` recording.log に `auto-stopped: silence for <N>m` が出て、`state: stopping`、`session finished: <path>`、`state: idle` が続く
- `autostop-notice` ポップオーバーに「無音が<N>分続いたため <HH:mm> に自動停止しました」が出る
- `autostop-notice-clear` 次の記録を始めると、知らせが消える
- `autostop-setting` 設定の「無音で自動停止」で、オフ、10分、15分、30分、60分から選ぶ（次の記録から反映）

## How to get to it (user POV)

- 記録を始めて、何も話さずに置いておく
- ポップオーバーの「設定」を開き、「無音で自動停止」のポップアップで時間を選ぶ

## Driving it with otolog-verify

Preconditions:

- 判定を 1 分にして起動している
  - 新しい run なら `$V launch --silence-minutes 1`
  - 動いている run なら `$V relaunch --silence-minutes 1`
- 検証用インスタンスは idle
- 歌詞や台詞のある音が、システム音声で流れていない

- 記録して待つ
  - `$V ctl start` が `"state":"recording"` を返す
  - 何も流さずに、`$V ctl status` を 5 秒おきに呼ぶ。60〜75 秒で `"state":"idle"` になる
- 終わり方を確かめる
  - `$V check-session --end-reason autoStopped --min-segments 0 --via control` の 6 行がすべて PASS
  - `eval "$($V env)"; grep 'auto-stopped: silence for 1m' "$OTOLOG_VERIFY_LOG"` が、この run で自動停止した回数ぶんの行を出す
- 知らせを確かめる
  - `$V ax popover open`、`$V ax wait "value=待機中" 5`、`$V ax tree | grep 自動停止しました`
  - `AXStaticText value="無音が1分続いたため <HH:mm> に自動停止しました"` が出る
  - `$V shot autostop-notice`
- 知らせが消える
  - `$V ax press "記録を開始"`、`$V ax wait "記録を停止" 15`
  - `$V ax tree | grep -c 自動停止しました` が 0 を出す
  - `$V ax press "記録を停止"`、`$V ax wait "value=待機中" 15`
- 設定の画面を確かめる
  - `$V ax popover open`、`$V ax press "設定"`、`$V ax wait "設定を閉じる" 5`
  - `$V ax tree | grep 文字起こしされる発話` が「無音で自動停止」のポップアップを出す
  - 1 分で起動した run では、その行に value が無い。30 分（launch の既定）で起動した run では value が `30分` になる
  - `$V ax press "設定を閉じる"`、`$V ax popover close`

## Gotchas

- 分数はアプリの起動時に読まれる。動いている間に defaults を書き換えても反映されない
- 設定の画面の選択肢は 10 分から
  - 1 分は `--silence-minutes` でだけ設定でき、そのときポップアップは値を表示しない
- 判定は 15 秒ごとなので、止まるのは設定の時間から最大 15 秒遅れる
- 無音は音量ではなく文字起こしで判定する。歌詞のある BGM や動画の台詞が流れていると止まらない
- 発話が 1 件も無いまま止まったセッションには、transcript.jsonl と transcript.md が無く、meta.json だけが残る
- 発話が無いと、停止時の自動処理は走らない。launch は停止時の自動処理を none にするので、この手順では確かめない
