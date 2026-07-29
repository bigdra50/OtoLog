import Foundation
import Speech

extension AssetInventory {
    /// ロケールを冪等に予約する。既存予約は壊さず、上限到達時のみ1つ解放する。
    ///
    /// 「全予約解除→再予約」を毎回行うと macOS のアセット管理が混乱し、直後の
    /// `downloadAndInstall()` が CancellationError で失敗する
    /// (https://github.com/finnvoor/yap/issues/32)。その回避策として必須のパターンで、
    /// 全予約解除のコードをここ以外に書かないこと。
    static func ensureReserved(locale: Locale) async throws {
        let reserved = await reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        if reserved.count >= maximumReservedLocales, let localeToRelease = reserved.first {
            await release(reservedLocale: localeToRelease)
        }
        try await reserve(locale: locale)
    }
}
