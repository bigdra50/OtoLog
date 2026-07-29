import SwiftUI

// MARK: - IconButton

/// アイコンだけのボタン。文言は tooltip と VoiceOver へ回し、ポップオーバーの文字量を抑える。
struct IconButton: View {
    // MARK: Internal

    enum Tone {
        case neutral
        case accent
        /// 中断・取り消し。常時赤だと画面が騒がしいので、赤はホバー時だけ出す
        case destructive
    }

    let systemImage: String
    let label: String
    var tone = Tone.neutral
    /// トグルとして使うとき、オン状態を色と背景で示す
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(foreground)
                .background(background, in: Self.shape)
                .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    // MARK: Private

    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.tertiary) }
        if isOn { return AnyShapeStyle(.tint) }
        switch tone {
        case .neutral: return AnyShapeStyle(isHovering ? .primary : .secondary)
        case .accent: return AnyShapeStyle(.tint)
        case .destructive: return isHovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
        }
    }

    private var background: AnyShapeStyle {
        if isOn { return AnyShapeStyle(.tint.opacity(0.15)) }
        guard isEnabled, isHovering else { return AnyShapeStyle(.clear) }
        return tone == .destructive ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.quaternary)
    }
}

// MARK: - RecordButton

/// 記録の開始/停止。ポップオーバー内で唯一の主役なので円形の塗りで置く。
struct RecordButton: View {
    // MARK: Internal

    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint), in: Circle())
                .scaleEffect(isHovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isRecording)
    }

    // MARK: Private

    @State private var isHovering = false

    private var label: String {
        isRecording ? "記録を停止" : "記録を開始"
    }
}

// MARK: - View + panel

extension View {
    /// ポップオーバー内で開閉するパネル（生成・設定）の共通の器。
    func panelBackground() -> some View {
        padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}
