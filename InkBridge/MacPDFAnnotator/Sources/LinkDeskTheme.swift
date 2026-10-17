import AppKit
import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable, Codable {
  case automatic, light, dark
  var id: String { rawValue }
  var title: String { switch self { case .automatic: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
}
private struct SharedTheme: Codable {
  var preference: ThemePreference
  var appearance: String
  var revision: Int
}

@MainActor
final class LinkDeskTheme: ObservableObject {
  static let shared = LinkDeskTheme()
  @Published private(set) var preference: ThemePreference
  @Published private(set) var resolvedDark: Bool
  var colorScheme: ColorScheme? { preference == .automatic ? nil : (resolvedDark ? .dark : .light) }
  private var room = ""
  private var timer: Timer?
  private var syncing = false
  private var pending: ThemePreference?
  private var generation = 0

  private init() {
    let saved = ThemePreference(rawValue: UserDefaults.standard.string(forKey: "LinkDeskThemePreference") ?? "automatic") ?? .automatic
    preference = saved
    resolvedDark = saved == .dark || (saved == .automatic && Self.systemDark)
    pending = ThemePreference(rawValue: UserDefaults.standard.string(forKey: "LinkDeskThemePendingPreference") ?? "")
  }
  private static var systemDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
  func start(room: String) {
    guard room != self.room || timer == nil else { return }
    self.room = room; generation += 1
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.synchronize() }
    }
    Task { await synchronize() }
  }
  func stop() { timer?.invalidate(); timer = nil; generation += 1 }
  func select(_ value: ThemePreference) {
    preference = value
    resolvedDark = value == .dark || (value == .automatic && Self.systemDark)
    pending = value
    UserDefaults.standard.set(value.rawValue, forKey: "LinkDeskThemePendingPreference")
    UserDefaults.standard.set(value.rawValue, forKey: "LinkDeskThemePreference")
    Task { await synchronize() }
  }
  private func synchronize() async {
    guard !syncing, let url = URL(string: "http://127.0.0.1:3210/api/appearance"), room.count == 6 else { return }
    syncing = true
    let currentGeneration = generation
    defer { syncing = false }
    do {
      var get = URLRequest(url: url); get.timeoutInterval = 1.5; get.cachePolicy = .reloadIgnoringLocalCacheData
      let (data, response) = try await URLSession.shared.data(for: get)
      guard (response as? HTTPURLResponse)?.statusCode == 200, currentGeneration == generation else { return }
      let shared = try JSONDecoder().decode(SharedTheme.self, from: data)
      let requested = pending ?? (shared.revision == 0 ? preference : shared.preference)
      let appearance = requested == .automatic ? (Self.systemDark ? "dark" : "light") : requested.rawValue
      if pending != nil || shared.revision == 0 || (shared.preference == .automatic && shared.appearance != appearance) {
        let capturedPending = pending
        var put = URLRequest(url: url); put.httpMethod = "PUT"; put.timeoutInterval = 1.5
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONSerialization.data(withJSONObject: ["preference": requested.rawValue, "appearance": appearance, "baseRevision": shared.revision])
        let (updated, result) = try await URLSession.shared.data(for: put)
        guard (result as? HTTPURLResponse)?.statusCode == 200, currentGeneration == generation else { return }
        if pending == capturedPending {
          pending = nil
          UserDefaults.standard.removeObject(forKey: "LinkDeskThemePendingPreference")
          apply(try JSONDecoder().decode(SharedTheme.self, from: updated))
        }
      } else { apply(shared) }
    } catch { /* Preserve the selected appearance during transport changes. */ }
  }
  private func apply(_ theme: SharedTheme) {
    preference = theme.preference; resolvedDark = theme.appearance == "dark"
    UserDefaults.standard.set(preference.rawValue, forKey: "LinkDeskThemePreference")
  }
}
