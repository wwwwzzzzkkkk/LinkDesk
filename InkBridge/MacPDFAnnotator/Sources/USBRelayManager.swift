import Foundation
import AppKit

enum ConnectionPreference: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case wifi
  case usb

  var id: String { rawValue }
  var title: String {
    switch self {
    case .automatic: return L10n.automatic
    case .wifi: return L10n.transportWireless
    case .usb: return L10n.transportUSB
    }
  }
}

enum ConnectionTransport: String, Sendable {
  case wifi
  case usb

  var title: String { self == .usb ? L10n.transportUSB : L10n.transportWireless }
}

struct DiscoveredTablet: Identifiable, Equatable, Sendable {
  let id: String
  let transport: ConnectionTransport
  let isConnected: Bool

  var displayName: String {
    let shortId = id.count > 28 ? "\(id.prefix(25))…" : id
    return "\(transport.title) · \(shortId)"
  }
}

private struct USBRelayInspection: Sendable {
  let isReady: Bool
  let text: String
  let devices: [DiscoveredTablet]
}

@MainActor
final class USBRelayManager: ObservableObject {
  @Published var preference: ConnectionPreference {
    didSet {
      UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceDefaultsKey)
      evaluateTransport(force: true)
    }
  }
  @Published private(set) var status = "正在搜索平板…"
  @Published private(set) var usbStatus = "USB 检测中…"
  @Published private(set) var isReady = false
  @Published private(set) var activeTransport: ConnectionTransport?
  @Published private(set) var isSwitching = false
  @Published private(set) var discoveredDevices: [DiscoveredTablet] = []

  var onTransportRequest: ((ConnectionTransport, ConnectionPreference, String) -> Void)?

  private var timer: Timer?
  private var isChecking = false
  private var pendingTransport: ConnectionTransport?
  private var pendingRequestId: String?
  private var lastRequestAt = Date.distantPast
  private var tabletDeviceId = ""

  init() {
    let saved = UserDefaults.standard.string(forKey: Self.preferenceDefaultsKey) ?? ""
    preference = ConnectionPreference(rawValue: saved) ?? .automatic
  }

  func start() {
    guard timer == nil else { return }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func sessionDidConnect() {
    evaluateTransport(force: activeTransport == nil)
  }

  func reportTabletTransport(_ transport: ConnectionTransport, requestId: String?, deviceId: String?) {
    activeTransport = transport
    if let deviceId, !deviceId.isEmpty { tabletDeviceId = deviceId }
    if requestId == pendingRequestId || transport == pendingTransport {
      pendingTransport = nil
      pendingRequestId = nil
      isSwitching = false
    }
    updateStatus()
    evaluateTransport()
  }

  func refresh() {
    guard !isChecking else { return }
    guard let hdc = hdcURL() else {
      isReady = false
      usbStatus = "USB 需安装 DevEco Studio"
      discoveredDevices = wifiDeviceIfConnected().map { [$0] } ?? []
      updateStatus()
      evaluateTransport()
      return
    }
    isChecking = true
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Self.inspect(hdc)
      }.value
      guard let self else { return }
      self.isChecking = false
      self.isReady = result.isReady
      self.usbStatus = result.text
      var devices = result.devices
      if let wifi = self.wifiDeviceIfConnected(), !devices.contains(where: { $0.id == wifi.id }) {
        devices.append(wifi)
      }
      self.discoveredDevices = devices
      self.updateStatus()
      self.evaluateTransport()
    }
  }

  private func evaluateTransport(force: Bool = false) {
    let desired: ConnectionTransport
    switch preference {
    case .automatic: desired = isReady ? .usb : .wifi
    case .wifi: desired = .wifi
    case .usb:
      guard isReady else {
        pendingTransport = nil
        pendingRequestId = nil
        isSwitching = false
        updateStatus()
        return
      }
      desired = .usb
    }

    if activeTransport == desired && !force {
      pendingTransport = nil
      pendingRequestId = nil
      isSwitching = false
      updateStatus()
      return
    }
    let requestExpired = Date().timeIntervalSince(lastRequestAt) >= 3.5
    guard force || pendingTransport != desired || requestExpired else { return }
    let requestId = UUID().uuidString.lowercased()
    pendingTransport = desired
    pendingRequestId = requestId
    lastRequestAt = Date()
    isSwitching = true
    updateStatus()
    onTransportRequest?(desired, preference, requestId)
  }

  private func updateStatus() {
    if preference == .usb && !isReady {
      status = "USB 模式 · 等待数据线"
      return
    }
    if isSwitching, let pendingTransport {
      status = "正在切换到 \(pendingTransport.title)…"
      return
    }
    if let activeTransport {
      let suffix = preference == .automatic ? " · 自动" : ""
      status = "\(activeTransport.title)\(suffix)"
      return
    }
    status = preference == .automatic ? "自动搜索中…" : "等待平板连接"
  }

  private func wifiDeviceIfConnected() -> DiscoveredTablet? {
    guard activeTransport == .wifi else { return nil }
    return DiscoveredTablet(
      id: tabletDeviceId.isEmpty ? "room-tablet" : tabletDeviceId,
      transport: .wifi,
      isConnected: true
    )
  }

  nonisolated private static func inspect(_ hdc: URL) -> USBRelayInspection {
    let targetsOutput = run(hdc, arguments: ["list", "targets", "-v"])
    let devices = parseTargets(targetsOutput)
    let connectedUSB = devices.filter { $0.transport == .usb && $0.isConnected }
    guard !connectedUSB.isEmpty else {
      return USBRelayInspection(isReady: false, text: "USB 未连接", devices: devices)
    }

    var readyCount = 0
    for usb in connectedUSB {
      var forwards = run(hdc, arguments: ["-t", usb.id, "fport", "ls"])
      if !hasReverseRelay(forwards) {
        _ = run(hdc, arguments: ["-t", usb.id, "rport", "tcp:3210", "tcp:3210"])
        _ = run(hdc, arguments: ["-t", usb.id, "rport", "tcp:3211", "tcp:3211"])
        // HDC can report an empty or localized result even when the mapping was
        // installed. Verify the forwarding table instead of trusting stdout.
        forwards = run(hdc, arguments: ["-t", usb.id, "fport", "ls"])
      }
      if hasReverseRelay(forwards) { readyCount += 1 }
    }

    let ready = readyCount > 0
    let text: String
    if readyCount == connectedUSB.count {
      text = connectedUSB.count == 1 ? "USB 有线已就绪" : "USB 有线已就绪·\(readyCount) 台"
    } else if ready {
      text = "USB 已就绪·\(readyCount)/\(connectedUSB.count) 台"
    } else {
      text = "USB 转发失败·将自动重试"
    }
    return USBRelayInspection(
      isReady: ready,
      text: text,
      devices: devices
    )
  }

  nonisolated private static func hasReverseRelay(_ output: String) -> Bool {
    let hasControl = output.contains("tcp:3210 tcp:3210") && output.contains("[Reverse]")
    let hasVideo = output.contains("tcp:3211 tcp:3211") && output.contains("[Reverse]")
    return hasControl && hasVideo
  }

  nonisolated private static func parseTargets(_ output: String) -> [DiscoveredTablet] {
    output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty,
            !line.localizedCaseInsensitiveContains("connect server failed"),
            !line.localizedCaseInsensitiveContains("empty") else { return nil }
      let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
      guard let id = fields.first, id != "ConnectKey" else { return nil }
      let connected = fields.contains { $0.caseInsensitiveCompare("Connected") == .orderedSame }
      let transport: ConnectionTransport = fields.contains {
        $0.caseInsensitiveCompare("USB") == .orderedSame
      } ? .usb : .wifi
      return DiscoveredTablet(id: id, transport: transport, isConnected: connected)
    }
  }

  nonisolated private static func run(
    _ executable: URL,
    arguments: [String],
    timeout: TimeInterval = 3
  ) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      output.fileHandleForWriting.closeFile()
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    } catch {
      output.fileHandleForWriting.closeFile()
      return ""
    }
  }

  private func hdcURL() -> URL? {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("tools/hdc").path ?? "",
      NSHomeDirectory() + "/Library/Application Support/LinkDesk/tools/hdc",
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.huawei.devecostudio.ds")?.appendingPathComponent("Contents/sdk/default/openharmony/toolchains/hdc").path ?? "",
      "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
      "/Applications/DevEco-Studio.app/Contents/sdk/default/hms/toolchains/hdc",
    ]
    return candidates.map(URL.init(fileURLWithPath:)).first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  private static let preferenceDefaultsKey = "InkBridgeConnectionPreferenceV1"
}
