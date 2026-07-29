import Foundation

// MARK: - GenerationTemplate

/// 後処理生成のテンプレート。
/// id は生成物ファイル名（<stem>.<id>.md）とユーザー定義ファイル名（<id>.md）に使う。
public struct GenerationTemplate: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(id: String, displayName: String, instructions: String, isBuiltIn: Bool) {
        self.id = id
        self.displayName = displayName
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }

    // MARK: Public

    public let id: String
    public let displayName: String
    public let instructions: String
    public let isBuiltIn: Bool
}

// MARK: - BuiltInTemplates

/// 組み込みテンプレート。正本はこの定数で、スキル同梱の md は TemplateExporter による書き出し。
/// SwiftPM の resource bundle は make-app.sh が扱わないため、文字列定数で持つ。
public enum BuiltInTemplates {
    // MARK: Public

    public static let all: [GenerationTemplate] = [
        correct, minutes, lecture, digest,
        summary, glossary, references, qa, repro, share, actions, followup,
    ]

    // MARK: Internal

    static let correct = GenerationTemplate(
        id: "correct",
        displayName: "誤認識の補正",
        instructions: """
        文字起こしログの誤認識を修正する。
        - 発話の順序・内容・分量を保つ。要約・省略・追記・創作をしない
        - 全体の文脈から明らかな誤認識・誤変換（同音異義語の誤り、固有名詞の崩れ、助詞の欠落など）だけを直す
        - 判断に迷う箇所は原文のまま残す
        - 入力と同じ「[HH:mm:ss] 本文」の行構造を維持して全行を出力する
        """,
        isBuiltIn: true
    )

    static let minutes = GenerationTemplate(
        id: "minutes",
        displayName: "議事録",
        instructions: """
        文字起こしログを議事録に整理する。
        - 冒頭に3行以内の全体サマリを置く
        - 議題ごとに見出しを立て、話し合われた内容を箇条書きで整理する
        - 「決定事項」「未決の論点」「TODO」を分けて書く。担当・期限はログ内で言及がある場合のみ添える
        - ログに無い事実を補わない
        """,
        isBuiltIn: true
    )

    static let lecture = GenerationTemplate(
        id: "lecture",
        displayName: "講義ノート",
        instructions: """
        文字起こしログを講義ノートに整理する。
        - 内容を見出し階層で構造化する
        - 重要用語は太字にし、ログ内の説明に基づく短い定義を添える
        - 箇条書き中心で、例・数値はログから正確に引き写す
        - 末尾に「復習ポイント」節を置き、理解を確認する問いを3〜5個書く
        """,
        isBuiltIn: true
    )

    static let digest = GenerationTemplate(
        id: "digest",
        displayName: "ダイジェスト",
        instructions: """
        文字起こしログをその日のダイジェストに要約する。
        - 時系列のトピック単位で全体を5〜10行にまとめる
        - 各行の先頭にトピックの開始時刻 [HH:mm] を付ける
        - 固有名詞・数値は正確に保持する
        """,
        isBuiltIn: true
    )

    static let summary = GenerationTemplate(
        id: "summary",
        displayName: "要約",
        instructions: """
        文字起こしログを要約する。
        - 冒頭に全体要旨を3〜5行でまとめる
        - 「主なポイント」節に重要な論点を箇条書きで整理する
        - 「特に印象的だった点」節に、具体例・数値・独自の主張など聞き手に刺さる箇所を挙げる
        - 固有名詞・数値は正確に保持する
        """,
        isBuiltIn: true
    )

    static let glossary = GenerationTemplate(
        id: "glossary",
        displayName: "用語集",
        instructions: """
        文字起こしログから専門用語・技術名を抽出し、用語集を作る。
        - 用語ごとに「ログ内での文脈（どう使われたか）」と「正確な定義」を書く
        - 定義は Web 検索で確認し、参照した URL を添える
        - 音声認識による表記の揺れ・誤りは正しい表記に直して見出しにする
        - 一般的すぎる語は含めず、この内容の理解に効く用語に絞る
        """,
        isBuiltIn: true
    )

    static let references = GenerationTemplate(
        id: "references",
        displayName: "参考資料集",
        instructions: """
        文字起こしログで言及されたリソース（ツール、ライブラリ、論文、書籍、サービス）を洗い出し、リンク集を作る。
        - 各リソースについて Web 検索で公式ページや原典を特定し、実在する URL を添える
        - 「ログ内でどう言及されたか」を1行で添える
        - 特定できなかったものは「未特定」節に分けて残す（URL を創作しない）
        """,
        isBuiltIn: true
    )

    static let qa = GenerationTemplate(
        id: "qa",
        displayName: "質疑応答の抽出",
        instructions: """
        文字起こしログから質疑応答を抽出する。
        - 質問と回答のペアを「Q:」「A:」形式で時系列に整理する
        - 質疑が無い場合は「質疑応答は記録されていません」とだけ出力する
        - 発言の要旨を保ち、冗長な言い回しだけを整える
        """,
        isBuiltIn: true
    )

    static let repro = GenerationTemplate(
        id: "repro",
        displayName: "追試検討",
        instructions: """
        文字起こしログで説明された技術・手法を追試（再現）するための検討資料を作る。
        - 「再現対象」節で何を再現するのかを明確にする
        - 「必要な環境・前提」節に、必要なツール・ハードウェア・スキルを挙げる（Web 検索で入手可能性を確認する）
        - 「手順の再構成」節で、ログの説明から実施手順を段階的に組み立てる。ログに無い部分は［要調査］と明示する
        - 「実現可能性の評価」節で、難易度・所要時間・不確実な点を評価する
        """,
        isBuiltIn: true
    )

    static let share = GenerationTemplate(
        id: "share",
        displayName: "共有パッケージ",
        instructions: """
        文字起こしログを、参加していない人に共有するための資料にまとめる。
        - 冒頭に「何のセッションか」「なぜ読む価値があるか」を2〜3行で書く
        - 前提知識が要る箇所には短い補足を添える
        - 依存タスクの結果（要約・用語集・参考資料）が与えられていれば、その内容を統合して自己完結した1枚にする
        - 読み手が次に取れるアクション（試す・調べる・視聴する）を末尾にまとめる
        """,
        isBuiltIn: true
    )

    static let actions = GenerationTemplate(
        id: "actions",
        displayName: "アクションアイテム",
        instructions: """
        文字起こしログからアクションアイテムを抽出する。
        - 「やること」をチェックリスト形式（- [ ]）で列挙する
        - ログ内で言及がある場合のみ担当者・期限を添える
        - 決定に基づくものと提案止まりのものを分けて整理する
        - ログに無いタスクを創作しない
        """,
        isBuiltIn: true
    )

    static let followup = GenerationTemplate(
        id: "followup",
        displayName: "フォローアップ下書き",
        instructions: """
        文字起こしログ（会議）のフォローアップ連絡の下書きを作る。
        - 宛先は会議の参加者を想定し、簡潔な挨拶から始める
        - 決定事項とアクションアイテム（依存タスクの議事録が与えられていればそれを基に）を要約する
        - 次回への持ち越し事項と依頼事項を明記する
        - そのまま送れる完成度のメール/チャット文面にする
        """,
        isBuiltIn: true
    )
}
