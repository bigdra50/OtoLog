---
name: otolog-generate
description: OtoLog の記録セッション（transcript.jsonl）をテンプレートに従って Markdown 生成物へ後処理する。「議事録にして」「さっきの講演を要約して」「タイトルを付けて」等、OtoLog の記録を加工したいときに使う。
---

# OtoLog ログ生成

OtoLog が記録したセッションを読み、テンプレートに従って生成物を書き出す。
アプリのポップオーバー「生成」と同じテンプレート定義・出力先・ヘッダ規約を使うため、どちらで生成しても等価な成果物になる（相互に上書き・再生成できる）。

## 保存構造

```
<saveDirectory>/
  2026-07-29/                  # 日付フォルダ
    ボクセル技術講演/           # セッション（タイトル名。未タイトルは HHmm、同日重複は -2 連番）
      transcript.jsonl         # 正本（1行1セグメントの JSON）
      transcript.md            # 表示用
      meta.json                # title / startedAt / endedAt / sessionID など
      <テンプレートID>.md       # 生成物
  2026-07-29_1703_旧形式/      # 旧フラット構造（読み取り互換で残っている場合がある）
  briefs/                      # 事前ブリーフ（セッションに紐付かない）
```

## 手順

1. 保存ディレクトリを特定する
   - `defaults read com.bigdra50.OtoLog saveDirectoryPath`（チルダは展開する）
   - 読めなければ既定 `~/Documents/OtoLog`。それも無ければユーザーに確認する
2. 対象セッションを特定する
   - 直下のセッションディレクトリを列挙し、meta.json の title / startedAt で選ぶ
   - 「さっきの」「今日の」のような指定は startedAt が最新のセッション
3. `<sessionDir>/transcript.jsonl` を読む
   - 1行が1つの JSON（text / finalizedAt ほか）。壊れた行はスキップする
   - `finalizedAt`（ISO8601 UTC）をローカル時刻に変換し、時系列の `[HH:mm:ss] text` 行としてログを組み立てる（text 内の改行は空白1個に潰す）
4. テンプレートを解決する（この順で最初に見つかったもの）
   1. `~/.config/otolog/templates/<id>.md`（ユーザー定義。同 id は組み込みより優先）
   2. このスキル同梱の `templates/<id>.md`（組み込み: correct / minutes / lecture / digest）
   - 形式: 最初の `# 見出し` が表示名、残り全部が生成指示
   - ユーザーが自由な指示を出した場合はテンプレートなしでその指示に従ってよい
5. 生成指示に従ってログを変換する
   - 結果の Markdown 本文のみを書く。前置き・説明・コードフェンス包みは禁止
   - ログに無い事実を創作しない。言語はログ本文に合わせる
6. `<sessionDir>/<id>.md` へ書き出す（既存があれば上書き）
   - テンプレートなしの自由指示の場合は `<id>` の代わりに内容を表す短い英小文字スラッグを使う
   - 先頭に必ず由来ヘッダを付ける:
     `<!-- otolog:generated template=<id> source=transcript.jsonl generatedAt=<ISO8601> -->`

## タイトル付与を頼まれた場合

1. ログの冒頭・末尾から内容を表す 15 文字程度のタイトルを決める（記号・括弧なし）
2. meta.json の `title` を更新する
3. ディレクトリを `<yyyy-MM-dd_HHmm 部分はそのまま>_<タイトル>` にリネームする（`/ : \\ 空白` はハイフンへ）
4. transcript.md の先頭見出しを `# <タイトル>` に差し替える

## パイプライン成果物

アプリのプレイブック実行は複数の生成物（summary.md / glossary.md / share.md 等）をセッションディレクトリへ書き、実行状態を meta.json の `pipeline` に記録する。
これらも同じ由来ヘッダ規約の派生物で、上書き・再生成してよい。

## 注意

- `transcript.jsonl` は不変の正本。編集・削除しない
- 生成物のファイル名・ヘッダ規約はアプリの生成機能と互換に保つ
- 記録中のセッション（meta.json に endedAt が無い）を対象にすると途中までの内容で生成される。必要ならユーザーに伝える
- `YYYY-MM-DD.jsonl.bak` などの .bak は旧形式の退避ファイル。触らない
