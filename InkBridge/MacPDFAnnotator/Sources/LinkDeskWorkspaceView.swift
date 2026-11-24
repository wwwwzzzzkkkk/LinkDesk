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
  @AppStorage("LinkDeskSidebarCollapsed") private var prefersCompactSidebar = false
  @State private var displayedDestination: LinkDeskDestination = .home
  @State private var contentVisible = true
  @State private var contentOffset: CGFloat = 0
  @State private var cardsVisible = false
  @State private var connectionPaused = false
  @State private var fileDrag = SidebarFileDragState()

  private var destination: LinkDeskDestination { navigation.selection ?? .home }
  private var isCanvas: Bool { displayedDestination == .pdf || displayedDestination == .whiteboard }
  private var state: ConnectionState {
    connectionPaused ? .disconnected : workspace.connectionState(for: destination, engine: desktop.engine)
  }

  private var sidebarDevice: SidebarTabletStatus {
    let engine = desktop.engine
    let mic = engine.microphoneStatus
    let microphoneTransport: ConnectionTransport? =
      mic.contains("Wi-Fi") ? .wifi : (mic.contains("USB") || mic.contains(L10n.source("micInputActiveMarker")) ? .usb : nil)
    guard !connectionPaused else { return SidebarTabletStatus() }
    let home = workspace.connectionState(for: .home, engine: engine)
    guard home.isConnected || engine.wirelessMicrophoneActive else { return SidebarTabletStatus() }
    let transport: ConnectionTransport
    if workspace.relay.isConnected, workspace.relay.peerCount > 1, let actual = workspace.relay.tabletTransport {
      transport = actual
    } else if workspace.tabletMirror.isConnected || engine.usbReady || workspace.usbRelay.isReady {
      transport = .usb
    } else {
      transport = microphoneTransport ?? workspace.usbRelay.activeTransport ?? .wifi
    }
    return SidebarTabletStatus(transport: transport, keyboardReady: keyboard.permitted,
      microphoneTransport: microphoneTransport)
  }

  var body: some View {
    GeometryReader { geometry in
      let forcedCompact = geometry.size.width < DT.layout.sidebarCollapseBreakpoint
      let compact = forcedCompact || prefersCompactSidebar
      let sidebarWidth = compact ? DT.layout.sidebarCompact : SidebarDesign.width
      let pageWidth = min(DT.layout.pageMax, geometry.size.width - sidebarWidth - DT.spacing.s64)
      HStack(spacing: DT.spacing.s16) {
        WorkspaceSidebar(compact: compact, selection: destination, device: sidebarDevice,
          pairingCode: workspace.room, theme: theme, keyboard: keyboard, fileDrag: fileDrag,
          navigate: { navigation.selection = $0 },
          connect: { workspace.isShowingPairing = true }, disconnect: disconnectTablet)
          .frame(width: sidebarWidth)
          .padding(.leading, DT.spacing.s16)
          .padding(.vertical, DT.spacing.s16)
          .animation(reduceMotion ? nil : .snappy(duration: DT.motion.workspaceEnter, extraBounce: 0), value: compact)
        VStack(spacing: DT.spacing.s16) {
          PageHeader(title: destination.title, subtitle: destination.subtitle, state: state, home: destination == .home)
            .frame(maxWidth: DT.layout.pageMax)
            .padding(.horizontal, DT.spacing.s16)
            .padding(.top, DT.spacing.s16)
            .accessibilityAddTraits(.isHeader)
          pageContent(width: pageWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .coordinateSpace(name: SidebarFileDragState.coordinateSpace)
      .modifier(SidebarWindowDrop(available: sidebarDevice.isConnected, state: fileDrag))
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button { prefersCompactSidebar.toggle() } label: {
            Label(compact ? L10n.expandSidebar : L10n.collapseSidebar, systemImage: DT.icon.sidebar)
          }.disabled(forcedCompact)
        }
      }
      .modifier(WorkspaceToolbarBackground())
    }
    .background {
      LinearGradient(colors: [DT.workspaceWash, DT.workspaceCanvas, DT.workspaceGlow],
        startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
    .background(WorkspaceWindowChrome())
    .tint(DT.workspaceAccent).preferredColorScheme(navigation.reviewColorScheme ?? theme.colorScheme)
    .onAppear { desktop.start(); workspace.start(); theme.start(room: workspace.room) }
    .task(id: workspace.room) { WorkspaceFiles.shared.start(room: workspace.room) }
    .task { await captureReviewImagesIfRequested() }
    .task(id: destination) { await present(destination) }
    .onChange(of: workspace.isShowingPairing) { _, showing in
      guard showing, connectionPaused else { return }
      connectionPaused = false
      desktop.start()
      keyboard.start()
      workspace.relay.connect(room: workspace.room)
    }
    .onChange(of: workspace.mode) { _, mode in
      if destination == .pdf || destination == .whiteboard {
        navigation.selection = mode == .pdf ? .pdf : .whiteboard
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .linkDeskOpenCanvas)) { _ in
      navigation.selection = workspace.mode == .pdf ? .pdf : .whiteboard
    }
  }

  private func disconnectTablet() {
    if workspace.tabletMirror.isReceiving { workspace.toggleTabletMirror() }
    workspace.relay.disconnect()
    desktop.stop()
    keyboard.stop()
    connectionPaused = true
  }

  private func pageContent(width: CGFloat) -> some View {
    ZStack(alignment: .top) {
      VStack(spacing: DT.spacing.s16) {
        if isCanvas && state == .disconnected {
          connectionAction
            .frame(maxWidth: DT.layout.pageMax)
            .padding(.horizontal, DT.spacing.s16)
        }
        ContentView(isActive: isCanvas)
      }
      .opacity(isCanvas ? 1 : 0).allowsHitTesting(isCanvas).accessibilityHidden(!isCanvas)

      if !isCanvas {
        ScrollView {
          Group {
            switch displayedDestination {
            case .home: home(width: width)
            case .display: displaySettings
            case .mirror: mirrorSettings
            default: EmptyView()
            }
          }
          .frame(maxWidth: DT.layout.pageMax)
          .padding(.horizontal, DT.spacing.s16)
          .padding(.bottom, DT.spacing.s32)
          .frame(maxWidth: .infinity)
        }
        .modifier(WorkspaceScrollEdges())
        .id(displayedDestination)
      }
    }
    .opacity(contentVisible ? 1 : 0)
    .offset(y: contentOffset)
    .clipped()
  }

  @MainActor private func present(_ next: LinkDeskDestination) async {
    if next != displayedDestination {
      withAnimation(.easeOut(duration: DT.motion.workspaceExit)) { contentVisible = false }
      do { try await Task.sleep(for: .seconds(DT.motion.workspaceExit)) } catch { return }
      guard !Task.isCancelled else { return }
      cardsVisible = false
      contentOffset = reduceMotion ? 0 : DT.spacing.s8
      displayedDestination = next
      if next == .pdf { workspace.selectMode(.pdf) }
      if next == .whiteboard { workspace.selectMode(.whiteboard) }
      // Commit the incoming layout at its initial offset before animating it.
      do { try await Task.sleep(for: .seconds(DT.motion.workspaceLayoutFrame)) } catch { return }
    }
    guard !Task.isCancelled else { return }
    withAnimation(DT.motion.workspace(DT.motion.workspaceEnter)) {
      contentOffset = 0
      contentVisible = true
    }
    cardsVisible = true
  }

  private var connectionAction: some View {
    SurfacePanel {
      SettingRow(title: L10n.pairingTitle, detail: L10n.connectionHint) {
        WorkspacePrimaryButton(title: L10n.connectTablet) { workspace.isShowingPairing = true }
      }
    }
  }

  private func home(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: DT.spacing.s24) {
      SurfacePanel {
        HStack(spacing: DT.spacing.s24) {
          heroCopy
          Spacer(minLength: DT.spacing.s0)
          if width >= DT.layout.singleColumnBreakpoint { WorkspaceDeviceIllustration() }
        }.padding(DT.spacing.s16)
      }
      .overlay {
        if state.isConnected { WorkspaceConnectionRim() }
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DT.spacing.s16),
        count: width >= DT.layout.workspaceFourCards ? 4 : 2), spacing: DT.spacing.s16) {
        ForEach(Array(LinkDeskDestination.allCases.dropFirst().enumerated()), id: \.element) { index, item in
          Button { navigation.selection = item } label: {
            SurfacePanel {
              VStack(alignment: .leading, spacing: DT.spacing.s16) {
                Image(systemName: item.symbol).font(.system(size: DT.font.section, weight: .medium)).foregroundStyle(DT.secondary)
                  .frame(width: DT.layout.iconTile, height: DT.layout.iconTile)
                  .background(DT.workspaceControl, in: RoundedRectangle(cornerRadius: DT.radius.small))
                VStack(alignment: .leading, spacing: DT.spacing.s8) {
                  Text(item.title).font(.system(size: DT.font.label, weight: .semibold)).foregroundStyle(DT.text)
                  Text(item.subtitle).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary).fixedSize(horizontal: false, vertical: true)
                }
              }.frame(maxWidth: .infinity, minHeight: DT.layout.cardMinHeight - DT.spacing.s48, alignment: .topLeading)
            }.contentShape(RoundedRectangle(cornerRadius: DT.radius.large))
          }.buttonStyle(.plain).accessibilityLabel(item.title)
            .opacity(cardsVisible || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: DT.motion.workspaceCard)
              .delay(Double(index) * DT.motion.workspaceStagger), value: cardsVisible)
        }
      }
    }
  }

  private var heroCopy: some View {
    VStack(alignment: .leading, spacing: DT.spacing.s16) {
      Text(L10n.macAndTablet).font(.system(size: DT.font.caption, weight: .semibold)).tracking(2).foregroundStyle(DT.secondary)
      Text(L10n.heroTitle).font(.system(size: DT.font.title, weight: .bold)).foregroundStyle(DT.text)
        .fixedSize(horizontal: false, vertical: true)
      Text(L10n.heroSubtitle).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary)
      if state.isConnected {
        Button(L10n.pairingTitle) { workspace.isShowingPairing = true }
          .buttonStyle(.bordered).tint(DT.text)
      } else {
        WorkspacePrimaryButton(title: L10n.connectTablet) { workspace.isShowingPairing = true }
      }
    }
  }

  private var displaySettings: some View {
    let running = desktop.engine.active || desktop.engine.starting
    let canStart = desktop.engine.usbReady || workspace.usbRelay.isReady
    return VStack(spacing: DT.spacing.s24) {
      if !canStart && !running {
        connectionAction
      } else {
        SurfacePanel(highlighted: canStart) {
          SettingRow(title: L10n.displayTitle, detail: state.title) {
            WorkspacePrimaryButton(title: running ? L10n.stopDisplay : L10n.startDisplay) {
              desktop.perform { $0.toggleDesktop() }
            }
          }
        }
      }
      SurfacePanel {
        VStack(spacing: DT.spacing.s16) {
          SettingRow(title: L10n.displayScale, detail: L10n.displayScaleDescription) {
            Picker(L10n.displayScale, selection: Binding(get: { desktop.engine.scaleIndex }, set: { value in desktop.perform { $0.selectScale(value) } })) {
              ForEach(Array([L10n.scaleLarger, L10n.scaleLarge, L10n.scaleDefault, L10n.scaleMore, L10n.scaleMost].enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
            }.labelsHidden().frame(width: DT.layout.workspaceControlWidth, alignment: .trailing)
          }
          Divider()
          SettingRow(title: L10n.frameRate, detail: L10n.frameRateDescription) {
            Picker(L10n.frameRate, selection: Binding(get: { desktop.engine.targetFPS }, set: { value in desktop.perform { $0.selectFrameRate(value) } })) {
              ForEach([60, 120, 144], id: \.self) { Text(L10n.format("frameRateValue", $0)).tag($0) }
            }.labelsHidden().frame(width: DT.layout.workspaceControlWidth, alignment: .trailing)
          }
          Divider()
          SettingRow(title: L10n.colorEnhancement, detail: L10n.colorEnhancementDescription) {
            Picker(L10n.colorEnhancement, selection: Binding(get: { desktop.engine.colorEnhancement }, set: { value in desktop.perform { $0.selectColorEnhancement(value) } })) {
              Text(L10n.colorOriginal).tag(0); Text(L10n.colorGentle).tag(1); Text(L10n.colorStrong).tag(2)
            }.labelsHidden().frame(width: DT.layout.workspaceControlWidth, alignment: .trailing)
          }
          Divider()
          SettingRow(title: L10n.hdrShadows, detail: L10n.hdrShadowsDescription) {
            Picker(L10n.hdrShadows, selection: Binding(get: { desktop.engine.hdrShadows }, set: { value in desktop.perform { $0.selectHDRShadows(value) } })) {
              Text(L10n.hdrShadowsNormal).tag(0); Text(L10n.hdrShadowsSoft).tag(1); Text(L10n.hdrShadowsDeep).tag(2)
            }.labelsHidden().frame(width: DT.layout.workspaceControlWidth, alignment: .trailing).disabled(!desktop.engine.hdrEnabled)
          }
          Divider()
          SettingRow(title: L10n.hdrTitle, detail: desktop.engine.hdrAvailable ? L10n.hdrDescription : L10n.hdrUnavailable) {
            Toggle(L10n.hdrTitle, isOn: Binding(get: { desktop.engine.hdrEnabled }, set: { value in desktop.perform { $0.enableHDR(value) } }))
              .labelsHidden().disabled(!desktop.engine.hdrAvailable && !desktop.engine.hdrEnabled)
          }
          Divider()
          HStack {
            Button(L10n.arrangeDisplays) { desktop.engine.openDisplaySettings() }
            Button(L10n.testDisplay) { desktop.engine.showDisplayTest() }.disabled(!desktop.engine.active)
            Spacer()
          }
        }
      }.opacity(canStart || running ? 1 : DT.motion.workspaceDim)
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
      }.opacity(canStart || running ? 1 : DT.motion.workspaceDim)
    }
  }

  private var mirrorSettings: some View {
    VStack(spacing: DT.spacing.s24) {
      if !workspace.usbRelay.isReady && !workspace.tabletMirror.isReceiving { connectionAction }
      SurfacePanel(highlighted: workspace.tabletMirror.isConnected) {
        MirrorControlPanel(workspace: workspace, mirror: workspace.tabletMirror, usb: workspace.usbRelay)
      }.opacity(workspace.usbRelay.isReady || workspace.tabletMirror.isReceiving ? 1 : DT.motion.workspaceDim)
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
      navigation.reviewColorScheme = dark ? .dark : .light
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      for width in [DT.dimensions.d1160, DT.layout.workspaceMinimum] {
        window.setContentSize(NSSize(width: width, height: DT.dimensions.d800))
        for item in LinkDeskDestination.allCases {
          navigation.selection = item
          let name = "mac-" + item.rawValue + (dark ? "-dark" : "-light")
            + (width == DT.layout.workspaceMinimum ? "-compact" : "")
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
    }
    navigation.selection = .home
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
    if destination == .home && (engine.wirelessMicrophoneActive ||
        (engine.active && engine.status == L10n.source("stateUSBConnected"))) { return .working }
    if (destination == .mirror || destination == .home) && tabletMirror.isConnected { return .working }
    if relay.isConnected && relay.peerCount > 1 {
      if destination == .home { return .working }
      if destination == .pdf || destination == .whiteboard { return .working }
    }
    if destination == .display && (engine.usbReady || usbRelay.isReady) { return .usbConnected }
    return .disconnected
  }
}

extension Notification.Name {
  static let linkDeskOpenCanvas = Notification.Name("LinkDeskOpenCanvas")
}
