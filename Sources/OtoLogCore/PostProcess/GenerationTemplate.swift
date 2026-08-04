import Foundation

// MARK: - GenerationTemplate

/// 後処理生成のテンプレート。
/// id は生成物ファイル名（<stem>.<id>.md）とユーザー定義ファイル名（<id>.md）に使う。
public struct GenerationTemplate: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(
        id: String,
        displayName: String,
        instructions: String,
        isBuiltIn: Bool,
        jsonSchema: String? = nil,
        allowsWebResearch: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.jsonSchema = jsonSchema
        self.allowsWebResearch = allowsWebResearch
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }

    // MARK: Public

    public let id: String
    public let displayName: String
    public let instructions: String
    public let isBuiltIn: Bool
    /// 構造化出力のスキーマ。機械が後で使う生成物にだけ与える
    /// （議事録や要約は自由記述のほうが質が出るので付けない）
    public let jsonSchema: String?
    /// 単発生成でも Web 検索を許すか。
    /// 「定義は Web 検索で確認し」と指示しているテンプレートを検索なしで走らせても指示どおりに動かない
    public let allowsWebResearch: Bool
}

// MARK: - BuiltInTemplates

/// 組み込みテンプレート。正本はこの定数で、スキル同梱の md は TemplateExporter による書き出し。
/// SwiftPM の resource bundle は make-app.sh が扱わないため、文字列定数で持つ。
public enum BuiltInTemplates {
    // MARK: Public

    public static let all: [GenerationTemplate] = [
        correct, minutes, lecture, digest,
        summary, glossary, references, qa, repro, share, actions, followup, situation,
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
        - 重要用語は見出しを立て、ログ内の説明に基づく短い定義を添える
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
        文字起こしログから専門用語・技術名を抽出し、用語集を JSON で出力する。
        - term は用語そのもの。分類やカテゴリ（「AI関連」など）を term にしない
        - context はログ内でどう使われたかを1〜2文で
        - definition は一般的な定義を1〜2文で。前提知識として持ち回るので簡潔にする
        - definition は Web 検索で確認し、参照した URL を reference に入れる。http(s) で始まる実在の URL のみ。確認できなければ reference を省く
        - 音声認識による表記の揺れ・誤りは正しい表記に直して term にする
        - 一般的すぎる語は含めず、この内容の理解に効く用語に絞る
        """,
        isBuiltIn: true,
        jsonSchema: glossarySchema,
        allowsWebResearch: true
    )

    /// 用語集の構造化出力スキーマ。
    /// definition に上限を置くのは、前提知識として毎回プロンプトへ乗るため
    static let glossarySchema = """
    {"type":"object","properties":{"terms":{"type":"array","items":{"type":"object",    "properties":{"term":{"type":"string","maxLength":60},    "context":{"type":"string","maxLength":200},    "definition":{"type":"string","maxLength":200},    "reference":{"type":"string"}},    "required":["term","context","definition"],"additionalProperties":false}}},    "required":["terms"],"additionalProperties":false}
    """

    static let references = GenerationTemplate(
        id: "references",
        displayName: "参考資料集",
        instructions: """
        文字起こしログで言及されたリソース（ツール、ライブラリ、論文、書籍、サービス）を洗い出し、リンク集を作る。
        - 各リソースについて Web 検索で公式ページや原典を特定し、実在する URL を添える
        - 「ログ内でどう言及されたか」を1行で添える
        - 特定できなかったものは「未特定」節に分けて残す（URL を創作しない）
        """,
        isBuiltIn: true,
        allowsWebResearch: true
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
        isBuiltIn: true,
        allowsWebResearch: true
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
        文字起こしログからアクションアイテムを抽出し、JSON で出力する。
        - task は「やること」を1文で
        - owner・due はログ内で言及がある場合のみ入れる。言及が無ければ省く（推測して埋めない）
        - at は発言時刻 [HH:mm:ss] の時刻部分。どこで決まったか辿れるようにする
        - decided は決定に基づくものだけ true。提案・検討止まりは false
        - ログに無いタスクを創作しない
        """,
        isBuiltIn: true,
        jsonSchema: actionsSchema
    )

    /// アクションアイテムの構造化出力スキーマ。
    /// 完了チェックや外部への書き出しに使うので、型を固定する
    static let actionsSchema = """
    {"type":"object","properties":{"actions":{"type":"array","items":{"type":"object",\
    "properties":{"task":{"type":"string","maxLength":200},\
    "owner":{"type":"string","maxLength":40},\
    "due":{"type":"string","maxLength":40},\
    "at":{"type":"string","pattern":"^[0-9]{2}:[0-9]{2}:[0-9]{2}$"},\
    "decided":{"type":"boolean"}},\
    "required":["task"],"additionalProperties":false}}},\
    "required":["actions"],"additionalProperties":false}
    """

    static let situation = GenerationTemplate(
        id: "situation",
        displayName: "現況メモの更新",
        instructions: """
        「現在の現況メモ」を、今回のログで分かったことを踏まえて更新し、更新後の全文を出力する。
        - 主題（人・案件・プロジェクト）ごとに `##` 見出しを立てて書く
        - 今回のログで触れられた主題だけを書き換える。触れられていない主題は現在の記述をそのまま残す
        - 新しく出てきた主題は追加する
        - 各主題の末尾に `（YYYY-MM-DD 時点）` を添える。日付はセッションの開始日
        - 状態・関係・温度感など、型にはめられない事柄を短く書く。用語の定義は書かない
        - 完了したこと・終わった案件は削らず「完了」と分かる形で残す
        - 現在の現況メモが空なら、今回のログから分かる範囲で新規に書く
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
