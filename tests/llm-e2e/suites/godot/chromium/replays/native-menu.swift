// Exercise only the disposable Godot process's AppKit menu with native keys.
import AppKit
import ApplicationServices

let pid = pid_t(CommandLine.arguments[1])!
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let specification = URL(fileURLWithPath: CommandLine.arguments[3])
let application = AXUIElementCreateApplication(pid)
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func findMenu(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 6 else { return nil }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    if role == kAXMenuBarRole { return nil }
    if role == kAXMenuRole { return element }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let menu = findMenu(child, depth: depth + 1) { return menu }
    }
    return nil
}
func key(_ code: CGKeyCode) {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.04)
    }
}
var receipt: [String: Any] = [:]
defer {
    let bytes = try! JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted])
    try! bytes.write(to: output.appendingPathComponent("native-menu.json"))
}
let deadline = Date().addingTimeInterval(15)
var menu: AXUIElement?
var window: [String: Any]?
while Date() < deadline {
    menu = findMenu(application)
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    window = windows.first { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    if window != nil && FileManager.default.fileExists(atPath: specification.path) { break }
    Thread.sleep(forTimeInterval: 0.05)
}
if let window, let data = try? Data(contentsOf: specification),
   let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let index = spec["index"] as? Int, index >= 0 {
    let items = menu.flatMap { attribute($0, kAXChildrenAttribute) as? [AXUIElement] } ?? []
    receipt["items"] = items.map { attribute($0, kAXTitleAttribute) as? String ?? "" }
    receipt["window"] = window
    receipt["index"] = index
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-l", String(window[kCGWindowNumber as String] as! Int), output.appendingPathComponent("native-menu.png").path]
    try? capture.run()
    capture.waitUntilExit()
    // Home chooses the first enabled item; separators/disabled items are skipped.
    key(115)
    for _ in 0..<index { key(125) }
    key(36)
    receipt["native_keys"] = true
} else {
    receipt["error"] = "No accessible native menu or selection specification"
    key(53) // Dismiss only the test process's menu if tracking already started.
}
