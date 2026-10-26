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
  private var running = false
  private var generation = 0
  private var testWindow: NSWindow?

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
      }
    }
    if let leaseTimer { RunLoop.main.add(leaseTimer, forMode: .common) }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.report() }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }
  func stop() { virtualCaps = false; postModifiers(modifierLease.release()); leaseTimer?.invalidate(); leaseTimer = nil; running = false; generation += 1; timer?.invalidate(); timer = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
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
    generation += 1; socket?.cancel(with: .goingAway, reason: nil); socket = nil
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(750))
      guard let self, self.running, self.socket == nil else { return }
      self.connect()
    }
  }
  private func report() {
    permitted = CGPreflightPostEventAccess()
    if !permitted || IsSecureEventInputEnabled() { postModifiers(modifierLease.release()) }
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
      postModifiers(modifierLease.release(owner: session)); return
    }
    guard let id = value["id"] as? String, id.count == 32 else { return }
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
      } else if value["type"] as? String == "keyboard:key", let key = value["key"] as? String, ["capslock", "capslockHold"].contains(key) {
        if !toggleCapsLock(force: key == "capslockHold") { error = "unsupported-key" }
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
        if value["repeat"] as? Bool == true { down.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        postModifiers(KeyboardModifierLease.changes(from: modifiers, to: held))
      } else { error = "invalid" }
    } else { error = "expired" }
    if ProcessInfo.processInfo.arguments.contains("--keyboard-test") { NSLog("KEYBOARD_TEST active=%d permitted=%d secure=%d result=%@", NSApp.isActive, CGPreflightPostEventAccess(), IsSecureEventInputEnabled(), error.isEmpty ? "posted" : error) }
    send(["type": "keyboard:ack", "id": id, "ok": error.isEmpty, "error": error, "inputSource": inputSourceName(), "capsLock": capsLockState()])
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
  private func toggleCapsLock(force: Bool = false) -> Bool {
    // A virtual lock avoids the system's short-Caps input-source remapping.
    // It applies Caps flags to this keyboard's events only, never changes a
    // physical keyboard's persistent lock, and clears when the app stops.
    if force { virtualCaps = true; return true }
    if virtualCaps { virtualCaps = false; return true }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return false }; defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return false }
    defer { IOServiceClose(connection) }
    var locked = false
    guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS else { return false }
    guard IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), force || !locked) == KERN_SUCCESS else { return false }
    // A short Caps event follows the Mac input-source switch setting. A hold
    // locks Caps directly, without re-triggering that short-press remapping.
    if !force, let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 57, keyDown: true) {
      event.type = .flagsChanged
      var flags = eventFlags(modifierLease.mask)
      if !locked { flags.insert(.maskAlphaShift) } else { flags.remove(.maskAlphaShift) }
      event.flags = flags; event.post(tap: .cghidEventTap)
    }
    return true
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
