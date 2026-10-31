// OtoLog の検証用インスタンスを、PID を指定して Accessibility API で操作する。
// 普段使いの OtoLog と同じ見た目のアイコンが並ぶため、名前ではなく PID で対象を決める。
// 使い方は otolog-verify の ax サブコマンドから呼ぶ（直接呼ぶときは引数の先頭に PID を置く）。
//
//   perms                         このターミナルの Accessibility と画面収録の許可を出す（ダイアログは出さない）
//   tree <pid>                    AX ツリーを1要素1行で出す
//   press <pid> <label>           AXDescription / AXTitle / AXHelp が label と一致する最初の要素を押す
//                                 label を value=<値> と書くと、AXValue が一致する要素（ポップアップの現在値など）を押す
//                                 label を subrole=<値> と書くと、AXSubrole が一致する要素（AXCloseButton など）を押す
//   select <pid> <text>           text を表示している一覧の行（AXRow）を選ぶ（ライブラリのサイドバー）
//   status-item <pid>             メニューバーのアイコンを押す（ポップオーバーの開閉を切り替える）
//   popover <pid> <open|close>    ポップオーバーを開いた状態か閉じた状態にし、中身が出るまで待つ（今の状態なら何もしない）
//   wait <pid> <label> [秒]       label と一致する要素が現れるまで待つ（既定 10 秒）
//   wait-gone <pid> <label> [秒]  label と一致する要素が無くなるまで待つ（既定 10 秒）
//   windows <pid>                 画面上のウィンドウの CGWindowID と位置を出す
//   terminate <pid> [秒]          通常の終了要求を送り、終わるまで待つ（既定 20 秒）
import AppKit
import ApplicationServices

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ax: \(message)\n".utf8))
    exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute),
          let size = attribute(element, kAXSizeAttribute)
    else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    // AXValue 以外が返ることは無いが、型を確かめずに取り出すと落ちるため確かめる
    guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func describe(_ element: AXUIElement) -> String {
    var parts: [String] = [string(element, kAXRoleAttribute) ?? "?"]
    if let subrole = string(element, kAXSubroleAttribute) { parts.append("subrole=\(subrole)") }
    for (key, name) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute),
                        ("id", kAXIdentifierAttribute)] {
        if let value = string(element, name), !value.isEmpty { parts.append("\(key)=\"\(value)\"") }
    }
    if let value = attribute(element, kAXValueAttribute) {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        if let text, !text.isEmpty { parts.append("value=\"\(text.prefix(200))\"") }
    }
    if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled { parts.append("disabled") }
    if let rect = frame(element) {
        parts.append("frame=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))")
    }
    return parts.joined(separator: " ")
}

/// ウィンドウ（ポップオーバーとライブラリ）とメニューバーのアイコンを根にする。
/// アプリ要素の子にはメニューバー（AppKit の既定メニュー）が入り、探索の雑音になるため含めない
func roots(_ app: AXUIElement) -> [AXUIElement] {
    var result = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if let extras = attribute(app, "AXExtrasMenuBar") {
        result.append(extras as! AXUIElement)
    }
    return result
}

/// 深さ優先で要素を列挙する。depth はツリー表示の字下げに使う。
/// 減少量は残りの深さ（maxDepth - depth）で、SwiftUI が循環した子を返しても止まる
func walk(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 40, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    guard depth <= maxDepth else { return false }
    if visit(element, depth) { return true }
    for child in children(element) where walk(child, depth: depth + 1, maxDepth: maxDepth, visit) {
        return true
    }
    return false
}

func matches(_ element: AXUIElement, _ label: String) -> Bool {
    if label.hasPrefix("value=") {
        return string(element, kAXValueAttribute) == String(label.dropFirst("value=".count))
    }
    if label.hasPrefix("subrole=") {
        return string(element, kAXSubroleAttribute) == String(label.dropFirst("subrole=".count))
    }
    return [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].contains { string(element, $0) == label }
}

/// 親をたどって role の要素を返す。減少量はたどれる残りの段数
func ancestor(of element: AXUIElement, role: String, limit: Int = 10) -> AXUIElement? {
    var current = element
    for _ in 0 ..< limit {
        guard let parent = attribute(current, kAXParentAttribute) else { return nil }
        let parentElement = parent as! AXUIElement
        if string(parentElement, kAXRoleAttribute) == role { return parentElement }
        current = parentElement
    }
    return nil
}

func find(_ app: AXUIElement, _ label: String) -> AXUIElement? {
    var found: AXUIElement?
    for root in roots(app) {
        if walk(root, { element, _ in
            guard matches(element, label) else { return false }
            found = element
            return true
        }) { break }
    }
    return found
}

func statusItem(_ app: AXUIElement) -> AXUIElement? {
    guard let extras = attribute(app, "AXExtrasMenuBar") else { return nil }
    return children(extras as! AXUIElement).first { string($0, kAXRoleAttribute) == kAXMenuBarItemRole }
}

/// 開いたポップオーバーは、メニューバーのアイコンと並ぶ AXPopover として出る。
/// 中のボタンが AX に出るまでは押せないので、ボタンがあるときだけ開いているとみなす
func popoverReady(_ app: AXUIElement) -> Bool {
    guard let extras = attribute(app, "AXExtrasMenuBar") else { return false }
    let popovers = children(extras as! AXUIElement).filter { string($0, kAXRoleAttribute) == "AXPopover" }
    return popovers.contains { popover in
        walk(popover) { element, _ in string(element, kAXRoleAttribute) == kAXButtonRole }
    }
}

func pressStatusItem(_ app: AXUIElement) -> AXUIElement {
    guard let item = statusItem(app) else { fail("メニューバーのアイコンが AX に出ていません", code: 2) }
    let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard status == .success else { fail("AXPress に失敗しました（AXError \(status.rawValue)）") }
    return item
}

func application(_ pidText: String) -> (pid_t, AXUIElement) {
    guard let pid = pid_t(pidText), NSRunningApplication(processIdentifier: pid) != nil else {
        fail("PID \(pidText) のアプリが見つかりません", code: 66)
    }
    guard AXIsProcessTrusted() else {
        fail("このターミナルに Accessibility の許可がありません（システム設定 > プライバシーとセキュリティ > アクセシビリティ）", code: 77)
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    return (pid, app)
}

let args = CommandLine.arguments
if args.count == 2, args[1] == "perms" {
    print("accessibility=\(AXIsProcessTrusted())")
    print("screen-recording=\(CGPreflightScreenCaptureAccess())")
    exit(0)
}
guard args.count >= 3 else {
    fail("usage: ax <perms|tree|press|status-item|wait|windows|terminate> <pid> [...]", code: 64)
}

switch args[1] {
case "tree":
    let (_, app) = application(args[2])
    for root in roots(app) {
        _ = walk(root) { element, depth in
            print(String(repeating: "  ", count: depth) + describe(element))
            return false
        }
    }

case "press":
    guard args.count >= 4 else { fail("usage: ax press <pid> <label>", code: 64) }
    let (_, app) = application(args[2])
    guard let element = find(app, args[3]) else { fail("「\(args[3])」に一致する要素がありません", code: 2) }
    // 押すとラベルが変わる要素がある（記録を開始 → 記録を停止）。押す前の姿を出す
    let pressed = describe(element)
    let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard status == .success else { fail("AXPress に失敗しました（AXError \(status.rawValue)）") }
    print("pressed: \(pressed)")

case "select":
    guard args.count >= 4 else { fail("usage: ax select <pid> <text>", code: 64) }
    let (_, app) = application(args[2])
    guard let text = find(app, "value=\(args[3])"),
          let row = ancestor(of: text, role: kAXRowRole)
    else { fail("「\(args[3])」を表示している行がありません", code: 2) }
    let status = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    guard status == .success else { fail("行を選べませんでした（AXError \(status.rawValue)）") }
    print("selected: \(describe(row))")

case "status-item":
    let (_, app) = application(args[2])
    print("pressed: \(describe(pressStatusItem(app)))")

case "popover":
    guard args.count >= 4, ["open", "close"].contains(args[3]) else {
        fail("usage: ax popover <pid> <open|close>", code: 64)
    }
    let (_, app) = application(args[2])
    let wantsOpen = args[3] == "open"
    if popoverReady(app) != wantsOpen {
        _ = pressStatusItem(app)
    }
    let deadline = Date().addingTimeInterval(5)
    // 減少量は締め切りまでの残り時間
    while Date() < deadline {
        if popoverReady(app) == wantsOpen {
            print("popover: \(wantsOpen ? "open" : "closed")")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail("ポップオーバーが\(wantsOpen ? "開きません" : "閉じません")", code: 2)

case "wait":
    guard args.count >= 4 else { fail("usage: ax wait <pid> <label> [seconds]", code: 64) }
    let (_, app) = application(args[2])
    let deadline = Date().addingTimeInterval(args.count >= 5 ? Double(args[4]) ?? 10 : 10)
    // 減少量は締め切りまでの残り時間
    while Date() < deadline {
        if let element = find(app, args[3]) {
            print("found: \(describe(element))")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    fail("「\(args[3])」に一致する要素が現れませんでした", code: 2)

case "wait-gone":
    guard args.count >= 4 else { fail("usage: ax wait-gone <pid> <label> [seconds]", code: 64) }
    let (_, app) = application(args[2])
    let deadline = Date().addingTimeInterval(args.count >= 5 ? Double(args[4]) ?? 10 : 10)
    // 減少量は締め切りまでの残り時間
    while Date() < deadline {
        if find(app, args[3]) == nil {
            print("gone: \(args[3])")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    fail("「\(args[3])」に一致する要素が残っています", code: 2)

case "windows":
    guard let pid = pid_t(args[2]) else { fail("PID が数字ではありません", code: 64) }
    let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for info in infos where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let number = info[kCGWindowNumber as String] as? Int ?? 0
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let name = info[kCGWindowName as String] as? String ?? ""
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let rect = "\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)),\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))"
        print("\(number)\tlayer=\(layer)\tframe=\(rect)\tname=\"\(name)\"")
    }

case "terminate":
    guard let pid = pid_t(args[2]), let app = NSRunningApplication(processIdentifier: pid) else {
        fail("PID \(args[2]) のアプリが見つかりません", code: 66)
    }
    // 通常の終了（applicationShouldTerminate を通る）。記録中なら閉じ終わるまで最大 15 秒かかる
    _ = app.terminate()
    let deadline = Date().addingTimeInterval(args.count >= 4 ? Double(args[3]) ?? 20 : 20)
    while Date() < deadline {
        if kill(pid, 0) != 0 {
            print("terminated: \(pid)")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    fail("PID \(pid) が終了しませんでした", code: 3)

default:
    fail("unknown subcommand: \(args[1])", code: 64)
}
