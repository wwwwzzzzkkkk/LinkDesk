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
          .padding(.top, 12)
          .transition(searchTransition)
          .zIndex(3)
      }
    }
    .overlay {
      if workspace.mode == .pdf && !workspace.hasDocument {
        VStack(spacing: 16) {
          Image(systemName: "doc.richtext").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Color.accentColor)
          Text("从一份 PDF 开始").font(.system(size: 23, weight: .semibold, design: .rounded))
          Text("在 Mac 打开文档，在平板上自然书写。\n批注、滚动与缩放都会实时同步。")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
          Button("打开 PDF…", action: workspace.openPDF).buttonStyle(.borderedProminent).controlSize(.large)
          if !workspace.recentPDFs.isEmpty {
            Menu("最近使用") {
              ForEach(workspace.recentPDFs) { recent in Button(recent.name) { workspace.openRecent(recent) } }
            }.menuStyle(.borderlessButton).frame(width: 120)
          }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(nsColor: .windowBackgroundColor))
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
          .frame(width: 112)
          MacScreenMirrorToolbarButton(
            mirror: workspace.tabletMirror,
            usbRelay: workspace.usbRelay,
            action: workspace.toggleTabletMirror
          )
          MacToolbarActionButton(
            title: workspace.hasDocument ? "搜索 PDF 文字（⌘F）" : "打开 PDF 后可搜索文字",
            accessibilityLabel: "搜索 PDF",
            systemImage: "magnifyingglass",
            disabled: workspace.mode != .pdf || !workspace.hasDocument,
            action: workspace.presentSearch
          )
          MacToolbarActionButton(
            title: "收起工具栏",
            accessibilityLabel: "收起工具栏",
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
          .padding(.bottom, 12)
          .transition(statusTransition)
      }
    }
    .sheet(isPresented: $workspace.isShowingPairing) {
      PairingView(link: workspace.pairingLink, room: workspace.room, usbRelay: workspace.usbRelay)
    }
    .animation(
      accessibilityReduceMotion
        ? nil
        : .timingCurve(0.42, 0.0, 0.58, 1.0, duration: 0.52),
      value: workspace.isToolbarCollapsed
    )
    .animation(
      accessibilityReduceMotion
        ? .easeOut(duration: 0.12)
        : .spring(duration: 0.34, bounce: 0.18),
      value: workspace.isSearchPresented
    )
    .animation(
      accessibilityReduceMotion
        ? .easeOut(duration: 0.14)
        : .spring(duration: 0.38, bounce: 0.16),
      value: workspace.exportStatus.isEmpty
    )
  }

  private var searchTransition: AnyTransition {
    if accessibilityReduceMotion {
      return .opacity
    }
    return .scale(scale: 0.68, anchor: .top)
      .combined(with: .offset(y: -14))
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
    window.backgroundColor = NSColor.windowBackgroundColor
  }
}

private struct MacModePicker: View {
  @ObservedObject var workspace: PDFWorkspace

  var body: some View {
    Picker(
      "工作区模式",
      selection: Binding(
        get: { workspace.mode },
        set: workspace.selectMode
      )
    ) {
      ForEach(AppMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.small)
    .frame(width: 144)
    .help("在 PDF 批注与实时白板之间切换")
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
        .foregroundStyle(Color.primary.opacity(0.76))
        .frame(width: 24, height: 24)
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
      title: mirror.status,
      accessibilityLabel: mirror.isReceiving ? "停止平板投屏" : "开始平板投屏",
      systemImage: mirror.isConnected ? "ipad.gen2.landscape" : "rectangle.inset.filled.and.person.filled",
      disabled: !usbRelay.isReady && !mirror.isReceiving,
      action: action
    )
  }
}

private struct MacToolbarTitle: View {
  @ObservedObject var workspace: PDFWorkspace

  var body: some View {
    VStack(spacing: 1) {
      Text(workspace.mode == .pdf ? workspace.documentName : "实时白板")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.primary.opacity(0.80))
        .lineLimit(1)
        .truncationMode(.middle)
      Text("房间 \(workspace.room)")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.primary.opacity(0.60))
        .lineLimit(1)
    }
    .frame(minWidth: 110, idealWidth: 220, maxWidth: 320)
    .help(workspace.mode == .pdf ? workspace.documentName : "实时白板")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "当前\(workspace.mode == .pdf ? "文件 \(workspace.documentName)" : "实时白板")，房间 \(workspace.room)"
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
        Label("连接平板…", systemImage: "ipad.and.arrow.forward")
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

      Label(relay.status, systemImage: relay.isConnected ? "checkmark.circle" : "exclamationmark.circle")
        .disabled(true)
      Label(usbRelay.status, systemImage: transportSystemImage)
        .disabled(true)
      Text("房间 \(workspace.room)")
        .disabled(true)

      if !relay.documentStatus.isEmpty {
        Divider()
        Label(relay.documentStatus, systemImage: "doc.badge.arrow.up")
          .disabled(true)
      }
      if relay.canCancelPDFTransfer {
        Button(role: .cancel, action: relay.cancelPDFUpload) {
          Label("取消 PDF 传送", systemImage: "xmark.circle")
        }
      }
      if relay.canRetryPDFTransfer {
        Button(action: relay.retryPDFUpload) {
          Label("重新发送 PDF", systemImage: "arrow.clockwise")
        }
      }
    } label: {
      HStack(spacing: 5) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
        Label(connectionLabel, systemImage: transportSystemImage)
          .labelStyle(.titleAndIcon)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.primary.opacity(0.78))
      }
    }
    .menuIndicator(.visible)
    .help("\(relay.status) · \(usbRelay.status)")
    .accessibilityLabel("连接状态：\(relay.status)，\(usbRelay.status)")
  }

  private var connectionLabel: String {
    if usbRelay.isSwitching { return "切换中" }
    guard relay.isConnected else { return "未连接" }
    switch usbRelay.activeTransport ?? relay.tabletTransport {
    case .usb: return "USB"
    case .wifi: return "Wi-Fi"
    case nil: return "已连接"
    }
  }

  private var transportSystemImage: String {
    switch usbRelay.activeTransport ?? relay.tabletTransport {
    case .usb: return "cable.connector"
    case .wifi: return "wifi"
    case nil: return "ipad.and.arrow.forward"
    }
  }

  private var statusColor: Color {
    if usbRelay.isSwitching { return .orange }
    return relay.isConnected ? .green : .orange
  }

}

private struct MacDocumentStatusToast: View {
  let status: String

  private var isFailure: Bool {
    status.contains("失败") || status.contains("无法") || status.contains("不足")
  }

  var body: some View {
    Label(status, systemImage: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(isFailure ? Color.red : Color.secondary)
      .lineLimit(1)
      .padding(.horizontal, 11)
      .frame(height: 30)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
      .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
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
        x: 0.20 + 0.80 * value,
        y: 0.72 + 0.28 * value,
        anchor: .center
      )
      .opacity(0.28 + 0.72 * value)
      .blur(radius: (1 - value) * 2.4)
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
          .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
          .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
      }
    }
  }

  private var expandButton: some View {
    Button {
      workspace.isToolbarCollapsed = false
    } label: {
      ZStack(alignment: .topTrailing) {
        Text("桥")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(Color.primary.opacity(0.78))
          .frame(width: 28, height: 28)
        Circle()
          .fill(workspace.relay.isConnected ? Color.green : Color.orange)
          .frame(width: 7, height: 7)
          .overlay(Circle().stroke(.background, lineWidth: 1))
          .padding(2)
      }
    }
    .help("展开工具栏")
    .accessibilityLabel("展开工具栏")
  }
}

private struct MacSearchOverlay: View {
  @ObservedObject var workspace: PDFWorkspace
  @FocusState private var isFocused: Bool

  var body: some View {
    searchContent
      .background(SearchOutsideClickMonitor(onOutsideClick: workspace.closeSearch))
      .modifier(NativeSearchGlassModifier())
      .shadow(color: Color.black.opacity(0.16), radius: 12, y: 5)
      .frame(maxWidth: .infinity, alignment: .center)
      .onAppear { isFocused = true }
      .onExitCommand(perform: workspace.closeSearch)
  }

  private var searchContent: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(
        "搜索 PDF 文字",
        text: Binding(
          get: { workspace.searchQuery },
          set: workspace.updateSearchQuery
        )
      )
      .textFieldStyle(.plain)
      .frame(width: 210)
      .focused($isFocused)
      .onSubmit(workspace.nextSearchResult)

      Text(workspace.searchTotal == 0
        ? (workspace.searchQuery.isEmpty ? "" : "无结果")
        : "\(workspace.searchCurrent)/\(workspace.searchTotal)")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(minWidth: 34)

      SearchIconButton(
        title: "上一个匹配",
        systemImage: "chevron.up",
        disabled: workspace.searchTotal == 0,
        action: workspace.previousSearchResult
      )
      SearchIconButton(
        title: "下一个匹配",
        systemImage: "chevron.down",
        disabled: workspace.searchTotal == 0,
        action: workspace.nextSearchResult
      )
      SearchIconButton(
        title: "关闭搜索",
        systemImage: "xmark",
        action: workspace.closeSearch
      )
    }
    .padding(.horizontal, 10)
    .frame(height: 38)
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: activation)
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      guard let self,
            self.isArmed,
            event.window === self.window else { return event }
      let localPoint = self.convert(event.locationInWindow, from: nil)
      if !self.bounds.insetBy(dx: -6, dy: -6).contains(localPoint) {
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
        .overlay(Capsule().stroke(Color.primary.opacity(0.13), lineWidth: 1))
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
        .font(.system(size: 12, weight: .medium))
        .frame(width: 24, height: 24)
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
    VStack(spacing: 14) {
      Text("连接平板")
        .font(.title2.weight(.bold))
      Text("选择连接方式后，Mac 会持续搜索并自动切换。")
        .foregroundStyle(.secondary)

      Picker("连接方式", selection: $usbRelay.preference) {
        ForEach(ConnectionPreference.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if usbRelay.preference == .usb {
        VStack(spacing: 12) {
          Image(systemName: usbRelay.isReady ? "cable.connector" : "cable.connector.slash")
            .font(.system(size: 64, weight: .light))
            .foregroundStyle(usbRelay.isReady ? Color.green : Color.secondary)
          Text(usbRelay.usbStatus)
            .font(.headline)
          Text("使用数据线连接并解锁平板，LinkDesk会自动建立低延时通道。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(height: 220)
      } else {
        Image(nsImage: qrImage(for: link))
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
        Text("首次连接可扫码；已安装的平板客户端会自动加入房间。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("房间 \(room)").font(.system(.body, design: .monospaced).weight(.semibold))
      if !usbRelay.discoveredDevices.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("已发现设备").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(usbRelay.discoveredDevices) { device in
            Label(device.displayName, systemImage: device.transport == .usb ? "cable.connector" : "wifi")
              .font(.caption)
              .foregroundStyle(device.isConnected ? .primary : .secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
      }
      Text(usbRelay.status).font(.caption).foregroundStyle(.secondary)
      if usbRelay.preference != .usb {
        Text(link).font(.caption2).textSelection(.enabled).multilineTextAlignment(.center)
      }
      Button("完成") { dismiss() }
    }
    .padding(28)
    .frame(width: 420)
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
