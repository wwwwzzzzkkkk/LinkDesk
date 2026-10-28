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
  var title: String { switch self {
    case .home: L10n.homeTitle
    case .display: L10n.displayTitle
    case .pdf: L10n.pdfTitle
    case .whiteboard: L10n.whiteboardTitle
    case .mirror: L10n.mirrorTitle
  } }
  var subtitle: String { switch self {
    case .home: L10n.homeSubtitle
    case .display: L10n.displaySubtitle
    case .pdf: L10n.pdfSubtitle
    case .whiteboard: L10n.whiteboardSubtitle
    case .mirror: L10n.mirrorSubtitle
  } }
  var symbol: String { switch self {
    case .home: DT.icon.home
    case .display: DT.icon.display
    case .pdf: DT.icon.pdf
    case .whiteboard: DT.icon.whiteboard
    case .mirror: DT.icon.mirror
  } }
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
  @ObservedObject private var keyboard = KeyboardHost.shared
  @StateObject private var navigation = WorkspaceNavigation()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var selection: LinkDeskDestination? {
    get { navigation.selection }
    nonmutating set { navigation.selection = newValue }
  }
  private var destination: LinkDeskDestination { selection ?? .home }
  private var isCanvas: Bool { destination == .pdf || destination == .whiteboard }
  private var state: ConnectionState { workspace.connectionState(for: destination, engine: desktop.engine) }

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: DT.spacing.s0) {
        HStack(spacing: DT.spacing.s12) {
          Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
            .frame(width: DT.layout.iconTile, height: DT.layout.iconTile)
          VStack(alignment: .leading, spacing: DT.spacing.s4) {
            Text(L10n.productName).font(.system(size: DT.font.section, weight: .semibold, design: .rounded))
            Text(L10n.productSubtitle).font(.system(size: DT.font.caption)).foregroundStyle(DT.secondary)
          }
        }.padding(DT.spacing.s16)
        List(selection: $navigation.selection) {
          ForEach(LinkDeskDestination.allCases) { item in
            Label { Text(item.title) } icon: {
              Image(systemName: item.symbol).foregroundStyle(selection == item ? DT.onAccent : DT.accent)
            }.tag(item)
              .padding(.vertical, DT.spacing.s4)
          }
        }.listStyle(.sidebar)
        VStack(alignment: .leading, spacing: DT.spacing.s12) {
          ConnectionPill(state: state)
          HStack {
            Text(L10n.pairingCode).foregroundStyle(DT.secondary)
            Spacer()
            Text(workspace.room).monospaced().textSelection(.enabled)
          }.font(.system(size: DT.font.caption))
          Picker(L10n.appearance, selection: Binding(get: { theme.preference }, set: { value in theme.select(value) })) {
            ForEach(ThemePreference.allCases) { Text($0.title).tag($0) }
          }.pickerStyle(.menu).help(L10n.themeHelp)
          Button(L10n.pairingTitle) { workspace.isShowingPairing = true }.buttonStyle(.bordered)
          Button(keyboard.permitted ? L10n.keyboardReady : L10n.keyboardPermissionAction) { keyboard.requestPermission() }
            .buttonStyle(.bordered).disabled(keyboard.permitted).help(L10n.keyboardPermissionHint)
        }.padding(DT.spacing.s16)
      }.foregroundStyle(DT.text)
        .navigationSplitViewColumnWidth(min: DT.layout.sidebarMin, ideal: DT.layout.sidebar, max: DT.layout.sidebarMax)
    } detail: {
      ZStack {
        VStack(spacing: DT.spacing.s0) {
          PageHeader(title: destination.title, subtitle: destination.subtitle, state: state)
            .padding(.horizontal, DT.layout.pagePadding).padding(.vertical, DT.spacing.s16)
          ContentView(isActive: isCanvas)
        }.opacity(isCanvas ? 1 : 0).allowsHitTesting(isCanvas).accessibilityHidden(!isCanvas)
        if !isCanvas {
          ScrollView {
            VStack(alignment: .leading, spacing: DT.spacing.s24) {
              PageHeader(title: destination.title, subtitle: destination.subtitle, state: state)
              if destination == .home { home }
              if destination == .display { displaySettings }
              if destination == .mirror { mirrorSettings }
            }.frame(maxWidth: DT.layout.pageMax).padding(DT.layout.pagePadding).frame(maxWidth: .infinity)
          }
        }
      }.background(DT.canvas).navigationTitle(destination.title)
    }
    .tint(DT.accent).preferredColorScheme(navigation.reviewColorScheme ?? theme.colorScheme)
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

  private var home: some View {
    VStack(alignment: .leading, spacing: DT.spacing.s24) {
      SurfacePanel {
        VStack(alignment: .leading, spacing: DT.spacing.s16) {
          Text(L10n.macAndTablet).font(.system(size: DT.font.caption, weight: .semibold, design: .monospaced)).foregroundStyle(DT.accent)
          Text(L10n.heroTitle).font(.system(size: DT.font.title, weight: .semibold, design: .rounded)).foregroundStyle(DT.text)
          Text(L10n.heroSubtitle).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary)
          Button(L10n.connectTablet) { workspace.isShowingPairing = true }.buttonStyle(.borderedProminent).controlSize(.large)
        }
      }
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DT.spacing.s16) {
        ForEach(Array(LinkDeskDestination.allCases.dropFirst())) { item in
          Button { selection = item } label: {
            VStack(alignment: .leading, spacing: DT.spacing.s16) {
              Image(systemName: item.symbol).font(.system(size: DT.font.section, weight: .medium)).foregroundStyle(DT.accent)
                .frame(width: DT.layout.iconTile, height: DT.layout.iconTile)
                .background(DT.accentSoft, in: RoundedRectangle(cornerRadius: DT.radius.small))
              Text(item.title).font(.system(size: DT.font.label, weight: .semibold)).foregroundStyle(DT.text)
              Text(item.subtitle).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(DT.spacing.s24).frame(minHeight: DT.layout.cardMinHeight).background(DT.surface, in: RoundedRectangle(cornerRadius: DT.radius.medium))
              .overlay(RoundedRectangle(cornerRadius: DT.radius.medium).strokeBorder(DT.border, lineWidth: DT.layout.stroke))
              .contentShape(RoundedRectangle(cornerRadius: DT.radius.medium))
          }.buttonStyle(.plain).accessibilityLabel(item.title)
        }
      }
      Text(L10n.connectionHint).font(.system(size: DT.font.caption)).foregroundStyle(DT.secondary)
    }
  }

  private var displaySettings: some View {
    VStack(spacing: DT.spacing.s24) {
      SurfacePanel {
        SettingRow(title: L10n.displayTitle, detail: state.title) {
          Button(desktop.engine.active || desktop.engine.starting ? L10n.stopDisplay : L10n.startDisplay) {
            desktop.perform { $0.toggleDesktop() }
          }.buttonStyle(.borderedProminent)
        }
      }
      SurfacePanel {
        VStack(spacing: DT.spacing.s16) {
          SettingRow(title: L10n.displayScale, detail: L10n.displayScaleDescription) {
            Picker(L10n.displayScale, selection: Binding(get: { desktop.engine.scaleIndex }, set: { value in desktop.perform { $0.selectScale(value) } })) {
              ForEach(Array([L10n.scaleLarger, L10n.scaleLarge, L10n.scaleDefault, L10n.scaleMore, L10n.scaleMost].enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
            }.labelsHidden().frame(maxWidth: DT.layout.formMaxWidth)
          }
          Divider()
          SettingRow(title: L10n.frameRate, detail: L10n.frameRateDescription) {
            Picker(L10n.frameRate, selection: Binding(get: { desktop.engine.targetFPS }, set: { value in desktop.perform { $0.selectFrameRate(value) } })) {
              ForEach([60, 120, 144], id: \.self) { Text(L10n.format("frameRateValue", $0)).tag($0) }
            }.labelsHidden()
          }
          HStack {
            Button(L10n.arrangeDisplays) { desktop.engine.openDisplaySettings() }
            Button(L10n.testDisplay) { desktop.engine.showDisplayTest() }.disabled(!desktop.engine.active)
          }
          Divider()
          SettingRow(title: L10n.colorEnhancement, detail: L10n.colorEnhancementDescription) {
            Picker(L10n.colorEnhancement, selection: Binding(get: { desktop.engine.colorEnhancement }, set: { value in desktop.perform { $0.selectColorEnhancement(value) } })) {
              Text(L10n.colorOriginal).tag(0); Text(L10n.colorGentle).tag(1); Text(L10n.colorStrong).tag(2)
            }.labelsHidden()
          }
          Divider()
          SettingRow(title: L10n.hdrShadows, detail: L10n.hdrShadowsDescription) {
            Picker(L10n.hdrShadows, selection: Binding(get: { desktop.engine.hdrShadows }, set: { value in desktop.perform { $0.selectHDRShadows(value) } })) {
              Text(L10n.hdrShadowsNormal).tag(0); Text(L10n.hdrShadowsSoft).tag(1); Text(L10n.hdrShadowsDeep).tag(2)
            }.labelsHidden().disabled(!desktop.engine.hdrEnabled)
          }
          Divider()
          SettingRow(title: L10n.hdrTitle, detail: desktop.engine.hdrAvailable ? L10n.hdrDescription : L10n.hdrUnavailable) {
            Toggle(L10n.hdrTitle, isOn: Binding(get: { desktop.engine.hdrEnabled }, set: { value in desktop.perform { $0.enableHDR(value) } }))
              .labelsHidden().disabled(!desktop.engine.hdrAvailable && !desktop.engine.hdrEnabled)
          }
        }
      }
      SurfacePanel {
        VStack(spacing: DT.spacing.s16) {
          SettingRow(title: L10n.tabletSpeaker, detail: L10n.speakerDescription) {
            HStack {
              Button(L10n.useTablet) { desktop.perform { $0.selectTabletSpeaker() } }.disabled(!desktop.engine.active)
              Button(L10n.restoreMac) { desktop.perform { $0.restoreMacSpeaker() } }
            }
          }
          Divider()
          SettingRow(title: L10n.tabletMicrophone, detail: L10n.microphoneDescription) {
            Toggle(L10n.tabletMicrophone, isOn: Binding(get: { desktop.engine.microphoneEnabled }, set: { value in desktop.perform { $0.enableMicrophone(value) } })).labelsHidden().disabled(!desktop.engine.active)
          }
          Divider()
          SettingRow(title: L10n.audioDelay, detail: L10n.audioDelayDescription) {
            HStack {
              Slider(value: Binding(get: { desktop.engine.audioDelay }, set: { value in desktop.perform { $0.selectAudioDelay(value) } }), in: 0...150)
              Text(L10n.format("milliseconds", Int(desktop.engine.audioDelay))).monospacedDigit()
            }.frame(maxWidth: DT.layout.formMaxWidth)
          }
        }
      }
    }
  }

  private var mirrorSettings: some View {
    VStack(spacing: DT.spacing.s24) {
      SurfacePanel { MirrorControlPanel(workspace: workspace, mirror: workspace.tabletMirror, usb: workspace.usbRelay) }
      SurfacePanel {
        SettingRow(title: L10n.roundTripTitle, detail: L10n.roundTripDescription) {
          Button(L10n.sendToNotes, action: workspace.startPDFRoundTrip).buttonStyle(.bordered)
        }
      }
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
    for dark in [false, true] {
      for item in LinkDeskDestination.allCases {
      let name = "mac-" + item.rawValue + (dark ? "-dark" : "-light")
      let width = DT.dimensions.d1160
      selection = item
      navigation.reviewColorScheme = dark ? .dark : .light
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.setContentSize(NSSize(width: width, height: DT.dimensions.d800))
      try? await Task.sleep(for: .milliseconds(650))
      guard let view = window.contentView else { continue }
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      if let data = bitmap.representation(using: .png, properties: [:]) {
        try? data.write(to: directory.appendingPathComponent(name + ".png"))
      }
    }
    }
    selection = .home
    window.appearance = nil
    navigation.reviewColorScheme = nil
  }

}

private struct MirrorControlPanel: View {
  @ObservedObject var workspace: PDFWorkspace
  @ObservedObject var mirror: TabletMirrorManager
  @ObservedObject var usb: USBRelayManager
  var body: some View {
    EmptyState(symbol: DT.icon.mirror, title: mirror.isConnected ? L10n.stateWorking : L10n.mirrorEmptyTitle,
      message: L10n.mirrorEmptyDescription, actionTitle: mirror.isReceiving ? L10n.stopMirror : L10n.startMirror,
      action: workspace.toggleTabletMirror, disabled: !usb.isReady && !mirror.isReceiving)
  }
}

extension PDFWorkspace {
  func connectionState(for destination: LinkDeskDestination, engine: LDDesktopController) -> ConnectionState {
    if destination == .display {
      if ["failureMarker", "unavailableMarker"].contains(where: { engine.status.contains(L10n.source($0)) }) { return .error }
      if engine.active && engine.status == L10n.source("stateUSBConnected") { return .working }
      if engine.active || engine.starting { return .waitingForMode }
    }
    if destination == .mirror && tabletMirror.isConnected { return .working }
    if relay.isConnected && relay.peerCount > 1 {
      if destination == .home { return .waitingForMode }
      if destination == .pdf || destination == .whiteboard { return .working }
    }
    if engine.usbReady || usbRelay.isReady { return .usbConnected }
    return .disconnected
  }
}

extension Notification.Name {
  static let linkDeskOpenCanvas = Notification.Name("LinkDeskOpenCanvas")
}
