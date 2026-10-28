import AppKit
import ApplicationServices

/// Read only the input method's exposed candidate text; never inspect the
/// focused document, and never persist or log preedit content.
enum WeTypeCandidates {
  nonisolated static func read() -> (values: [String], nodes: Int, segments: Int) {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.inputmethod.wetype").first else { return ([], -1, 0) }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var pending = [root], count = 0, segments: [String] = []
    while !pending.isEmpty && count < 60 {
      let node = pending.removeFirst(); count += 1; AXUIElementSetMessagingTimeout(node, 0.025)
      for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(node, attr as CFString, &raw) == .success, let text = (raw as? String) ?? (raw as? NSAttributedString)?.string {
          let values = parse(text)
          if !values.isEmpty { return (values, count, segments.count) }
          if !text.isEmpty && text.count <= 120 && segments.last != text { segments.append(text) }
        }
      }
      for attr in [kAXWindowsAttribute, kAXChildrenAttribute] {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(node, attr as CFString, &raw) == .success, let children = raw as? [AXUIElement] {
          pending.append(contentsOf: children.prefix(30))
        }
      }
    }
    return (parse(segments.joined(separator: " ")), count, segments.count)
  }
  nonisolated static func parse(_ text: String) -> [String] {
    guard text.count <= 2048, let re = try? NSRegularExpression(pattern: #"(?:^|\s)([1-9])\s+"#) else { return [] }
    let ns = text as NSString, matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard matches.count >= 2, ns.substring(with: matches[0].range(at: 1)) == "1" else { return [] }
    var result: [String] = []
    for (i, match) in matches.prefix(9).enumerated() {
      guard Int(ns.substring(with: match.range(at: 1))) == i + 1 else { break }
      let start = NSMaxRange(match.range), end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
      guard end >= start else { break }
      let value = ns.substring(with: NSRange(location: start, length: end-start)).trimmingCharacters(in: .whitespacesAndNewlines)
      if value.isEmpty || value.count > 80 { break }; result.append(value)
    }
    return result.count >= 2 ? result : []
  }
}
