import Foundation

/// 複数ロケールで並行認識しているあいだの裁定。
///
/// 話者の言語が決まるまで確定セグメントを溜め、決まった時点で勝者の分だけを順に放出する。
/// 判定には数秒〜十数秒かかる（実測で英語 4.2 秒・日本語 12.3 秒）ので、
/// 保留しないとその間の発話がまるごと落ちる。
struct LanguageArbiter {
    // MARK: Lifecycle

    /// candidates の先頭は判定できなかったときの落としどころになる。
    /// 候補が1つなら並行認識自体が不要なので、最初から決定済みとして扱う
    init(candidates: [String]) {
        self.candidates = candidates
        decidedLocale = candidates.count == 1 ? candidates.first : nil
    }

    // MARK: Internal

    private(set) var decidedLocale: String?

    /// 確定セグメントを受け取り、書き出してよいものを返す。
    /// 未決定なら空（溜める）、決定した瞬間は溜めた分をまとめて返す
    mutating func accept(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        if let decidedLocale {
            return segment.locale == decidedLocale ? [segment] : []
        }
        backlog[segment.locale, default: []].append(segment)
        texts[segment.locale, default: ""] += segment.text
        return decideNow()
    }

    /// 途中経過を受け取り、表示すべきテキストを返す。
    /// 未決定のあいだは最も長い結果を出している認識器のものを見せる（それらしく見えるため）
    mutating func acceptVolatile(text: String, locale: String) -> String? {
        if let decidedLocale {
            return locale == decidedLocale ? text : nil
        }
        volatiles[locale] = text
        // volatile も判定材料に混ぜる。確定を待つと字幕がその分遅れる
        let merged = candidates.map { (locale: $0, text: (texts[$0] ?? "") + (volatiles[$0] ?? "")) }
        if let winner = LanguageDecider.decide(merged) {
            settle(on: winner)
            return volatiles[winner]
        }
        return volatiles.values.max { $0.count < $1.count }
    }

    /// 入力終了。決まらないままなら候補の先頭で確定させ、溜めた分を落とさず出す
    mutating func flush() -> [TranscriptSegment] {
        if decidedLocale != nil { return [] }
        guard let fallback = candidates.first else { return [] }
        return settle(on: fallback)
    }

    // MARK: Private

    private let candidates: [String]
    private var backlog: [String: [TranscriptSegment]] = [:]
    private var texts: [String: String] = [:]
    private var volatiles: [String: String] = [:]

    private mutating func decideNow() -> [TranscriptSegment] {
        let merged = candidates.map { (locale: $0, text: (texts[$0] ?? "") + (volatiles[$0] ?? "")) }
        guard let winner = LanguageDecider.decide(merged) else { return [] }
        return settle(on: winner)
    }

    @discardableResult private mutating func settle(on locale: String) -> [TranscriptSegment] {
        decidedLocale = locale
        let flushed = backlog[locale] ?? []
        backlog.removeAll()
        texts.removeAll()
        volatiles = volatiles.filter { $0.key == locale }
        return flushed
    }
}
