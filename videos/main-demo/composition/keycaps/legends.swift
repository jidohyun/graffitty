// Keyty uses NSFont.systemFont: medium, label 14 pt and symbol 22 pt.
// Freeze CoreText outlines so SVG playback never substitutes fonts.
import AppKit
import CoreText
func outline(_ text: String, size: CGFloat, right: CGFloat, baseline: CGFloat) -> String {
    let font = NSFont.systemFont(ofSize: size, weight: .medium)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    var output = ""
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<count {
            guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            var d = ""
            path.applyWithBlock { pointer in
                let e = pointer.pointee
                func p(_ i: Int) -> String { "\(e.points[i].x),\(e.points[i].y)" }
                switch e.type {
                case .moveToPoint: d += "M\(p(0))"
                case .addLineToPoint: d += "L\(p(0))"
                case .addQuadCurveToPoint: d += "Q\(p(0)) \(p(1))"
                case .addCurveToPoint: d += "C\(p(0)) \(p(1)) \(p(2))"
                case .closeSubpath: d += "Z"
                @unknown default: break
                }
            }
            output += "<path transform=\"translate(\(right-width+positions[i].x) \(baseline)) scale(1 -1)\" d=\"\(d)\"/>"
        }
    }
    return output
}
var result: [String:String] = [:]
for (name, symbol, width) in [("cmd", "⌘", 114.0), ("ctrl", "⌃", 126.0), ("shift", "⇧", 126.0), ("alt", "⌥", 126.0), ("enter", "↩", 154.0)] {
    let label = name == "cmd" ? "command" : name == "ctrl" ? "control" : name == "alt" ? "option" : name
    result[name] = outline(label, size: 14, right: width-25, baseline: 64) + outline(symbol, size: 22, right: width-25, baseline: 37)
}
for (name, symbol) in [("2", "2"), ("3", "3"), ("a", "A"), ("colon", ":"), ("minus", "-"), ("underscore", "_")] {
    let font = NSFont.systemFont(ofSize: 32, weight: .medium)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: symbol, attributes: [.font: font]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    result[name] = outline(symbol, size: 32, right: 50+width/2, baseline: 54)
}
// A sequence separator: a plain comma between keycaps, not a key.
do {
    let font = NSFont.systemFont(ofSize: 32, weight: .medium)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: ",", attributes: [.font: font]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    result["comma"] = outline(",", size: 32, right: 12+width/2, baseline: 62)
}
for label in ["Open command line", "Return to Main View", "Restore previous view", "Zoom to pane", "Send to pane 2",
              "Send to pane 2 without Enter", "Send to tab 2, pane 3"] {
    let font = NSFont.systemFont(ofSize: 24, weight: .medium)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    result["label-" + label] = outline(label, size: 24, right: 213+width/2, baseline: 31)
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
