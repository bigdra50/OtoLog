import AppKit
import OtoLogCore

/// メニューバーアイコンの状態表示とフレームアニメーション。
/// SwiftUI ラベルのアニメーションは macOS 26 でラグの既知報告があるため、
/// RunCat と同じく NSStatusBarButton.image をタイマーで差し替える。
@MainActor final class IconAnimator {
    // MARK: Lifecycle

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    // MARK: Internal

    func apply(_ state: SessionState) {
        switch state {
        case .recording:
            startAnimating()
        case .preparing:
            stopAnimating()
            setSymbol("arrow.down.circle")
        case .failed:
            stopAnimating()
            setSymbol("exclamationmark.triangle")
        case .idle, .stopping:
            stopAnimating()
            setSymbol("ear")
        }
    }

    // MARK: Private

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var phase = 0.0

    private func startAnimating() {
        guard timer == nil else { return }
        phase = 0
        setSymbol("waveform", variableValue: 0)
        let timer = Timer(timeInterval: 0.12, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // メニュー操作中も止まらないよう common モードに載せる
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        phase += 1.0 / 6.0
        if phase > 1 { phase = 0 }
        setSymbol("waveform", variableValue: phase)
    }

    private func setSymbol(_ name: String, variableValue: Double? = nil) {
        let image: NSImage? = if let variableValue {
            NSImage(systemSymbolName: name, variableValue: variableValue, accessibilityDescription: "OtoLog")
        } else {
            NSImage(systemSymbolName: name, accessibilityDescription: "OtoLog")
        }
        image?.isTemplate = true
        button?.image = image
    }
}
