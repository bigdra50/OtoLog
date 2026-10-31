# OtoLog verification map

OtoLog の利用者から見える振る舞いを確かめる手順の一覧。
操作する前にこの索引を読み、該当する機能のファイルを手順として使う。
コマンドの `$V` は `.claude/skills/verify-otolog/scripts/otolog-verify` を指す（[SKILL.md](../SKILL.md)）。

## Baseline preconditions

- `$V build` と `$V launch` で、検証用インスタンスを起動している
- `$V doctor` に NG が無く、tcc 行が OK
  - tcc 行が WARN なら、SKILL.md の「システム音声の録音の許可」を先に済ませる
- launch した直後の保存先 `<run>/sessions` は空
- doctor の real OtoLog 行が `idle` か `absent`
- doctor の terminal perms 行が、Accessibility と画面収録の両方で true
- このインスタンスは、この検証の launch で起動したもの。ほかの run が起動したインスタンスは操作しない

## Driving conventions

- 手順は baseline の状態から始める。違う状態から始める手順は、その Preconditions に書く
- ポップオーバーとライブラリは `$V ax` で、ラベル（AXDescription、help、表示中の値）を指定して操作する。座標は使わない
- 押した後は `$V ax wait` で次の状態を待つ。固定の sleep で待たない
- コマンドは書いてあるとおりに打つ。引用符の中のラベルを変えない
- 記録を始めたら、手順の終わりに必ず止める
- ポップオーバーは `$V ax popover open` で開き、手順の終わりに `$V ax popover close` で閉じる
  - `$V ax status-item` は開閉を切り替えるだけなので、今の状態とずれると逆の操作になる
- ポップオーバーで止めた後は、`$V ax wait "value=待機中" 15` で止め終わるのを待つ
  - 停止中も記録ボタンのラベルは `記録を開始` になるので、ラベルでは待てない

## Proof and skip reporting

- 操作と、その結果の状態を残す。最後の画面だけでは足りない
- 画面の証拠は `$V shot <name>`（AX ツリーとスクリーンショットの組）で残す
- 記録の証拠は `$V check-session` の出力と、`$V evidence <label>` の snapshot で残す
- 証拠の名前に、機能の ID と使った経路を入れる
- 届かなかった経路は、試したコマンドと、満たせなかった前提を書いて報告する
- 別の経路で確かめた結果を、届かなかった経路の結果として報告しない

## Feature entry contract

各ファイルは H1 の題と、利用者から見える振る舞いを書いた 1 段落で始まり、次の 4 つの H2 をこの順で持つ。

1. `Sub-features` 短い ID と、振る舞いの 1 行の説明
2. `How to get to it (user POV)` 利用者が操作する場所のすべて
3. `Driving it with otolog-verify` `Preconditions:` から始め、操作、コマンド、観察できる結果を組にして並べる
4. `Gotchas` 検証の時間を無駄にしたり、結果を無効にしたりする事柄

実装の内部は書かない。
書くのは利用者の経路、ラベル、必要な状態、コマンド、観察できる証拠だけ。

## Features

- [記録の開始と停止](./recording.md)
  - ctl とポップオーバーの記録ボタン、二重の開始、終了で閉じる記録、状態の遷移、保存されるファイル
- [無音での自動停止](./silence-auto-stop.md)
  - 無音が続いたときの停止、meta.json の終わり方、ポップオーバーの知らせ、設定の画面
- [ライブラリ](./library.md)
  - セッションの一覧と選択、文字起こしの表示、一覧の読み直し、前提知識、ウィンドウを閉じる
- [生成](./generation.md)
  - テンプレートとプレイブックの選択、生成の実行、タイトル生成
  - 実行は claude CLI を呼び、ユーザーの課金か利用枠を使う
