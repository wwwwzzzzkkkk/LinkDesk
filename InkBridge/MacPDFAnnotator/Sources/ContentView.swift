import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ContentView: View {
  var isActive = true
  @EnvironmentObject private var workspace: PDFWorkspace
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  var body: some View {
    ZStack(alignment: .topLeading) {
      ZStack {
        PDFCanvasRepresentable(workspace: workspace)
          .opacity(workspace.mode == .pdf ? 1 : 0)
          .allowsHitTesting(workspace.mode == .pdf)
        WhiteboardCanvasRepresentable(workspace: workspace)
          .opacity(workspace.mode == .whiteboard ? 1 : 0)
          .allowsHitTesting(workspace.mode == .whiteboard)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .top)
      // AppKit's PDF ink preview is deliberately rendered at native
      // resolution. Keep that backing layer inside the immersive document
      // region while the glass toolbar intercepts input above it.
      .clipped()

      if workspace.isSearchPresented, workspace.mode == .pdf {
        MacSearchOverlay(workspace: workspace)
          .padding(.top, DT.spacing.s12)
          .transition(searchTransition)
          .zIndex(3)
      }
    }
    .overlay {
      if workspace.mode == .pdf && !workspace.hasDocument {
        VStack(spacing: DT.spacing.s16) {
          EmptyState(symbol: DT.icon.pdf, title: L10n.pdfEmptyTitle, message: L10n.pdfEmptyDescription,
            actionTitle: L10n.openPDF, action: workspace.openPDF)
          if !workspace.recentPDFs.isEmpty {
            Menu(L10n.recentFiles) {
              ForEach(workspace.recentPDFs) { recent in Button(recent.name) { workspace.openRecent(recent) } }
            }.menuStyle(.borderlessButton).frame(width: DT.dimensions.d120)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DT.canvas)
      }
    }
    .background(WindowLiquidGlassConfigurator())
    .toolbar {
      if isActive && workspace.isToolbarCollapsed {
        ToolbarItem(placement: .navigation) {
          CollapsedMacToolbarButton(workspace: workspace)
        }
      } else if isActive {
        ToolbarItem(placement: .navigation) {
          MacModePicker(workspace: workspace)
        }
        ToolbarItem(placement: .principal) {
          MacToolbarTitle(workspace: workspace)
        }
        ToolbarItemGroup(placement: .primaryAction) {
          MacConnectionMenu(
            workspace: workspace,
            relay: workspace.relay,
            usbRelay: workspace.usbRelay
          )
          .frame(width: DT.dimensions.d112)
          MacScreenMirrorToolbarButton(
            mirror: workspace.tabletMirror,
            usbRelay: workspace.usbRelay,
            action: workspace.toggleTabletMirror
          )
          MacToolbarActionButton(
            title: workspace.hasDocument ? L10n.searchHelp : L10n.searchUnavailable,
            accessibilityLabel: L10n.searchPDF,
            systemImage: "magnifyingglass",
            disabled: workspace.mode != .pdf || !workspace.hasDocument,
            action: workspace.presentSearch
          )
          MacToolbarActionButton(
            title: L10n.collapseTools,
            accessibilityLabel: L10n.collapseTools,
            systemImage: "chevron.up"
          ) {
            workspace.isToolbarCollapsed = true
          }
        }
      }
    }
    .overlay(alignment: .bottom) {
      if !workspace.exportStatus.isEmpty {
        MacDocumentStatusToast(status: workspace.exportStatus)
          .padding(.bottom, DT.spacing.s12)
          .transition(statusTransition)
      }
    }
    .sheet(isPresented: $workspace.isShowingPairing) {
      PairingView(link: workspace.pairingLink, room: workspace.room, usbRelay: workspace.usbRelay)
    }
    .animation(
      accessibilityReduceMotion
        ? nil
        : DT.motion.standard(DT.motion.collapse),
      value: workspace.isToolbarCollapsed
    )
    .animation(
      accessibilityReduceMotion
        ? nil
        : DT.motion.enter(DT.motion.menuEnter),
      value: workspace.isSearchPresented
    )
    .animation(
      accessibilityReduceMotion
        ? nil
        : DT.motion.enter(DT.motion.menuEnter),
      value: workspace.exportStatus.isEmpty
    )
  }

  private var searchTransition: AnyTransition {
    if accessibilityReduceMotion {
      return .opacity
    }
    return .scale(scale: DT.motion.searchScale, anchor: .top)
      .combined(with: .offset(y: -DT.spacing.s12))
      .combined(with: .opacity)
  }

  private var statusTransition: AnyTransition {
    if accessibilityReduceMotion {
      return .opacity
    }
    return .modifier(
      active: MacStatusToastMorphModifier(progress: 0),
      identity: MacStatusToastMorphModifier(progress: 1)
    )
  }
}

private struct WindowLiquidGlassConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowLiquidGlassConfigurationView {
    WindowLiquidGlassConfigurationView()
  }

  func updateNSView(_ nsView: WindowLiquidGlassConfigurationView, context: Context) {
    nsView.configureWindow()
  }
}

private final class WindowLiquidGlassConfigurationView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindow()
  }

  func configureWindow() {
    guard let window else { return }
    window.styleMask.remove(.fullSizeContentView)
    window.titlebarAppearsTransparent = false
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.toolbar?.showsBaselineSeparator = false
    window.isMovableByWindowBackground = false
    window.isOpaque = true
    window.backgroundColor = NSColor(DT.canvas)
  }
}

private struct MacModePicker: View {
  @ObservedObject var workspace: PDFWorkspace

  var body: some View {
    Picker(
      L10n.modePicker,
      selection: Binding(
        get: { workspace.mode },
        set: { value in workspace.selectMode(value) }
      )
    ) {
      ForEach(AppMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.small)
    .frame(width: DT.dimensions.d144)
    .help(L10n.modePickerHelp)
  }
}

private struct MacToolbarActionButton: View {
  let title: String
  let accessibilityLabel: String
  let systemImage: String
  var disabled = false
  let action: () -> Void

  var body: some View {
    Group {
      if #available(macOS 26.0, *) {
        button.buttonStyle(.glass)
      } else {
        button.buttonStyle(.borderless)
      }
    }
  }

  private var button: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .foregroundStyle(DT.text.opacity(DT.motion.muted))
        .frame(width: DT.spacing.s24, height: DT.spacing.s24)
    }
    .disabled(disabled)
    .help(title)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct MacScreenMirrorToolbarButton: View {
  @ObservedObject var mirror: TabletMirrorManager
  @ObservedObject var usbRelay: USBRelayManager
  let action: () -> Void

  var body: some View {
    MacToolbarActionButton(
      title: mirror.isConnected ? L10n.stateWorking : L10n.mirrorEmptyDescription,
      accessibilityLabel: mirror.isReceiving ? L10n.stopMirror : L10n.startMirror,
      systemImage: mirror.isConnected ? "ipad.gen2.landscape" : "rectangle.inset.filled.and.person.filled",
      disabled: !usbRelay.isReady && !mirror.isReceiving,
      action: action
    )
  }
}

private struct MacToolbarTitle: View {
  @ObservedObject var workspace: PDFWorkspace

  var body: some View {
    VStack(spacing: DT.spacing.s4) {
      Text(workspace.mode == .pdf ? workspace.documentName : L10n.whiteboardTitle)
        .font(.system(size: DT.font.caption, weight: .semibold))
        .foregroundStyle(DT.text.opacity(DT.motion.muted))
        .lineLimit(1)
        .truncationMode(.middle)
      Text(L10n.format("pairingCodeValue", workspace.room))
        .font(.system(size: DT.font.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(DT.text.opacity(DT.motion.muted))
        .lineLimit(1)
    }
    .frame(minWidth: DT.dimensions.d112, idealWidth: DT.dimensions.d220, maxWidth: DT.dimensions.d320)
    .help(workspace.mode == .pdf ? workspace.documentName : L10n.whiteboardTitle)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      workspace.documentName + ", " + L10n.format("pairingCodeValue", workspace.room)
    )
  }
}

private struct MacConnectionMenu: View {
  @ObservedObject var workspace: PDFWorkspace
  @ObservedObject var relay: RelayClient
  @ObservedObject var usbRelay: USBRelayManager

  var body: some View {
    Menu {
      Button {
        workspace.isShowingPairing = true
      } label: {
        Label(L10n.connectTablet, systemImage: "ipad.and.arrow.forward")
      }

      Divider()

      ForEach(ConnectionPreference.allCases) { preference in
        Button {
          usbRelay.preference = preference
        } label: {
          if usbRelay.preference == preference {
            Label(preference.title, systemImage: "checkmark")
          } else {
            Text(preference.title)
          }
        }
      }

      Divider()

      Label(presentation.title, systemImage: relay.isConnected ? "checkmark.circle" : "exclamationmark.circle")
        .disabled(true)
      Label(usbRelay.activeTransport == .wifi ? L10n.transportWireless : L10n.transportUSB, systemImage: transportSystemImage)
        .disabled(true)
      Text(L10n.format("pairingCodeValue", workspace.room))
        .disabled(true)

      if !relay.documentStatus.isEmpty {
        Divider()
        Label(relay.documentStatus, systemImage: "doc.badge.arrow.up")
          .disabled(true)
      }
      if relay.canCancelPDFTransfer {
        Button(role: .cancel, action: relay.cancelPDFUpload) {
          Label(L10n.cancelTransfer, systemImage: "xmark.circle")
        }
      }
      if relay.canRetryPDFTransfer {
        Button(action: relay.retryPDFUpload) {
          Label(L10n.retryTransfer, systemImage: "arrow.clockwise")
        }
      }
    } label: {
      HStack(spacing: DT.spacing.s4) {
        Circle()
          .fill(statusColor)
          .frame(width: DT.spacing.s8, height: DT.spacing.s8)
        Label(connectionLabel, systemImage: transportSystemImage)
          .labelStyle(.titleAndIcon)
          .font(.system(size: DT.font.caption, weight: .medium))
          .foregroundStyle(DT.text.opacity(DT.motion.muted))
      }
    }
    .menuIndicator(.visible)
    .help(presentation.title)
    .accessibilityLabel(L10n.connectionStatus + ": " + presentation.title)
  }

  private var presentation: ConnectionState {
    workspace.connectionState(for: workspace.mode == .pdf ? .pdf : .whiteboard, engine: DesktopSession.shared.engine)
  }
  private var connectionLabel: String { presentation.title }

  private var transportSystemImage: String {
    switch usbRelay.activeTransport ?? relay.tabletTransport {
    case .usb: return "cable.connector"
    case .wifi: return "wifi"
    case nil: return "ipad.and.arrow.forward"
    }
  }

  private var statusColor: Color { presentation.color }

}

private struct MacDocumentStatusToast: View {
  let status: String

  private var isFailure: Bool {
    ["failureMarker", "unavailableMarker", "insufficientMarker"].contains { status.contains(L10n.source($0)) || status.contains(L10n.value($0)) }
  }

  var body: some View {
    Label(status, systemImage: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
      .font(.system(size: DT.font.caption, weight: .medium))
      .foregroundStyle(isFailure ? DT.error : DT.secondary)
      .lineLimit(1)
      .padding(.horizontal, DT.spacing.s12)
      .frame(height: DT.spacing.s32)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().stroke(DT.text.opacity(DT.motion.border), lineWidth: DT.layout.stroke))
      .shadow(color: DT.scrim.opacity(DT.motion.border), radius: DT.spacing.s8, y: DT.spacing.s4)
      .accessibilityLabel(status)
  }
}

private struct MacStatusToastMorphModifier: AnimatableModifier {
  nonisolated(unsafe) var progress: CGFloat

  nonisolated var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let value = min(1, max(0, progress))
    content
      .scaleEffect(
        x: DT.motion.menuScale + (1 - DT.motion.menuScale) * value,
        y: DT.motion.menuScale + (1 - DT.motion.menuScale) * value,
        anchor: .center
      )
      .opacity(value)
      .blur(radius: (1 - value) * DT.spacing.s4)
      .clipShape(Capsule())
  }
}

private struct CollapsedMacToolbarButton: View {
  @ObservedObject var workspace: PDFWorkspace

  var body: some View {
    Group {
      if #available(macOS 26.0, *) {
        expandButton
          .buttonStyle(.glass)
      } else {
        expandButton
          .buttonStyle(.plain)
          .background(.regularMaterial, in: Circle())
          .overlay(Circle().stroke(DT.text.opacity(DT.motion.border), lineWidth: DT.layout.stroke))
          .shadow(color: DT.scrim.opacity(DT.motion.border), radius: DT.spacing.s8, y: DT.spacing.s4)
      }
    }
  }

  private var expandButton: some View {
    Button {
      workspace.isToolbarCollapsed = false
    } label: {
      ZStack(alignment: .topTrailing) {
        Text(L10n.productInitial)
          .font(.system(size: DT.font.caption, weight: .bold))
          .foregroundStyle(DT.text.opacity(DT.motion.muted))
          .frame(width: DT.spacing.s28, height: DT.spacing.s28)
        Circle()
          .fill(workspace.relay.isConnected ? DT.success : DT.warning)
          .frame(width: DT.spacing.s8, height: DT.spacing.s8)
          .overlay(Circle().stroke(DT.surface, lineWidth: DT.layout.stroke))
          .padding(DT.spacing.s4)
      }
    }
    .help(L10n.expandTools)
    .accessibilityLabel(L10n.expandTools)
  }
}

private struct MacSearchOverlay: View {
  @ObservedObject var workspace: PDFWorkspace
  @FocusState private var isFocused: Bool

  var body: some View {
    searchContent
      .background(SearchOutsideClickMonitor(onOutsideClick: workspace.closeSearch))
      .modifier(NativeSearchGlassModifier())
      .shadow(color: DT.scrim.opacity(DT.motion.border), radius: DT.spacing.s12, y: DT.spacing.s4)
      .frame(maxWidth: .infinity, alignment: .center)
      .onAppear { isFocused = true }
      .onExitCommand(perform: workspace.closeSearch)
  }

  private var searchContent: some View {
    HStack(spacing: DT.spacing.s8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(DT.secondary)
      TextField(
        L10n.searchPlaceholder,
        text: Binding(
          get: { workspace.searchQuery },
          set: { value in workspace.updateSearchQuery(value) }
        )
      )
      .textFieldStyle(.plain)
      .frame(width: DT.dimensions.d208)
      .focused($isFocused)
      .onSubmit(workspace.nextSearchResult)

      Text(workspace.searchTotal == 0
        ? (workspace.searchQuery.isEmpty ? "" : L10n.noResults)
        : "\(workspace.searchCurrent)/\(workspace.searchTotal)")
        .font(.system(size: DT.font.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(DT.secondary)
        .frame(minWidth: DT.spacing.s32)

      SearchIconButton(
        title: L10n.previousMatch,
        systemImage: "chevron.up",
        disabled: workspace.searchTotal == 0,
        action: workspace.previousSearchResult
      )
      SearchIconButton(
        title: L10n.nextMatch,
        systemImage: "chevron.down",
        disabled: workspace.searchTotal == 0,
        action: workspace.nextSearchResult
      )
      SearchIconButton(
        title: L10n.closeSearch,
        systemImage: "xmark",
        action: workspace.closeSearch
      )
    }
    .padding(.horizontal, DT.spacing.s8)
    .frame(height: DT.spacing.s40)
  }
}

private struct SearchOutsideClickMonitor: NSViewRepresentable {
  let onOutsideClick: () -> Void

  func makeNSView(context: Context) -> SearchOutsideClickMonitorView {
    let view = SearchOutsideClickMonitorView()
    view.onOutsideClick = onOutsideClick
    return view
  }

  func updateNSView(_ nsView: SearchOutsideClickMonitorView, context: Context) {
    nsView.onOutsideClick = onOutsideClick
  }

  static func dismantleNSView(_ nsView: SearchOutsideClickMonitorView, coordinator: ()) {
    nsView.stopMonitoring()
  }
}

@MainActor
private final class SearchOutsideClickMonitorView: NSView {
  var onOutsideClick: (() -> Void)?
  private var eventMonitor: Any?
  private var activationWorkItem: DispatchWorkItem?
  private var isArmed = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { startMonitoring() }
    else { stopMonitoring() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func startMonitoring() {
    stopMonitoring()
    guard window != nil else { return }
    let activation = DispatchWorkItem { [weak self] in
      guard self?.window != nil else { return }
      self?.isArmed = true
    }
    activationWorkItem = activation
    DispatchQueue.main.asyncAfter(deadline: .now() + DT.motion.menuEnter, execute: activation)
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      guard let self,
            self.isArmed,
            event.window === self.window else { return event }
      let localPoint = self.convert(event.locationInWindow, from: nil)
      if !self.bounds.insetBy(dx: -DT.spacing.s8, dy: -DT.spacing.s8).contains(localPoint) {
        DispatchQueue.main.async { [weak self] in
          self?.onOutsideClick?()
        }
      }
      return event
    }
  }

  func stopMonitoring() {
    activationWorkItem?.cancel()
    activationWorkItem = nil
    isArmed = false
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }
}

private struct NativeSearchGlassModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .glassEffect(.regular, in: Capsule())
    } else {
      content
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(DT.text.opacity(DT.motion.border), lineWidth: DT.layout.stroke))
    }
  }
}

private struct SearchIconButton: View {
  let title: String
  let systemImage: String
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: DT.font.caption, weight: .medium))
        .frame(width: DT.spacing.s24, height: DT.spacing.s24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct WhiteboardCanvasRepresentable: NSViewRepresentable {
  let workspace: PDFWorkspace

  func makeNSView(context: Context) -> WhiteboardCanvasView {
    let view = WhiteboardCanvasView()
    workspace.attach(whiteboardCanvas: view)
    return view
  }

  func updateNSView(_ nsView: WhiteboardCanvasView, context: Context) {}
}

private struct PDFCanvasRepresentable: NSViewRepresentable {
  let workspace: PDFWorkspace

  func makeNSView(context: Context) -> PDFCanvasView {
    let view = PDFCanvasView()
    workspace.attach(canvas: view)
    return view
  }

  func updateNSView(_ nsView: PDFCanvasView, context: Context) {}
}

private struct PairingView: View {
  let link: String
  let room: String
  @ObservedObject var usbRelay: USBRelayManager
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: DT.spacing.s16) {
      Text(L10n.connectTablet)
        .font(.system(size: DT.font.section).weight(.bold))
      Text(L10n.chooseConnection)
        .foregroundStyle(DT.secondary)

      Picker(L10n.connectionMethod, selection: $usbRelay.preference) {
        ForEach(ConnectionPreference.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if usbRelay.preference == .usb {
        VStack(spacing: DT.spacing.s12) {
          Image(systemName: usbRelay.isReady ? "cable.connector" : "cable.connector.slash")
            .font(.system(size: DT.font.title, weight: .light))
            .foregroundStyle(usbRelay.isReady ? DT.success : DT.secondary)
          Text(usbRelay.isReady ? L10n.stateUSBConnected : L10n.stateDisconnected)
            .font(.system(size: DT.font.label))
          Text(L10n.usbHint)
            .font(.system(size: DT.font.caption))
            .foregroundStyle(DT.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(height: DT.dimensions.d220)
      } else {
        Image(nsImage: qrImage(for: link + "#keyboardKey=" + KeyboardHost.shared.pairingKey))
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: DT.dimensions.d220, height: DT.dimensions.d220)
        Text(L10n.scanHint)
          .font(.system(size: DT.font.caption))
          .foregroundStyle(DT.secondary)
      }

      Text(L10n.format("pairingCodeValue", room)).font(.system(size: DT.font.body, design: .monospaced).weight(.semibold))
      if !usbRelay.discoveredDevices.isEmpty {
        VStack(alignment: .leading, spacing: DT.spacing.s8) {
          Text(L10n.discoveredDevices).font(.system(size: DT.font.caption).weight(.semibold)).foregroundStyle(DT.secondary)
          ForEach(usbRelay.discoveredDevices) { device in
            Label(device.displayName, systemImage: device.transport == .usb ? "cable.connector" : "wifi")
              .font(.system(size: DT.font.caption))
              .foregroundStyle(device.isConnected ? .primary : .secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DT.spacing.s8)
        .background(DT.text.opacity(DT.motion.subtle), in: RoundedRectangle(cornerRadius: DT.radius.small))
      }
      Text(L10n.pairingSubtitle).font(.system(size: DT.font.caption)).foregroundStyle(DT.secondary)
      if usbRelay.preference != .usb {
        Text(link).font(.system(size: DT.font.caption)).textSelection(.enabled).multilineTextAlignment(.center)
      }
      Button(L10n.done) { dismiss() }
    }
    .padding(DT.spacing.s28)
    .frame(width: DT.dimensions.d420)
  }

  private func qrImage(for text: String) -> NSImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let representation = NSCIImageRep(ciImage: image)
    let result = NSImage(size: representation.size)
    result.addRepresentation(representation)
    return result
  }
}
