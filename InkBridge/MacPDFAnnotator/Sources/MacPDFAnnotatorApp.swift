import AppKit
import SwiftUI
import LinkDeskCore
import Darwin

@MainActor
final class InkBridgeAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.arguments.contains("--keyboard-test") { KeyboardHost.shared.showTestWindow() }
    if let iconURL = Bundle.main.url(forResource: "linkdesk-icon", withExtension: "png"), let icon = NSImage(contentsOf: iconURL) {
      NSApp.applicationIconImage = icon
    }
    if ProcessInfo.processInfo.arguments.contains("--background-agent") {
      NSApp.setActivationPolicy(.accessory)
      NSApp.windows.forEach { $0.orderOut(nil) }
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    NSApp.setActivationPolicy(.regular)
    if !flag { NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == L10n.productName })?.makeKeyAndOrderFront(nil) }
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    KeyboardHost.shared.stop()
    LinkDeskTheme.shared.stop()
    DesktopSession.shared.stop()
    LocalRelayLauncher.shared.stop()
  }
}

@main
struct MacPDFAnnotatorApp: App {
  @NSApplicationDelegateAdaptor(InkBridgeAppDelegate.self) private var appDelegate
  @StateObject private var workspace = PDFWorkspace()

  init() {
    if ProcessInfo.processInfo.arguments.contains("--self-test") {
      let ok = LDDesktopController().runDisplaySelfTest()
      print(ok ? "SELF_TEST PASS" : "SELF_TEST FAIL")
      exit(ok ? 0 : 1)
    }
    // Import only missing InkBridge preferences. Existing LinkDesk preferences win.
    if let previous = UserDefaults.standard.persistentDomain(forName: "local.zhekuan.bijiqiao") {
      for (key, value) in previous where key.hasPrefix("InkBridge") && UserDefaults.standard.object(forKey: key) == nil {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    LocalRelayLauncher.shared.startIfNeeded()
    KeyboardHost.shared.start()
  }

  var body: some Scene {
    Window(L10n.productName, id: "main") {
      LinkDeskWorkspaceView()
        .environmentObject(workspace)
        .frame(minWidth: DT.dimensions.d1000, minHeight: DT.dimensions.d680)
        .onAppear { workspace.start() }
        .onOpenURL { url in
          if url.isFileURL && url.pathExtension.lowercased() == "pdf" { workspace.openPDF(at: url) }
        }
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(L10n.openPDF, action: workspace.openPDF)
          .keyboardShortcut("o", modifiers: .command)
        Menu(L10n.recentFiles) {
          if workspace.recentPDFs.isEmpty {
            Button(L10n.recentEmpty) {}
              .disabled(true)
          } else {
            ForEach(workspace.recentPDFs) { recent in
              Button(recent.name) { workspace.openRecent(recent) }
            }
          }
        }
        Divider()
        Button(L10n.sendPDF, action: workspace.startPDFRoundTrip)
      }

      CommandGroup(replacing: .saveItem) {
        Button(L10n.savePDF, action: workspace.saveAs)
          .keyboardShortcut("s", modifiers: [.command, .shift])
          .disabled(!workspace.hasDocument)
      }

      CommandGroup(replacing: .undoRedo) {
        Button(L10n.undo, action: workspace.undo)
          .keyboardShortcut("z", modifiers: .command)
          .disabled(!workspace.canUndo)
        Button(L10n.redo, action: workspace.redo)
          .keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(!workspace.canRedo)
      }

      CommandGroup(after: .pasteboard) {
        Divider()
        Button(L10n.searchMenu, action: workspace.presentSearch)
          .keyboardShortcut("f", modifiers: .command)
          .disabled(workspace.mode != .pdf || !workspace.hasDocument)
      }

      CommandGroup(after: .toolbar) {
        Divider()
        Button(L10n.zoomIn, action: workspace.zoomIn)
          .keyboardShortcut("+", modifiers: .command)
          .disabled(workspace.mode == .pdf && !workspace.hasDocument)
        Button(L10n.zoomOut, action: workspace.zoomOut)
          .keyboardShortcut("-", modifiers: .command)
          .disabled(workspace.mode == .pdf && !workspace.hasDocument)
        Button(workspace.mode == .whiteboard ? L10n.whiteboardOrigin : L10n.fitWindow, action: workspace.zoomToFit)
          .keyboardShortcut("0", modifiers: .command)
          .disabled(workspace.mode == .pdf && !workspace.hasDocument)
        Divider()
        Button(workspace.isToolbarCollapsed ? L10n.expandTools : L10n.collapseTools) {
          workspace.isToolbarCollapsed.toggle()
        }
      }

      CommandMenu(L10n.connect) {
        Button(L10n.connectTablet) { workspace.isShowingPairing = true }
        Divider()
        ForEach(ConnectionPreference.allCases) { preference in
          Button {
            workspace.usbRelay.preference = preference
          } label: {
            if workspace.usbRelay.preference == preference {
              Label(preference.title, systemImage: "checkmark")
            } else {
              Text(preference.title)
            }
          }
        }
        Divider()
        Button(workspace.tabletMirror.isReceiving ? L10n.stopMirror : L10n.startMirror) {
          workspace.toggleTabletMirror()
        }
        .disabled(!workspace.usbRelay.isReady && !workspace.tabletMirror.isReceiving)
      }
    }
  }
}
