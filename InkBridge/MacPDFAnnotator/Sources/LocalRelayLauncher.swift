import AppKit
import Foundation

/// Starts the local-only web relay when the Finder app is opened. If another
/// copy is already listening, its process simply exits and the app uses it.
@MainActor
final class LocalRelayLauncher {
  static let shared = LocalRelayLauncher()
  private static let requiredRelayVersion = 13
  private var process: Process?
  private var isCheckingExistingService = false
  private var discoveryService: NetService?

  private init() {}

  func startIfNeeded() {
    guard process == nil, !isCheckingExistingService else { return }
    // Start immediately so opening the Finder app never depends on an
    // asynchronous localhost probe completing during SwiftUI initialization.
    // If a compatible relay is already listening, this short-lived child exits
    // with EADDRINUSE and the version check below keeps the existing service.
    launchRelay()
    isCheckingExistingService = true
    var request = URLRequest(url: URL(string: "http://127.0.0.1:3210/config")!)
    request.timeoutInterval = 0.5
    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isCheckingExistingService = false
        let configuration = data.flatMap { try? JSONDecoder().decode(RelayConfiguration.self, from: $0) }
        if (response as? HTTPURLResponse)?.statusCode == 200,
           configuration?.relayVersion == Self.requiredRelayVersion,
           configuration?.appVersion == inkBridgeAppVersion,
           configuration?.protocolVersion == inkBridgeProtocolVersion {
          return
        } else {
          self.replaceOutdatedRelay()
        }
      }
    }.resume()
  }

  /// Advertise the relay independently of the Mac's current IP address. The
  /// HarmonyOS client resolves this service on every launch and after network
  /// changes, so saved addresses never become a connection requirement.
  func publishDiscoveryService(room: String) {
    guard room.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil else { return }
    let serviceName = "InkBridge-\(room)"
    if discoveryService?.name == serviceName { return }
    discoveryService?.stop()
    let service = NetService(
      domain: "local.",
      type: "_inkbridge._tcp.",
      name: serviceName,
      port: 3210
    )
    service.includesPeerToPeer = true
    service.setTXTRecord(NetService.data(fromTXTRecord: [
      "room": Data(room.utf8),
      "appVersion": Data(inkBridgeAppVersion.utf8),
      "protocolVersion": Data(String(inkBridgeProtocolVersion).utf8),
    ]))
    discoveryService = service
    service.publish()
  }

  func stop() {
    discoveryService?.stop()
    discoveryService = nil
    process?.terminationHandler = nil
    if process?.isRunning == true { process?.terminate() }
    process = nil

    // Older builds could leave the bundled relay orphaned after the app quit.
    // Stop only this app bundle's exact script, never an arbitrary Node task.
    guard let script = relayScriptURL() else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    task.arguments = ["-f", script.path]
    do { try task.run() } catch { /* No relay is already the desired state. */ }
  }

  /// A Finder relaunch can otherwise reuse an older orphaned Node process,
  /// leaving the app and the web client on incompatible relay protocols.
  private func replaceOutdatedRelay() {
    guard let script = relayScriptURL() else { return launchRelay() }
    process = nil
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    task.arguments = ["-f", script.path]
    do { try task.run() } catch { /* No old relay is also a valid state. */ }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.launchRelay() }
  }

  private func launchRelay() {
    guard process == nil,
          let script = relayScriptURL(),
          let node = nodeURL() else { return }
    let task = Process()
    // Launch through the user's login shell. Directly spawning Homebrew's Node
    // from a Finder app can leave Node alive without evaluating its entry
    // script; the shell launch uses the same execution context as `node
    // local-server.mjs` in Terminal, while still remaining invisible.
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-lc", "exec \(shellQuote(node.path)) \(shellQuote(script.path))"]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    task.terminationHandler = { [weak self, weak task] _ in
      Task { @MainActor in
        guard let self, let task, self.process === task else { return }
        self.process = nil
      }
    }
    do {
      try task.run()
      process = task
    } catch {
      process = nil
    }
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
  }

  private func relayScriptURL() -> URL? {
    let manager = FileManager.default
    if let resources = Bundle.main.resourceURL {
      let bundled = resources.appendingPathComponent("local-server.mjs")
      if manager.fileExists(atPath: bundled.path) { return bundled }
    }
    let workingDirectory = URL(fileURLWithPath: manager.currentDirectoryPath)
    let fromWorkingDirectory = workingDirectory.appendingPathComponent("local-server.mjs")
    if manager.fileExists(atPath: fromWorkingDirectory.path) { return fromWorkingDirectory }

    // Finder launches the app from .../触控板/LinkDesk.app/Contents/MacOS.
    var folder = Bundle.main.bundleURL
    for _ in 0..<4 {
      folder.deleteLastPathComponent()
      let candidate = folder.appendingPathComponent("local-server.mjs")
      if manager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private func nodeURL() -> URL? {
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent("node").path ?? "", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }
}

private struct RelayConfiguration: Decodable {
  let relayVersion: Int?
  let appVersion: String?
  let protocolVersion: Int?
}
