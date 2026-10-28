import AppKit
import CryptoKit
import Carbon
import IOKit.hidsystem

/// All input is explicit, authenticated and momentary; no held modifier survives a disconnect.
@MainActor
final class KeyboardHost: ObservableObject {
  static let shared = KeyboardHost()
  let pairingKey: String
  @Published private(set) var permitted = false
  private var socket: URLSessionWebSocketTask?
  private var timer: Timer?
  private let modifierLease = KeyboardModifierLease()
  private let eventSource = CGEventSource(stateID: .privateState)
  private var leaseTimer: Timer?
  private var virtualCaps = false
  private var voiceOwner: String?
  private var voiceRenewed: TimeInterval = 0
  private var running = false
  private var generation = 0
  private var testWindow: NSWindow?
  private var touchOwner: String?
  private var touchLast = CGPoint.zero
  private var touchRenewed: TimeInterval = 0
  private var touchDisplay: CGDirectDisplayID = kCGNullDirectDisplay
  private var touchKind = "idle"
  private var touchStart = CGPoint.zero
  private var touchLatest = CGPoint.zero
  private var touchTarget: TouchTarget?
  private var touchForceScroll = false
  private var touchToken = 0
  private var scrollVelocity = CGPoint.zero
  private var scrollRemainder = CGPoint.zero
  private var scrollPoint = CGPoint.zero
  private var scrollAt: TimeInterval = 0
  private var scrollDisplay: CGDirectDisplayID = kCGNullDirectDisplay
  private var momentumTimer: Timer?
  private var momentumLast: TimeInterval = 0
  private var scrollActive = false
  private var momentumActive = false
  private var candidateWantedAt: TimeInterval = 0
  private var candidateScanAt: TimeInterval = 0
  private var candidateScanning = false
  private var candidateValues: [String] = []
  private var candidateRevision = 0
  private var touchReduceMotion = false
  private var lastTouchClick: TimeInterval = 0
  private var lastTouchClickPoint = CGPoint.zero
  private var touchClickCount: Int64 = 1

  func showTestWindow() {
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
    editor.isRichText = false; editor.font = .systemFont(ofSize: 22)
    editor.autoresizingMask = [.width, .height]
    let scroll = NSScrollView(frame: editor.frame); scroll.documentView = editor; scroll.hasVerticalScroller = true
    let window = NSWindow(contentRect: editor.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = L10n.keyboardTitle; window.contentView = scroll; window.isReleasedWhenClosed = false
    window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
    testWindow = window
  }

  private init() {
    // The USB bootstrap is intentionally available to local processes; a private
    // app-owned file preserves the same local-user trust boundary without a
    // Keychain consent dialog blocking app launch after development rebuilds.
    let manager = FileManager.default
    let folder = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LinkDesk/Keyboard", isDirectory: true)
    let file = folder.appendingPathComponent("pairing-v1.key")
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let data: Data
      if manager.fileExists(atPath: file.path) {
        data = try Data(contentsOf: file)
      } else {
        data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try data.write(to: file, options: .atomic)
      }
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      pairingKey = data.count == 32 ? data.map { String(format: "%02x", $0) }.joined() : ""
    } catch { pairingKey = "" }
  }
  func start() {
    guard !running, !pairingKey.isEmpty else { return }
    running = true; connect()
    leaseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.postModifiers(self.modifierLease.expire(now: ProcessInfo.processInfo.systemUptime))
        self.refreshCandidates()
        if self.voiceOwner != nil && ProcessInfo.processInfo.systemUptime - self.voiceRenewed > 1.5 { self.releaseVoice() }
        if self.touchOwner != nil && ProcessInfo.processInfo.systemUptime - self.touchRenewed > 1.5 { self.releaseTouch() }
      }
    }
    if let leaseTimer { RunLoop.main.add(leaseTimer, forMode: .common) }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.report() }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }
  func stop() { releaseVoice(); stopMomentum(); releaseTouch(); virtualCaps = false; postModifiers(modifierLease.release()); leaseTimer?.invalidate(); leaseTimer = nil; running = false; generation += 1; timer?.invalidate(); timer = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
  func requestPermission() { _ = CGRequestPostEventAccess(); permitted = CGPreflightPostEventAccess(); report() }
  private func connect() {
    guard running else { return }
    generation += 1; let expected = generation
    var request = URLRequest(url: URL(string: "ws://127.0.0.1:3210/keyboard-host")!)
    request.setValue("Bearer \(pairingKey)", forHTTPHeaderField: "Authorization")
    let task = URLSession.shared.webSocketTask(with: request)
    task.maximumMessageSize = 8192; socket = task; task.resume()
    receive(task, generation: expected); report()
  }
  private func lost(_ expected: Int) {
    guard running, expected == generation else { return }
    postModifiers(modifierLease.release())
    releaseVoice(); stopMomentum()
    releaseTouch()
    generation += 1; socket?.cancel(with: .goingAway, reason: nil); socket = nil
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(750))
      guard let self, self.running, self.socket == nil else { return }
      self.connect()
    }
  }
  private func report() {
    permitted = CGPreflightPostEventAccess()
    if !permitted || IsSecureEventInputEnabled() { postModifiers(modifierLease.release()); releaseVoice(); releaseTouch() }
    send(["type": "keyboard:status", "permitted": permitted, "secureInput": IsSecureEventInputEnabled()])
  }
  private func send(_ value: [String: Any]) {
    guard let task = socket, let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
    let expected = generation
    task.send(.string(text)) { [weak self] error in
      if error != nil { Task { @MainActor in self?.lost(expected) } }
    }
  }
  private func receive(_ task: URLSessionWebSocketTask, generation expected: Int) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, expected == self.generation else { return }
        switch result {
        case .failure: self.lost(expected)
        case .success(let message):
          if case .string(let text) = message, let data = text.data(using: .utf8),
             let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.apply(value) }
          self.receive(task, generation: expected)
        }
      }
    }
  }
  private func apply(_ value: [String: Any]) {
    if value["type"] as? String == "keyboard:release", let session = value["session"] as? String {
      postModifiers(modifierLease.release(owner: session)); if voiceOwner == session { releaseVoice() }; if touchOwner == session { releaseTouch() }; return
    }
    if let type = value["type"] as? String, type.hasPrefix("touch:") { applyTouch(value, type: type); return }
    guard let id = value["id"] as? String, id.count == 32 else { return }
    if value["type"] as? String != "keyboard:lease" { candidateRevision += 1; candidateValues = []; candidateScanAt = 0 }
    if value["type"] as? String == "keyboard:lease" {
      if value["candidates"] as? Bool == true { candidateWantedAt = ProcessInfo.processInfo.systemUptime }
      else { candidateWantedAt = 0; candidateValues = [] }
    }
    if ProcessInfo.processInfo.arguments.contains("--keyboard-test"), let modifiers = value["modifiers"] as? Int { testWindow?.subtitle = "m\(modifiers)" }
    var error = ""
    if !CGPreflightPostEventAccess() { error = "permission" }
    else if IsSecureEventInputEnabled() { error = "secure-input" }
    else if let expires = value["expires"] as? Double, expires >= Date().timeIntervalSince1970 * 1000, expires <= Date().timeIntervalSince1970 * 1000 + 1500 {
      let session = value["session"] as? String ?? "legacy"
      if ["keyboard:modifiers", "keyboard:lease"].contains(value["type"] as? String ?? ""), let mask = value["modifiers"] as? Int, (0...15).contains(mask) {
        postModifiers(modifierLease.set(mask, owner: session, now: ProcessInfo.processInfo.systemUptime))
      } else if value["type"] as? String == "keyboard:key", let key = value["key"] as? String, key == "inputsource" {
        postModifiers(modifierLease.release(owner: session)); selectNextInputSource()
      } else if value["type"] as? String == "keyboard:key", let key = value["key"] as? String, ["voiceDown", "voiceKeep", "voiceUp"].contains(key) {
        if key == "voiceDown" {
          if voiceOwner == nil {
            if CGEventSource.keyState(.combinedSessionState, key: 63) { error = "busy" }
            else if postVoiceFn(true) { voiceOwner = session; voiceRenewed = ProcessInfo.processInfo.systemUptime }
            else { error = "event" }
          } else if voiceOwner != session { error = "busy" }
        } else if voiceOwner == session {
          if key == "voiceUp" { releaseVoice() } else { voiceRenewed = ProcessInfo.processInfo.systemUptime }
        } else { error = "expired" }
      } else if value["type"] as? String == "keyboard:key", let key = value["key"] as? String, ["capslock", "capslockHold"].contains(key) {
        postModifiers(modifierLease.release(owner: session))
        if key == "capslockHold" { virtualCaps.toggle() }
        else { virtualCaps = false; selectNextInputSource() }
      } else if value["type"] as? String == "keyboard:key", let key = value["key"] as? String, let code = Self.mediaCodes[key] {
        for down in [true, false] {
          NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (down ? 0xa00 : 0xb00), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
      } else if value["type"] as? String == "keyboard:text", let text = value["text"] as? String, !text.isEmpty, text.utf16.count <= 1024 {
        postModifiers(modifierLease.release(owner: session))
        var units = Array(text.utf16)
        while !units.isEmpty {
          var count = min(20, units.count)
          if count < units.count && (0xD800...0xDBFF).contains(units[count - 1]) { count -= 1 }
          let piece = Array(units.prefix(count)); units.removeFirst(count)
          guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { error = "event"; break }
          down.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
          up.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
          down.flags = []; up.flags = []; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
      } else if value["type"] as? String == "keyboard:key", let key = value["key"] as? String,
                let code = Self.keyCodes[key], let modifiers = value["modifiers"] as? Int, (0...15).contains(modifiers),
                let down = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false) {
        // Armed one-shot chords also need real modifier transitions (e.g. Cmd-Tab).
        // Restore only the leased state after the key; held two-hand chords stay down.
        let held = modifierLease.mask
        postModifiers(KeyboardModifierLease.changes(from: held, to: modifiers))
        var flags = eventFlags(modifiers)
        if key.hasPrefix("numpad") || ["left", "right", "up", "down"].contains(key) { flags.insert(.maskNumericPad) }
        down.flags = flags; up.flags = flags
        // The tablet already schedules repetition. Each message is a complete
        // down/up tap, so it must not masquerade as an autorepeat of a held key.
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        postModifiers(KeyboardModifierLease.changes(from: modifiers, to: held))
      } else { error = "invalid" }
    } else { error = "expired" }
    if ProcessInfo.processInfo.arguments.contains("--keyboard-test") { NSLog("KEYBOARD_TEST active=%d permitted=%d secure=%d key=%@ repeat=%d result=%@", NSApp.isActive, CGPreflightPostEventAccess(), IsSecureEventInputEnabled(), value["key"] as? String ?? "control", value["repeat"] as? Bool == true, error.isEmpty ? "posted" : error) }
    send(["type": "keyboard:ack", "id": id, "ok": error.isEmpty, "error": error, "inputSource": inputSourceName(), "capsLock": capsLockState(), "candidates": error.isEmpty && value["candidates"] as? Bool == true ? candidateValues : []])
  }
  private func refreshCandidates() {
    let now = ProcessInfo.processInfo.systemUptime
    let source = inputSourceName()
    guard running, candidateWantedAt > 0, now - candidateWantedAt < 1.5, (source.contains("微信") || source.localizedCaseInsensitiveContains("WeType")), CGPreflightPostEventAccess(), !IsSecureEventInputEnabled() else { candidateValues = []; return }
    guard !candidateScanning, now - candidateScanAt >= 0.15 else { return }
    candidateScanning = true; candidateScanAt = now; let expected = generation, revision = candidateRevision
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = WeTypeCandidates.read()
      await MainActor.run { [weak self] in
        guard let self else { return }; self.candidateScanning = false
        if self.running && self.generation == expected && self.candidateRevision == revision && ProcessInfo.processInfo.systemUptime - self.candidateWantedAt < 1.5 { self.candidateValues = result.values }
      }
    }
  }
  private func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) {
    guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
    if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged { event.setIntegerValueField(.mouseEventClickState, value: touchClickCount) }
    event.post(tap: .cghidEventTap)
  }
  private func releaseTouch() {
    if touchOwner != nil && touchKind == "drag" { mouse(.leftMouseUp, touchLast) }
    if touchOwner != nil && touchKind == "pinch" { TouchMagnification.post(0, phase: 4) }
    touchOwner = nil; touchDisplay = kCGNullDirectDisplay; touchKind = "idle"; touchToken += 1
  }
  private func stopMomentum() {
    momentumTimer?.invalidate(); momentumTimer = nil
    if scrollActive { postScroll(.zero, at: scrollPoint, phase: 4); scrollActive = false }
    if momentumActive { postScroll(.zero, at: scrollPoint, momentum: 3); momentumActive = false }
    scrollVelocity = .zero; scrollRemainder = .zero
  }
  private func postScroll(_ delta: CGPoint, at point: CGPoint, phase: Int64 = 0, momentum: Int64 = 0) {
    scrollRemainder.x += delta.x; scrollRemainder.y += delta.y
    let dx = Int32(max(-200, min(200, scrollRemainder.x.rounded(.towardZero))))
    let dy = Int32(max(-200, min(200, scrollRemainder.y.rounded(.towardZero))))
    scrollRemainder.x -= CGFloat(dx); scrollRemainder.y -= CGFloat(dy)
    guard dx != 0 || dy != 0 || phase != 0 || momentum != 0 else { return }
    if let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
      event.location = point
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
      event.post(tap: .cghidEventTap)
    }
  }
  private func trackScroll(_ delta: CGPoint, at point: CGPoint, sample: TimeInterval) {
    let elapsed = max(1.0 / 240, min(0.1, sample - scrollAt))
    if sample - scrollAt > 0.15 { scrollVelocity = .zero }
    let alpha = 1 - exp(-elapsed / 0.055)
    scrollVelocity.x = max(-1600, min(1600, scrollVelocity.x * (1-alpha) + delta.x / elapsed * alpha))
    scrollVelocity.y = max(-1600, min(1600, scrollVelocity.y * (1-alpha) + delta.y / elapsed * alpha))
    scrollAt = sample; scrollPoint = point
    postScroll(delta, at: point, phase: scrollActive ? 2 : 1); scrollActive = true
  }
  private func startMomentum() {
    if scrollActive { postScroll(.zero, at: scrollPoint, phase: 4); scrollActive = false }
    guard !touchReduceMotion, ProcessInfo.processInfo.systemUptime - scrollAt < 0.12, hypot(scrollVelocity.x, scrollVelocity.y) > 80 else { stopMomentum(); return }
    momentumTimer?.invalidate()
    let started = ProcessInfo.processInfo.systemUptime
    momentumLast = started
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.05, max(0, now - self.momentumLast)); self.momentumLast = now
        let decay = exp(-elapsed / 0.38)
        self.scrollVelocity.x *= decay; self.scrollVelocity.y *= decay
        if now - started >= 1.25 || hypot(self.scrollVelocity.x, self.scrollVelocity.y) < 18 || self.touchOwner != nil || !CGPreflightPostEventAccess() || IsSecureEventInputEnabled() || DesktopSession.shared.engine.touchDisplayID != self.scrollDisplay { self.stopMomentum(); return }
        self.postScroll(CGPoint(x: self.scrollVelocity.x * elapsed, y: self.scrollVelocity.y * elapsed), at: self.scrollPoint, momentum: self.momentumActive ? 2 : 1)
        self.momentumActive = true
      }
    }
    momentumTimer = timer; RunLoop.main.add(timer, forMode: .common)
  }
  private func beginDrag() {
    let now = ProcessInfo.processInfo.systemUptime
    let near = hypot(touchStart.x - lastTouchClickPoint.x, touchStart.y - lastTouchClickPoint.y) <= 5
    touchClickCount = near && now - lastTouchClick <= NSEvent.doubleClickInterval ? min(3, touchClickCount + 1) : 1
    lastTouchClick = now; lastTouchClickPoint = touchStart
    mouse(.mouseMoved, touchStart); mouse(.leftMouseDown, touchStart); touchKind = "drag"
  }
  private func moveTouch(_ point: CGPoint, sample: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    if touchKind == "pending" {
      guard let target = touchTarget else { touchLatest = point; return }
      let dx = point.x - touchStart.x, dy = point.y - touchStart.y
      if TouchTarget.shouldScroll(target, force: touchForceScroll, delta: CGPoint(x: dx, y: dy)) {
        touchKind = "scroll"; mouse(.mouseMoved, touchStart); scrollAt = ProcessInfo.processInfo.systemUptime; scrollPoint = touchStart
      } else { beginDrag() }
    }
    if touchKind == "drag" {
      if hypot(point.x - touchStart.x, point.y - touchStart.y) > 5 { lastTouchClick = 0; touchClickCount = 1 }
      touchLast = point; mouse(.leftMouseDragged, point)
    } else if touchKind == "scroll" {
      let delta = CGPoint(x: point.x - touchLast.x, y: point.y - touchLast.y)
      touchLast = point; trackScroll(delta, at: point, sample: sample)
    }
  }
  private func applyTouch(_ value: [String: Any], type: String) {
    guard let session = value["session"] as? String, let expires = value["expires"] as? Double,
      expires >= Date().timeIntervalSince1970 * 1000, expires <= Date().timeIntervalSince1970 * 1000 + 1500,
      CGPreflightPostEventAccess(), !IsSecureEventInputEnabled() else { releaseTouch(); return }
    if type == "touch:cancel" { stopMomentum(); if touchOwner == session { releaseTouch() }; return }
    if type == "touch:halt" { stopMomentum(); return }
    if type == "touch:ping" {
      if touchOwner == session {
        if DesktopSession.shared.engine.touchDisplayID != touchDisplay || CGDisplayIsActive(touchDisplay) == 0 { releaseTouch() }
        else { touchRenewed = ProcessInfo.processInfo.systemUptime }
      }
      return
    }
    if type == "touch:scrollend" { touchReduceMotion = value["reduceMotion"] as? Bool ?? false; startMomentum(); return }
    let display = DesktopSession.shared.engine.touchDisplayID
    if touchOwner != nil && display != touchDisplay { releaseTouch() }
    guard display != kCGNullDirectDisplay, CGDisplayIsActive(display) != 0,
      let x = value["x"] as? Double, let y = value["y"] as? Double,
      x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { releaseTouch(); return }
    let bounds = CGDisplayBounds(display)
    guard bounds.width > 0, bounds.height > 0 else { releaseTouch(); return }
    let p = CGPoint(x: bounds.minX + min(x * bounds.width, bounds.width - 1), y: bounds.minY + min(y * bounds.height, bounds.height - 1))
    let now = ProcessInfo.processInfo.systemUptime
    let sample = now - max(0, min(0.5, Date().timeIntervalSince1970 - (expires - 1000) / 1000))
    touchRenewed = ProcessInfo.processInfo.systemUptime
    switch type {
    case "touch:down":
      stopMomentum(); if touchOwner != nil { releaseTouch() }
      touchLast = p; touchStart = p; touchLatest = p; touchOwner = session; touchDisplay = display; touchKind = "pending"
      let mode = value["mode"] as? String ?? "auto"
      touchReduceMotion = value["reduceMotion"] as? Bool ?? false
      touchForceScroll = mode == "scroll"; scrollDisplay = display
      if mode == "select" { touchTarget = .drag }
      else if mode == "scroll" { touchTarget = .scroll }
      else {
        touchTarget = nil; touchToken += 1; let token = touchToken
        Task.detached(priority: .userInitiated) { [weak self] in
          let result = TouchTarget.at(p)
          await MainActor.run { [weak self] in
            guard let self, self.touchOwner == session, self.touchToken == token, self.touchKind == "pending", self.touchTarget == nil else { return }
            self.touchTarget = result
            if self.touchLatest != self.touchStart { self.moveTouch(self.touchLatest) }
          }
        }
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(80))
          guard let self, self.touchOwner == session, self.touchToken == token, self.touchKind == "pending", self.touchTarget == nil else { return }
          let dx = self.touchLatest.x - self.touchStart.x, dy = self.touchLatest.y - self.touchStart.y
          self.touchTarget = abs(dy) > abs(dx) * 1.15 ? .scroll : .drag
          if self.touchLatest != self.touchStart { self.moveTouch(self.touchLatest) }
        }
      }
    case "touch:move":
      guard touchOwner == session else { return }
      moveTouch(p, sample: sample)
    case "touch:up":
      guard touchOwner == session else { return }
      if touchKind == "pending" {
        if touchLatest != touchStart {
          if touchTarget == nil { let dx = touchLatest.x - touchStart.x, dy = touchLatest.y - touchStart.y; touchTarget = abs(dy) > abs(dx) * 1.15 ? .scroll : .drag }
          moveTouch(touchLatest)
        }
        else { beginDrag() }
      }
      if touchKind == "drag" {
        let doubleClick = touchClickCount == 2 && hypot(p.x - touchStart.x, p.y - touchStart.y) <= 5
        touchLast = p; releaseTouch()
        if doubleClick, let sequence = value["seq"] as? Int {
          let keyboardOpen = value["keyboardOpen"] as? Bool ?? false
          let token = touchToken
          Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            let notice = keyboardOpen && TouchTarget.clearlyBlank(at: p) ? "touch:dismiss" : TouchTarget.focusedEditable() ? "touch:editable" : ""
            guard !notice.isEmpty else { return }
            await MainActor.run { [weak self] in
              guard let self, self.touchToken == token, self.running, CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(), DesktopSession.shared.engine.touchDisplayID != kCGNullDirectDisplay else { return }
              self.send(["type":notice, "session":session, "seq":sequence])
            }
          }
        }
      }
      else if touchKind == "scroll" { releaseTouch(); startMomentum() }
      else { releaseTouch() }
    case "touch:pinchbegin":
      stopMomentum(); if touchOwner != nil { releaseTouch() }
      touchOwner = session; touchDisplay = display; touchKind = "pinch"; touchLast = p
      mouse(.mouseMoved, p); TouchMagnification.post(0, phase: 1)
    case "touch:pinch":
      guard touchOwner == session, touchKind == "pinch", let delta = value["dx"] as? Double, delta.isFinite, abs(delta) <= 0.4 else { return }
      touchLast = p; mouse(.mouseMoved, p); TouchMagnification.post(delta, phase: 2)
    case "touch:pinchend":
      if touchOwner == session && touchKind == "pinch" { releaseTouch() }
    case "touch:right":
      stopMomentum(); guard touchOwner == nil else { return }; mouse(.mouseMoved, p); mouse(.rightMouseDown, p, .right); mouse(.rightMouseUp, p, .right)
    case "touch:scroll":
      guard touchOwner == nil, let dx = value["dx"] as? Double, let dy = value["dy"] as? Double,
        dx.isFinite, dy.isFinite, abs(dx) <= 200, abs(dy) <= 200 else { return }
      if momentumTimer != nil { stopMomentum() }; scrollDisplay = display; mouse(.mouseMoved, p)
      trackScroll(CGPoint(x: dx, y: dy), at: p, sample: sample)
    default: break
    }
  }
  private func postVoiceFn(_ down: Bool) -> Bool {
    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 63, keyDown: down) else { return false }
    event.type = .flagsChanged; event.flags = down ? .maskSecondaryFn : []; event.post(tap: .cghidEventTap); return true
  }
  private func releaseVoice() {
    guard voiceOwner != nil else { return }; _ = postVoiceFn(false); voiceOwner = nil; voiceRenewed = 0
  }
  private func eventFlags(_ mask: Int) -> CGEventFlags {
    var flags: CGEventFlags = capsLockState() ? .maskAlphaShift : []
    if mask & 1 != 0 { flags.insert(.maskShift) }
    if mask & 2 != 0 { flags.insert(.maskControl) }
    if mask & 4 != 0 { flags.insert(.maskAlternate) }
    if mask & 8 != 0 { flags.insert(.maskCommand) }
    return flags
  }
  private func postModifiers(_ changes: [KeyboardModifierChange]) {
    for change in changes {
      guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: change.code, keyDown: change.down) else { continue }
      event.type = .flagsChanged; event.flags = eventFlags(change.mask); event.post(tap: .cghidEventTap)
    }
  }
  private func inputSourceName() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let property = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "" }
    return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
  }
  private func selectNextInputSource() {
    let filter = [kTISPropertyInputSourceIsEnabled!: true, kTISPropertyInputSourceIsSelectCapable!: true, kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], !sources.isEmpty,
          let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
    let index = sources.firstIndex { CFEqual($0, current) } ?? 0
    _ = TISSelectInputSource(sources[(index + 1) % sources.count])
  }
  private func capsLockState() -> Bool { virtualCaps || physicalCapsLockState() }
  private func physicalCapsLockState() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) }
    defer { IOServiceClose(connection) }
    var locked = false
    return IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS ? locked : CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
  }
  private static let mediaCodes = ["volumeup":0,"volumedown":1,"mute":7,"playpause":16,"nexttrack":17,"prevtrack":18]
  private static let keyCodes: [String: CGKeyCode] = [
    "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
    "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
    "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"enter":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,
    "capslock":57,"isoSection":10,"jisYen":93,"jisUnderscore":94,"jisEisu":102,"jisKana":104,
    "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,"f13":105,"f14":107,"f15":113,"f16":106,"f17":64,"f18":79,"f19":80,"f20":90,
    "numpad0":82,"numpad1":83,"numpad2":84,"numpad3":85,"numpad4":86,"numpad5":87,"numpad6":88,"numpad7":89,"numpad8":91,"numpad9":92,"numpadDecimal":65,"numpadMultiply":67,"numpadPlus":69,"numpadClear":71,"numpadDivide":75,"numpadEnter":76,"numpadMinus":78,"numpadEquals":81,
    "tab":48,"space":49,"`":50,"backspace":51,"escape":53,"home":115,"pageup":116,"delete":117,"end":119,"pagedown":121,"left":123,"right":124,"down":125,"up":126]
}
