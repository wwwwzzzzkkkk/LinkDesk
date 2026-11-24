import Foundation

struct TabletCameraWakeTarget: Equatable, Sendable {
  struct Point: Equatable, Sendable {
    let x: Int
    let y: Int
  }

  enum Prompt: Equatable {
    case unavailable, clear, asleep(Point)
  }

  let hdc: URL
  let deviceID: String
  static let promptText = "点击屏幕唤醒相机"

  func readPrompt() async -> Prompt {
    let file = "linkdesk-camera-\(UUID().uuidString).json"
    let remote = "/data/local/tmp/\(file)"
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let local = directory.appending(path: file)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
    } catch { return .unavailable }
    defer {
      _ = run(["shell", "unlink", remote])
      try? FileManager.default.removeItem(at: directory)
    }

    guard !Task.isCancelled else { return .unavailable }
    _ = run(["shell", "uitest", "dumpLayout", "-p", remote])
    guard !Task.isCancelled else { return .unavailable }
    _ = run(["file", "recv", remote, local.path])
    guard let data = try? Data(contentsOf: local) else { return .unavailable }
    return Self.parsePrompt(data)
  }

  func tap(_ point: Point) async {
    guard !Task.isCancelled else { return }
    _ = run(["shell", "uitest", "uiInput", "click", String(point.x), String(point.y)])
  }

  private func run(_ arguments: [String]) -> String {
    USBRelayManager.run(hdc, arguments: ["-t", deviceID] + arguments)
  }

  static func parsePrompt(_ data: Data) -> Prompt {
    guard let layout = try? JSONDecoder().decode(Node.self, from: data) else { return .unavailable }
    let matches = layout.wakePoints(app: nil, inStandbyView: false)
    guard matches.count <= 1 else { return .unavailable }
    return matches.first.map(Prompt.asleep) ?? .clear
  }

  private struct Node: Decodable {
    struct Attributes: Decodable {
      let bundleName: String?
      let key: String?
      let text: String?
      let bounds: String?
      let visible: String?
    }

    let attributes: Attributes
    let children: [Node]?

    func wakePoints(app: String?, inStandbyView: Bool) -> [Point] {
      guard attributes.visible != "false" else { return [] }
      let app = attributes.bundleName.flatMap { $0.isEmpty ? nil : $0 } ?? app
      let standby = inStandbyView || attributes.key == "SAVE_POWER_MODE_VIEW"
      if app == "com.huawei.hmos.camera", standby, attributes.visible == "true",
         attributes.text?.trimmingCharacters(in: .whitespacesAndNewlines) == promptText,
         let bounds = attributes.bounds,
         let match = bounds.wholeMatch(of: /\[([0-9]{1,5}),([0-9]{1,5})\]\[([0-9]{1,5}),([0-9]{1,5})\]/),
         let left = Int(match.1), let top = Int(match.2), let right = Int(match.3), let bottom = Int(match.4),
         left < right, top < bottom {
        return [Point(x: (left + right) / 2, y: (top + bottom) / 2)]
      }
      return (children ?? []).flatMap { $0.wakePoints(app: app, inStandbyView: standby) }
    }
  }
}
