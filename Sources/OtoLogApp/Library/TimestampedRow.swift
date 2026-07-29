import SwiftUI

/// 時刻 + 本文の1行表示（文字起こしビューと補正ログビューで共用）。
struct TimestampedRow: View {
    let time: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
