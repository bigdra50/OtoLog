import SwiftUI
import WebKit

// MARK: - MermaidPage

/// mermaid を描く HTML の組み立て。WebView から切り離してテストできるようにしてある。
enum MermaidPage {
    /// 同梱した mermaid.js の場所。バンドルに無ければ描画しない（CDN へは取りに行かない）
    static var scriptURL: URL? {
        Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
    }

    /// 図のソースは JSON 文字列として埋め、HTML やスクリプトとして解釈されないようにする
    static func html(source: String, scriptFileName: String, isDark: Bool) -> String {
        let encoded = (try? JSONEncoder().encode(source))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          html,body { margin:0; padding:0; background:transparent; overflow:hidden; }
          #d { display:flex; justify-content:flex-start; }
          svg { max-width:100%; height:auto; }
        </style>
        </head><body>
        <div id="d"></div>
        <script src="\(scriptFileName)"></script>
        <script>
          const source = \(encoded);
          mermaid.initialize({ startOnLoad: false, theme: '\(isDark ? "dark" : "default")', securityLevel: 'strict' });
          mermaid.render('g', source)
            .then(({ svg }) => {
              document.getElementById('d').innerHTML = svg;
              // 高さは描画後にしか決まらないので、SwiftUI 側へ知らせる
              requestAnimationFrame(() => {
                window.webkit.messageHandlers.rendered.postMessage(document.body.scrollHeight);
              });
            })
            .catch(e => {
              window.webkit.messageHandlers.failed.postMessage(String(e && e.message ? e.message : e));
            });
        </script>
        </body></html>
        """
    }
}

// MARK: - MermaidView

/// ```mermaid のコードブロックを図として描く。
/// 描けなかったときは呼び出し側がコードブロック表示へ戻す。
struct MermaidView: NSViewRepresentable {
    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler {
        // MARK: Lifecycle

        init(height: Binding<CGFloat>, onFailure: @escaping (String) -> Void) {
            _height = height
            self.onFailure = onFailure
        }

        // MARK: Internal

        var renderedSource: String?

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "rendered":
                if let value = message.body as? NSNumber {
                    height = CGFloat(value.doubleValue)
                }
            default:
                onFailure(message.body as? String ?? "描画に失敗しました")
            }
        }

        // MARK: Private

        @Binding private var height: CGFloat

        private let onFailure: (String) -> Void
    }

    let source: String
    @Binding var height: CGFloat

    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "rendered")
        configuration.userContentController.add(context.coordinator, name: "failed")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 図の背景は本文に馴染ませる（drawsBackground の KVC は非公開なので使わない）
        webView.underPageBackgroundColor = .clear
        // 図は静的な絵。スクロールや選択は不要で、あると親のスクロールと競合する
        webView.enclosingScrollView?.hasVerticalScroller = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let scriptURL = MermaidPage.scriptURL else {
            onFailure("mermaid.js がバンドルに見つかりません")
            return
        }
        guard context.coordinator.renderedSource != source else { return }
        context.coordinator.renderedSource = source

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let html = MermaidPage.html(
            source: source, scriptFileName: scriptURL.lastPathComponent, isDark: isDark
        )
        // mermaid.js を読ませるため、スクリプトのあるディレクトリを基準に読み込む
        webView.loadHTMLString(html, baseURL: scriptURL.deletingLastPathComponent())
    }
}
