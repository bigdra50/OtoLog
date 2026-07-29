import Foundation

/// 1記録セッション分の transcripts を保存するストア。
/// begin → append… → finalize のライフサイクルで、セッションの置き場所はストアが決める。
public protocol TranscriptStore: Sendable {
    /// セッションの保存先を確保する。append より先に1回呼ぶ
    func begin(context: TranscriptionContext) async throws

    func append(_ segment: TranscriptSegment) async throws

    /// セッションを閉じ、保存済みセッションへの参照を返す。begin していなければ nil
    func finalize(endedAt: Date) async throws -> SessionRef?
}
