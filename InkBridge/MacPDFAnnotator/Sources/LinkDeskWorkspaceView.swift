import AppKit
import SwiftUI
import LinkDeskCore

@MainActor
final class DesktopSession: ObservableObject {
  static let shared = DesktopSession()
  let engine = LDDesktopController()
  @Published private(set) var revision = 0
  private var timer: Timer?

  func start() {
    guard timer == nil else { return }
    engine.prepare()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.revision &+= 1 }
    }
  }
  func stop() { timer?.invalidate(); timer = nil; engine.shutdown() }
  func perform(_ action: (LDDesktopController) -> Void) { action(engine); revision &+= 1 }
}

enum LinkDeskDestination: String, CaseIterable, Identifiable {
  case home, display, pdf, whiteboard, mirror
  var id: String { rawValue }
  var title: String {
    switch self {
    case .home: "工作台"
    case .display: "扩展屏幕"
    case .pdf: "PDF 批注"
    case .whiteboard: "实时白板"
    case .mirror: "平板投屏"
    }
  }
  var symbol: String {
    switch self {
    case .home: "square.grid.2x2"
    case .display: "display.2"
    case .pdf: "doc.richtext"
    case .whiteboard: "pencil.and.outline"
    case .mirror: "ipad.and.arrow.forward"
    }
  }
  var subtitle: String {
    switch self {
    case .home: "让 Mac 与 MatePad 一起工作。"
    case .display: "把 MatePad 变成 Mac 的高清扩展屏幕。"
    case .pdf: "在平板上书写，在 Mac 上同步阅读与整理。"
    case .whiteboard: "一块画布，让想法自由延伸。"
    case .mirror: "将平板上的笔记、演示和灵感带到 Mac。"
    }
  }
}

@MainActor
final class WorkspaceNavigation: ObservableObject {
  @Published var selection: LinkDeskDestination? = .home
  @Published var reviewColorScheme: ColorScheme?
}

struct LinkDeskWorkspaceView: View {
  @EnvironmentObject private var workspace: PDFWorkspace
  @ObservedObject private var desktop = DesktopSession.shared
  @ObservedObject private var theme = LinkDeskTheme.shared
  @StateObject private var navigation = WorkspaceNavigation()
  private var selection: LinkDeskDestination? {
    get { navigation.selection }
    nonmutating set { navigation.selection = newValue }
  }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let blue = Color(red: 0.31, green: 0.56, blue: 0.97)
  private var destination: LinkDeskDestination { selection ?? .home }
  private var isCanvas: Bool { destination == .pdf || destination == .whiteboard }

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Image(nsImage: NSImage(contentsOf: Bundle.main.url(forResource: "linkdesk-icon", withExtension: "png") ?? URL(fileURLWithPath: "/")) ?? NSImage())
            .resizable().scaledToFit().frame(width: 38, height: 38)
          VStack(alignment: .leading, spacing: 2) {
            Text("LinkDesk").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("你的跨屏工作空间").font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 25)
        List(selection: $navigation.selection) {
          Label { Text(LinkDeskDestination.home.title) } icon: {
            Image(systemName: LinkDeskDestination.home.symbol).foregroundColor(selection == .home ? .white : blue)
          }.tag(LinkDeskDestination.home)
          Section("工作空间") {
            ForEach([LinkDeskDestination.display, .pdf, .whiteboard, .mirror]) { item in
              Label { Text(item.title) } icon: {
                Image(systemName: item.symbol).foregroundColor(selection == item ? .white : blue)
              }.tag(item)
                .padding(.vertical, 3)
            }
          }
        }.listStyle(.sidebar)
        VStack(alignment: .leading, spacing: 10) {
          Label(desktop.engine.usbReady ? "USB 平板已就绪" : "等待连接平板", systemImage: desktop.engine.usbReady ? "cable.connector" : "ipad.gen2")
            .font(.caption).foregroundStyle(desktop.engine.usbReady ? Color.mint : Color.secondary)
          HStack {
            Text("配对房间").foregroundStyle(.secondary)
            Spacer()
            Text(workspace.room).font(.system(.caption, design: .monospaced).weight(.medium)).textSelection(.enabled)
          }.font(.caption)
          Picker("外观", selection: Binding(get: { theme.preference }, set: theme.select)) {
            ForEach(ThemePreference.allCases) { option in Text(option.title).tag(option) }
          }.pickerStyle(.menu).controlSize(.small)
            .help("跟随 Mac 系统外观，或选择两端同步的浅色／深色主题")
          Button("连接与配对…") { workspace.isShowingPairing = true }
            .buttonStyle(.bordered).controlSize(.small)
        }.padding(18)
      }.navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 270)
    } detail: {
      ZStack {
        // Keep document views alive while visiting devices or display settings.
        // This preserves undo history, viewport and in-progress peer updates.
        ContentView(isActive: isCanvas)
          .opacity(isCanvas ? 1 : 0).allowsHitTesting(isCanvas).accessibilityHidden(!isCanvas)
        if !isCanvas {
          ScrollView {
            VStack(alignment: .leading, spacing: 28) {
              if destination == .home { home }
              if destination == .display { displaySettings }
              if destination == .mirror { mirrorSettings }
            }.frame(maxWidth: 940, alignment: .leading).padding(36).frame(maxWidth: .infinity)
          }.background(Color(nsColor: .windowBackgroundColor))
        }
      }
      .navigationTitle(isCanvas ? workspace.mode.title : destination.title)
    }
    .tint(blue)
    .preferredColorScheme(navigation.reviewColorScheme ?? theme.colorScheme)
    .onAppear { desktop.start(); workspace.start(); theme.start(room: workspace.room) }
    .task { await captureReviewImagesIfRequested() }
    .onChange(of: selection) { _, value in
      if value == .pdf { workspace.selectMode(.pdf) }
      if value == .whiteboard { workspace.selectMode(.whiteboard) }
    }
    .onChange(of: workspace.mode) { _, mode in
      if isCanvas { selection = mode == .pdf ? .pdf : .whiteboard }
    }
    .onReceive(NotificationCenter.default.publisher(for: .linkDeskOpenCanvas)) { _ in
      selection = workspace.mode == .pdf ? .pdf : .whiteboard
    }
  }

  // Explicit developer launch option; renders only this app's own content view.
  @MainActor
  private func captureReviewImagesIfRequested() async {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--ui-snapshots"), index + 1 < arguments.count else { return }
    let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(1))
    guard let window = NSApp.windows.first(where: { $0.title == "LinkDesk" }) ?? NSApp.keyWindow else { return }
    if let fixtureIndex = arguments.firstIndex(of: "--review-pdf"), fixtureIndex + 1 < arguments.count {
      workspace.openPDF(at: URL(fileURLWithPath: arguments[fixtureIndex + 1]))
      try? await Task.sleep(for: .seconds(1))
    }
    for (name, item, dark, width) in [
      ("mac-home", LinkDeskDestination.home, false, 1160.0),
      ("mac-home-dark", .home, true, 1160.0),
      ("mac-home-compact", .home, false, 1000.0),
      ("mac-display", .display, false, 1160.0),
      ("mac-pdf", .pdf, false, 1160.0),
      ("mac-whiteboard", .whiteboard, false, 1160.0),
      ("mac-mirror", .mirror, false, 1160.0)
    ] {
      selection = item
      navigation.reviewColorScheme = dark ? .dark : .light
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.setContentSize(NSSize(width: width, height: 800))
      try? await Task.sleep(for: .milliseconds(650))
      guard let view = window.contentView else { continue }
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      if let data = bitmap.representation(using: .png, properties: [:]) {
        try? data.write(to: directory.appendingPathComponent(name + ".png"))
      }
    }
    selection = .home
    window.appearance = nil
    navigation.reviewColorScheme = nil
  }

  private func heading(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
      Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var home: some View {
    VStack(alignment: .leading, spacing: 28) {
      HStack(alignment: .center, spacing: 28) {
        VStack(alignment: .leading, spacing: 17) {
          Text("MAC + MATEPAD").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(blue)
          heading("让灵感，在屏幕间流动。", "扩展桌面，随手批注，或一起构思。\n你需要的工具，现在都在 LinkDesk。")
          Button { workspace.isShowingPairing = true } label: { Label("连接你的平板", systemImage: "link") }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity, alignment: .leading)
        DeviceComposition().frame(width: 215, height: 165).accessibilityHidden(true)
      }.padding(28).background(LinearGradient(colors: [blue.opacity(0.09), Color.mint.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
      LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
        ForEach([LinkDeskDestination.display, .pdf, .whiteboard, .mirror]) { item in
          Button { selection = item } label: {
            VStack(alignment: .leading, spacing: 14) {
              HStack {
                Image(systemName: item.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(item == .whiteboard ? Color.mint : blue)
                  .frame(width: 44, height: 44).background(blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
              }
              Text(item.title).font(.system(size: 17, weight: .semibold))
              Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading).padding(22).background(.background, in: RoundedRectangle(cornerRadius: 20))
              .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.05)))
              .contentShape(RoundedRectangle(cornerRadius: 20))
          }.buttonStyle(.plain).accessibilityHint("进入\(item.title)")
        }
      }
      HStack(spacing: 10) {
        Image(systemName: "cable.connector").foregroundStyle(blue)
        Text("扩展屏幕与平板投屏使用 USB；PDF 和白板也支持 Wi-Fi。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var displaySettings: some View {
    VStack(alignment: .leading, spacing: 24) {
      heading("多一块屏幕，多一些从容。", LinkDeskDestination.display.subtitle)
      panel {
        HStack(spacing: 20) {
          Image(systemName: "display.2").font(.system(size: 38, weight: .light)).foregroundStyle(blue).frame(width: 72)
          VStack(alignment: .leading, spacing: 7) {
            Label(desktop.engine.status, systemImage: desktop.engine.active ? "circle.fill" : "circle")
              .font(.headline).foregroundStyle(desktop.engine.active ? Color.mint : Color.primary)
            Text(desktop.engine.statusDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Button(desktop.engine.active || desktop.engine.starting ? "停止扩展" : "启动扩展") {
            desktop.perform { $0.toggleDesktop() }
          }.buttonStyle(.borderedProminent).controlSize(.large)
        }
      }
      panel {
        VStack(alignment: .leading, spacing: 20) {
          Text("显示").font(.headline)
          Picker("工作空间", selection: Binding(get: { desktop.engine.scaleIndex }, set: { index in desktop.perform { $0.selectScale(index) } })) {
            ForEach(Array(["更大字体", "较大", "默认", "较多空间", "更多空间"].enumerated()), id: \.offset) { index, label in Text(label).tag(index) }
          }.pickerStyle(.segmented)
          Picker("目标帧率", selection: Binding(get: { desktop.engine.targetFPS }, set: { fps in desktop.perform { $0.selectFrameRate(fps) } })) {
            ForEach([60, 120, 144], id: \.self) { Text("\($0) 帧/秒").tag($0) }
          }.pickerStyle(.segmented)
          Text("高清传输 2880 × 1920。更高帧率取决于 Mac、平板与连接性能。").font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("排列显示器…") { desktop.engine.openDisplaySettings() }
            Button("显示测试画面") { desktop.engine.showDisplayTest() }.disabled(!desktop.engine.active)
          }
        }
      }
      panel {
        VStack(alignment: .leading, spacing: 18) {
          Text("声音与麦克风").font(.headline)
          HStack {
            Label("平板扬声器", systemImage: "speaker.wave.2")
            Spacer()
            Button("使用平板") { desktop.perform { $0.selectTabletSpeaker() } }.disabled(!desktop.engine.active)
            Button("恢复 Mac") { desktop.perform { $0.restoreMacSpeaker() } }
          }
          Text(desktop.engine.audioStatus).font(.caption).foregroundStyle(.secondary)
          Divider()
          Toggle("使用平板麦克风作为 Mac 输入", isOn: Binding(get: { desktop.engine.microphoneEnabled }, set: { enabled in desktop.perform { $0.enableMicrophone(enabled) } }))
            .disabled(!desktop.engine.active)
          Text(desktop.engine.microphoneStatus).font(.caption).foregroundStyle(.secondary)
          Divider()
          HStack {
            Text("Mac 声音延后").font(.callout)
            Slider(value: Binding(get: { desktop.engine.audioDelay }, set: { delay in desktop.perform { $0.selectAudioDelay(delay) } }), in: 0...150)
            Text("\(Int(desktop.engine.audioDelay)) ms").monospacedDigit().font(.caption).frame(width: 52)
          }
        }
      }
    }
  }

  private var mirrorSettings: some View {
    VStack(alignment: .leading, spacing: 26) {
      heading("把平板上的精彩，带到 Mac。", LinkDeskDestination.mirror.subtitle)
      MirrorControlPanel(workspace: workspace, mirror: workspace.tabletMirror, usb: workspace.usbRelay)
      panel {
        VStack(alignment: .leading, spacing: 14) {
          Label("一份 PDF，顺畅往返", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard").font(.headline)
          Text("发送到平板的华为笔记进行批注，再通过分享菜单回传 LinkDesk。也可以一边书写，一边投屏到 Mac。")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Button("发送 PDF 到华为笔记…", action: workspace.startPDFRoundTrip).buttonStyle(.bordered)
        }
      }
    }
  }

  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content().frame(maxWidth: .infinity, alignment: .leading).padding(24)
      .background(.background, in: RoundedRectangle(cornerRadius: 20))
      .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.05)))
  }
}

private struct MirrorControlPanel: View {
  @ObservedObject var workspace: PDFWorkspace
  @ObservedObject var mirror: TabletMirrorManager
  @ObservedObject var usb: USBRelayManager
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "ipad.gen2.landscape").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(Color.accentColor).padding(.top, 20)
      Text(mirror.status).font(.headline)
      Text("通过 USB 传输平板全屏画面。首次启动时，请在平板上允许录屏。")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button(mirror.isReceiving ? "停止平板投屏" : "开始平板投屏", action: workspace.toggleTabletMirror)
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!usb.isReady && !mirror.isReceiving)
      if !usb.isReady { Text(usb.usbStatus).font(.caption).foregroundStyle(.secondary) }
    }.padding(28).frame(maxWidth: .infinity)
      .background(.background, in: RoundedRectangle(cornerRadius: 24))
  }
}

private struct DeviceComposition: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 23).fill(Color.mint.opacity(0.09)).frame(width: 190, height: 145).rotationEffect(.degrees(-8))
      VStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.5))
          .overlay(Image(systemName: "macwindow").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(Color.accentColor.opacity(0.55)))
        Rectangle().fill(Color.accentColor.opacity(0.2)).frame(width: 22, height: 13)
        Capsule().fill(Color.accentColor.opacity(0.25)).frame(width: 58, height: 4)
      }.frame(width: 150, height: 115).offset(x: -17, y: -7)
      RoundedRectangle(cornerRadius: 11).fill(.regularMaterial).frame(width: 83, height: 111)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.mint.opacity(0.7), lineWidth: 1.5))
        .overlay(Image(systemName: "pencil.tip.crop.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Color.mint))
        .rotationEffect(.degrees(8)).offset(x: 62, y: 25)
    }
  }
}

extension Notification.Name {
  static let linkDeskOpenCanvas = Notification.Name("LinkDeskOpenCanvas")
}
