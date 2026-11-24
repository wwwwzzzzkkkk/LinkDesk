import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The section numbers refer to the supplied sidebar design.
enum SidebarDesign {
  static let width: CGFloat = 300                // §4 · floating card width in the drawing
  static let radius: CGFloat = 22, inset: CGFloat = 20 // §4 · card radius and padding
  static let border: CGFloat = 1                 // §4 · hairline outlines
  static let navHeight: CGFloat = 42, navRadius: CGFloat = 13 // §4 · navigation geometry
  static let navIcon: CGFloat = 20, navText: CGFloat = 14     // §4 · navigation type
  static let navGap: CGFloat = 2                 // §4 · row spacing in the drawing
  static let logoSize: CGFloat = 36, logoTitle: CGFloat = 17 // §4 · brand geometry and type
  static let cardRadius: CGFloat = 18, cardInset: CGFloat = 16, cardGap: CGFloat = 14 // §4 · device card
  static let name: CGFloat = 14, small: CGFloat = 12   // §4 · device type
  static let buttonHeight: CGFloat = 40, iconButton: CGFloat = 28 // §2 · button proportions
  static let compactInset: CGFloat = 7
  static let groupGap: CGFloat = 14
  static let dividerInset: CGFloat = 6, dividerOpacity = 0.08 // §4 · rule inset and opacity
  static let backdropTint = 0.095, saturation = 1.18  // §4 · glass tint and saturation
  static let selectedTint = 0.12, deviceTint = 0.075 // §4 · selection and device panel
  static let secondaryFill = 0.08, secondaryOutline = 0.12 // §4 · secondary button
  static let fileRow: CGFloat = 44, fileDrop: CGFloat = 96, dashWidth: CGFloat = 1.5 // §3 · drop geometry
  static let disconnectedOpacity = 0.45          // §3 · unavailable file row
  static let pulseDuration = 0.52, pulseScale = 2.15 // §5 · one-shot connection halo
  static let stateDuration = 0.25, stateTravel: CGFloat = 6, badgeDelay = 0.04 // §5 · device transition
  static let fileDelay = 0.08, fileFlash = 0.40   // §5 · drop text and success flash
  static let pressDuration = 0.12, pressScale = 0.97, hoverLight = 0.04 // §5 · button feedback
  static let copyDuration = 1.2                  // §5 · clipboard confirmation
  static let navigation = Animation.spring(response: 0.35, dampingFraction: 0.86) // §5 · selection
  static let dropSpring = Animation.spring(response: 0.30, dampingFraction: 0.9) // §5 · expanding drop area

  static let primaryTop = rgb(0x5E6A9B), primaryBottom = rgb(0x49547E) // §4 · primary gradient
  static let ready = rgb(0x78C2A0), offline = rgb(0x7C86A0)        // §4 · device indicators
  static let dropStroke = rgb(0xABB8D1)                           // §3 · dashed slate-blue border

  static func rgb(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 255) / 255,
      green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
  }
}

private struct SidebarPalette {
  let dark: Bool
  var text: Color { SidebarDesign.rgb(dark ? 0xEEF1FA : 0x242D42) } // §4 · primary text
  var secondary: Color { SidebarDesign.rgb(dark ? 0xAAB3C8 : 0x4F5E76) } // §4 · secondary text
  var buttonText: Color { SidebarDesign.rgb(dark ? 0xE1E5F2 : 0x334056) } // §4 · secondary button text
  var overlay: Color { dark ? .white : SidebarDesign.rgb(0x33435F) }
  var hairline: Color { overlay.opacity(dark ? 0.16 : 0.15) }
  var disabled: Color { secondary.opacity(0.64) }
}

struct SidebarTabletStatus {
  var transport: ConnectionTransport?
  var keyboardReady = false
  var microphoneTransport: ConnectionTransport?
  var isConnected: Bool { transport != nil }
}

@MainActor @Observable
final class SidebarFileDragState {
  nonisolated static let coordinateSpace = "linkdesk-file-drop"
  var frame: CGRect = .null
  var overWindow = false
  var loading = false
  private(set) var confirmed = false
  private(set) var generation = 0
  private var confirmation: Task<Void, Never>?

  func accept() {
    confirmation?.cancel()
    confirmed = true
    confirmation = Task {
      do { try await Task.sleep(for: .seconds(SidebarDesign.fileFlash)) } catch { return }
      confirmed = false
    }
  }

  func reset() {
    generation += 1
    confirmation?.cancel()
    overWindow = false
    loading = false
    confirmed = false
  }
}

struct SidebarWindowDrop: ViewModifier {
  let available: Bool
  let state: SidebarFileDragState

  @ViewBuilder func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onDrop(of: available ? [.fileURL] : [], delegate: SidebarDropDelegate(state: state))
      .onChange(of: available) { _, connected in if !connected { state.reset() } }
  }
}

private struct SidebarDropDelegate: DropDelegate {
  let state: SidebarFileDragState

  func validateDrop(info: DropInfo) -> Bool {
    !WorkspaceFiles.shared.busy && info.hasItemsConforming(to: [.fileURL])
  }

  func dropEntered(info: DropInfo) { state.overWindow = true }
  func dropExited(info: DropInfo) { state.overWindow = false }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    state.overWindow = true
    return DropProposal(operation: state.frame.contains(info.location) ? .copy : .forbidden)
  }

  func performDrop(info: DropInfo) -> Bool {
    defer { state.overWindow = false }
    guard state.frame.contains(info.location), !state.loading, !WorkspaceFiles.shared.busy else { return false }
    let providers = info.itemProviders(for: [.fileURL])
    guard !providers.isEmpty else { return false }
    state.loading = true
    // Ask Finder for every item before returning from the drop callback.
    let result = SidebarDropContents(count: providers.count, state: state)
    for (index, provider) in providers.enumerated() {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
        let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        Task { @MainActor in result.complete(url, at: index) }
      }
    }
    return true
  }
}

@MainActor
private final class SidebarDropContents {
  private var urls: [URL?]
  private var outstanding: Int
  private let state: SidebarFileDragState
  private let generation: Int

  init(count: Int, state: SidebarFileDragState) {
    urls = Array(repeating: nil, count: count)
    outstanding = count
    self.state = state
    generation = state.generation
  }

  func complete(_ url: URL?, at index: Int) {
    urls[index] = url
    outstanding -= 1
    guard outstanding == 0, state.generation == generation else { return }
    if WorkspaceFiles.shared.send(urls.compactMap { $0 }) { state.accept() }
    state.loading = false
  }
}

struct WorkspaceSidebar: View {
  let compact: Bool
  let selection: LinkDeskDestination
  let device: SidebarTabletStatus
  let pairingCode: String
  @ObservedObject var theme: LinkDeskTheme
  @ObservedObject var keyboard: KeyboardHost
  let fileDrag: SidebarFileDragState
  let navigate: (LinkDeskDestination) -> Void
  let connect: () -> Void
  let disconnect: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let palette = SidebarPalette(dark: scheme == .dark)
    let shape = RoundedRectangle(cornerRadius: SidebarDesign.radius)
    VStack(spacing: SidebarDesign.groupGap) {
      SidebarHeader(compact: compact, palette: palette, theme: theme, keyboard: keyboard, connect: connect)
      VStack(spacing: SidebarDesign.dividerInset) {
        SidebarNavigation(compact: compact, selection: selection, palette: palette, navigate: navigate)
        Rectangle().fill(palette.overlay.opacity(SidebarDesign.dividerOpacity))
          .frame(height: SidebarDesign.border).padding(.horizontal, SidebarDesign.dividerInset)
      }
      SidebarFileTransfer(compact: compact, connected: device.isConnected, drag: fileDrag, palette: palette)
      Spacer(minLength: 0)
      SidebarDeviceCard(compact: compact, device: device, pairingCode: pairingCode,
        palette: palette, connect: connect, disconnect: disconnect)
    }
    .padding(compact ? SidebarDesign.compactInset : SidebarDesign.inset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // §4 · Use the system's live backdrop diffusion (approximately the requested 30-point blur).
    // Animate the children only so material sampling stays stable during transitions.
    .background {
      shape.fill(.ultraThinMaterial).saturation(SidebarDesign.saturation)
        .overlay { shape.fill(SidebarDesign.rgb(palette.dark ? 0x1A2543 : 0xDCE1F3).opacity(palette.dark ? 0.65 : 0.24)) }
        .overlay { shape.fill(palette.overlay.opacity(SidebarDesign.backdropTint)) }
    }
    .overlay { shape.strokeBorder(palette.hairline, lineWidth: SidebarDesign.border).allowsHitTesting(false) }
    .overlay { SidebarHighlight(radius: SidebarDesign.radius, strength: 0.36) }
    .shadow(color: .black.opacity(0.23), radius: 18, y: 9) // §4 · soft outside shadow
  }
}

private struct SidebarHeader: View {
  let compact: Bool
  let palette: SidebarPalette
  @ObservedObject var theme: LinkDeskTheme
  @ObservedObject var keyboard: KeyboardHost
  let connect: () -> Void

  var body: some View {
    if compact {
      VStack(spacing: SidebarDesign.navGap + 4) { logo; settings }
    } else {
      HStack(spacing: 12) {
        logo
        Text(L10n.productName).font(.system(size: SidebarDesign.logoTitle, weight: .bold))
          .foregroundStyle(palette.text).lineLimit(1)
        Spacer(minLength: 0)
        settings
      }
    }
  }

  private var logo: some View {
    Image(systemName: DT.icon.display).font(.system(size: SidebarDesign.navIcon, weight: .medium))
      .foregroundStyle(.white).frame(width: SidebarDesign.logoSize, height: SidebarDesign.logoSize)
      .background(primaryGradient, in: RoundedRectangle(cornerRadius: 11))
      .accessibilityHidden(true)
  }

  private var settings: some View {
    Menu {
      Picker(L10n.appearance, selection: Binding(get: { theme.preference }, set: { theme.select($0) })) {
        ForEach(ThemePreference.allCases) { Text($0.title).tag($0) }
      }
      Divider()
      Button(L10n.pairingTitle, action: connect)
      if !keyboard.permitted { Button(L10n.keyboardPermissionAction) { keyboard.requestPermission() } }
    } label: {
      Image(systemName: "gearshape").font(.system(size: 16, weight: .medium))
        .foregroundStyle(palette.secondary).frame(width: SidebarDesign.iconButton, height: SidebarDesign.iconButton)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden)
    .tint(palette.secondary)
    .fixedSize().help(SidebarCopy.settings).accessibilityLabel(SidebarCopy.settings)
  }
}

private struct SidebarNavigation: View {
  let compact: Bool
  let selection: LinkDeskDestination
  let palette: SidebarPalette
  let navigate: (LinkDeskDestination) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var highlight

  var body: some View {
    VStack(spacing: SidebarDesign.navGap) {
      ForEach(LinkDeskDestination.allCases) { destination in
        let selected = destination == selection
        Button { navigate(destination) } label: {
          HStack(spacing: 11) {
            Image(systemName: destination.symbol).font(.system(size: SidebarDesign.navIcon, weight: .medium))
              .frame(width: 25)
            if !compact {
              Text(destination.title).font(.system(size: SidebarDesign.navText, weight: selected ? .semibold : .medium))
                .lineLimit(1)
            }
          }
          .padding(.horizontal, compact ? 0 : 14)
          .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
          .frame(height: SidebarDesign.navHeight)
          .foregroundStyle(selected ? (palette.dark ? .white : palette.text) : palette.secondary)
          .background {
            if selected {
              let selection = selectionBackground
              if reduceMotion { selection.transition(.opacity) }
              else { selection.matchedGeometryEffect(id: "selection", in: highlight) }
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(radius: SidebarDesign.navRadius, palette: palette))
        .help(destination.title).accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .animation(reduceMotion ? .easeInOut(duration: SidebarDesign.stateDuration) : SidebarDesign.navigation, value: selection)
  }

  private var selectionBackground: some View {
    RoundedRectangle(cornerRadius: SidebarDesign.navRadius)
      .fill(palette.overlay.opacity(SidebarDesign.selectedTint))
      .overlay { SidebarHighlight(radius: SidebarDesign.navRadius, strength: 0.27) }
      .shadow(color: .black.opacity(0.16), radius: 6, y: 4) // §4 · selection depth
  }
}

private struct SidebarFileTransfer: View {
  let compact: Bool
  let connected: Bool
  let drag: SidebarFileDragState
  let palette: SidebarPalette
  @State private var showContents = false
  @ObservedObject private var files = WorkspaceFiles.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var expanded: Bool { connected && (drag.overWindow || drag.loading || drag.confirmed) }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: SidebarDesign.navRadius)
    ZStack {
      line.opacity(expanded ? 0 : 1).allowsHitTesting(!expanded).accessibilityHidden(expanded)
      if expanded {
        shape.fill(palette.overlay.opacity(0.08))
          .overlay {
            shape.strokeBorder(drag.confirmed ? SidebarDesign.ready : SidebarDesign.dropStroke.opacity(0.54),
              style: StrokeStyle(lineWidth: SidebarDesign.dashWidth, dash: [4, 3])) // §3 · soft dashed border
          }
          .overlay {
            VStack(spacing: 5) {
              Image(systemName: drag.confirmed ? "checkmark" : "arrow.up.arrow.down")
                .font(.system(size: 17, weight: .semibold))
              if !compact {
                Text(drag.confirmed ? SidebarCopy.dropAccepted : SidebarCopy.dropTitle)
                  .font(.system(size: SidebarDesign.navText, weight: .semibold))
                Text(SidebarCopy.dropHint).font(.system(size: SidebarDesign.small)).foregroundStyle(palette.secondary)
              }
            }
            .foregroundStyle(palette.text).opacity(showContents ? 1 : 0)
            .accessibilityLabel(SidebarCopy.dropTitle)
          }
          .transition(.opacity).allowsHitTesting(false)
      }
    }
    .animation(reduceMotion ? .easeInOut(duration: SidebarDesign.pressDuration) : nil, value: expanded)
    .frame(height: expanded ? SidebarDesign.fileDrop : SidebarDesign.fileRow)
    .opacity(connected ? 1 : SidebarDesign.disconnectedOpacity)
    .help(files.status.isEmpty ? SidebarCopy.transfer : files.status)
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(SidebarFileDragState.coordinateSpace))
    } action: { drag.frame = $0 }
    .animation(reduceMotion ? nil : SidebarDesign.dropSpring, value: expanded)
    .animation(.easeInOut(duration: SidebarDesign.pressDuration), value: drag.confirmed)
    .task(id: expanded) {
      showContents = false
      guard expanded else { return }
      do { try await Task.sleep(for: .seconds(SidebarDesign.fileDelay)) } catch { return }
      withAnimation(.easeInOut(duration: SidebarDesign.pressDuration)) { showContents = true }
    }
  }

  private var line: some View {
    HStack(spacing: compact ? 0 : 5) {
      Button { files.chooseFiles() } label: {
        HStack(spacing: 11) {
          if files.busy { ProgressView().controlSize(.mini) }
          else { Image(systemName: "arrow.up.arrow.down").font(.system(size: 17, weight: .medium)) }
          if !compact { Text(SidebarCopy.transfer).font(.system(size: SidebarDesign.navText, weight: .medium)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
        .contentShape(Rectangle())
      }
      .disabled(!connected || files.busy)
      .buttonStyle(SidebarButtonStyle(radius: 10, palette: palette))
      .accessibilityLabel(SidebarCopy.transfer)

      Button {
        if files.pendingCount > 0 { files.savePendingFiles() }
        else { files.openReceiveFolder() }
      } label: {
        Image(systemName: files.pendingCount > 0 ? "tray.and.arrow.down.fill" : "folder")
          .font(.system(size: compact ? 13 : 17))
          .frame(width: compact ? 23 : SidebarDesign.iconButton, height: SidebarDesign.iconButton)
          .contentShape(Rectangle())
      }
      .buttonStyle(SidebarButtonStyle(radius: 8, palette: palette))
      .help(files.pendingCount > 0 ? SidebarCopy.pendingFiles : SidebarCopy.folder)
      .accessibilityLabel(files.pendingCount > 0 ? SidebarCopy.pendingFiles : SidebarCopy.folder)
      .contextMenu {
        if files.pendingCount > 0 { Button(SidebarCopy.pendingFiles, action: files.savePendingFiles) }
        Button(SidebarCopy.folder, action: files.openReceiveFolder)
      }
    }
    .padding(.horizontal, compact ? 1 : 12)
    .foregroundStyle(palette.secondary)
  }
}

private struct SidebarDeviceCard: View {
  let compact: Bool
  let device: SidebarTabletStatus
  let pairingCode: String
  let palette: SidebarPalette
  let connect: () -> Void
  let disconnect: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var confirmCopy = false
  @State private var copyRevision = 0
  @State private var showKeyboard = false
  @State private var showMicrophone = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: SidebarDesign.cardRadius)
    VStack(alignment: .leading, spacing: SidebarDesign.cardGap) {
      HStack(spacing: compact ? 5 : 10) {
        SidebarConnectionDot(connected: device.isConnected)
        if let transport = device.transport {
          VStack(alignment: .leading, spacing: 4) {
            if !compact {
              Text("MatePad").font(.system(size: SidebarDesign.name, weight: .semibold)).foregroundStyle(palette.text)
              Text(SidebarCopy.connected + " · " + transport.title)
                .font(.system(size: SidebarDesign.small)).foregroundStyle(palette.secondary)
            }
          }.transition(contentTransition)
          if !compact { Spacer(minLength: 0) }
          disconnectButton
        } else if !compact {
          VStack(alignment: .leading, spacing: 5) {
            Text(L10n.stateDisconnected).font(.system(size: SidebarDesign.name, weight: .semibold)).foregroundStyle(palette.text)
            HStack(spacing: 6) {
              Text(L10n.pairingCode).foregroundStyle(palette.secondary)
              Text(pairingCode).tracking(SidebarDesign.small * 0.10).fontWeight(.semibold)
              copyButton
            }.font(.system(size: SidebarDesign.small))
          }.transition(contentTransition)
        } else {
          copyButton.transition(contentTransition)
        }
      }.frame(maxWidth: .infinity, alignment: compact ? .center : .leading)

      if device.isConnected {
        HStack(spacing: compact ? 4 : 8) {
          badge("keyboard", label: SidebarCopy.keyboard, ready: device.keyboardReady).opacity(showKeyboard ? 1 : 0)
          badge("mic", label: SidebarCopy.microphone + (device.microphoneTransport.map { " · \($0.title)" } ?? ""),
            ready: device.microphoneTransport != nil).opacity(showMicrophone ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .transition(contentTransition)
      } else {
        Button(action: connect) {
          Group {
            if compact { Image(systemName: "link") }
            else { Text(L10n.connectTablet).font(.system(size: SidebarDesign.navText, weight: .semibold)) }
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity).frame(height: compact ? 32 : SidebarDesign.buttonHeight)
          .background(primaryGradient, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(SidebarButtonStyle(radius: 11, palette: palette)).help(L10n.connectTablet)
        .accessibilityLabel(L10n.connectTablet).transition(contentTransition)
      }
    }
    .padding(compact ? 5 : SidebarDesign.cardInset)
    .background(shape.fill(palette.overlay.opacity(SidebarDesign.deviceTint)))
    .overlay { shape.strokeBorder(palette.hairline, lineWidth: SidebarDesign.border).allowsHitTesting(false) }
    .animation(.easeInOut(duration: SidebarDesign.stateDuration), value: device.isConnected)
    .task(id: device.isConnected) {
      showKeyboard = false
      showMicrophone = false
      guard device.isConnected else { return }
      withAnimation(.easeInOut(duration: 0.18)) { showKeyboard = true } // §5 · staggered badge opacity
      do { try await Task.sleep(for: .seconds(SidebarDesign.badgeDelay)) } catch { return }
      withAnimation(.easeInOut(duration: 0.18)) { showMicrophone = true }
    }
    .task(id: copyRevision) {
      guard copyRevision > 0 else { return }
      do { try await Task.sleep(for: .seconds(SidebarDesign.copyDuration)) } catch { return }
      confirmCopy = false
    }
  }

  private var contentTransition: AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .offset(y: SidebarDesign.stateTravel))
  }

  private var copyButton: some View {
    Button {
      NSPasteboard.general.clearContents()
      confirmCopy = NSPasteboard.general.setString(pairingCode, forType: .string)
      if confirmCopy { copyRevision += 1 }
    } label: {
      Image(systemName: confirmCopy ? "checkmark" : "document.on.document")
        .font(.system(size: SidebarDesign.small, weight: .medium))
        .foregroundStyle(confirmCopy ? SidebarDesign.ready : palette.secondary)
        .frame(width: 23, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(SidebarButtonStyle(radius: 6, palette: palette))
    .accessibilityLabel(SidebarCopy.copy)
    .accessibilityValue(confirmCopy ? SidebarCopy.copied : "")
    .help(confirmCopy ? SidebarCopy.copied : SidebarCopy.copy)
  }

  private var disconnectButton: some View {
    Button(action: disconnect) {
      Group {
        if compact { Image(systemName: "xmark") }
        else { Text(SidebarCopy.disconnect) }
      }
      .font(.system(size: SidebarDesign.small, weight: .medium))
      .foregroundStyle(palette.buttonText)
      .padding(.horizontal, compact ? 4 : 13).frame(height: compact ? 26 : 32)
      .background(palette.overlay.opacity(SidebarDesign.secondaryFill), in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9).strokeBorder(palette.overlay.opacity(SidebarDesign.secondaryOutline))
          .allowsHitTesting(false)
      }
    }
    .buttonStyle(SidebarButtonStyle(radius: 9, palette: palette)).help(SidebarCopy.disconnect)
    .accessibilityLabel(SidebarCopy.disconnect)
  }

  private func badge(_ icon: String, label: String, ready: Bool) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).foregroundStyle(ready ? SidebarDesign.ready : palette.disabled)
      if !compact { Text(label).foregroundStyle(ready ? palette.secondary : palette.disabled).lineLimit(1) }
    }
    .font(.system(size: SidebarDesign.small))
    .padding(.horizontal, compact ? 3 : 9).frame(height: compact ? 22 : 28)
    .background(palette.overlay.opacity(SidebarDesign.secondaryFill), in: Capsule())
    .accessibilityLabel(label).accessibilityValue(ready ? SidebarCopy.ready : SidebarCopy.unavailable)
  }
}

private struct SidebarConnectionDot: View {
  let connected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var expanding = false
  @State private var pulse = false

  var body: some View {
    Circle().fill(connected ? SidebarDesign.ready : SidebarDesign.offline)
      .frame(width: 8, height: 8)
      .background {
        Circle().fill(SidebarDesign.ready.opacity(connected ? 0.22 : 0)).frame(width: 16, height: 16)
      }
      .overlay {
        Circle().strokeBorder(SidebarDesign.ready.opacity(0.55))
          .scaleEffect(expanding && !reduceMotion ? SidebarDesign.pulseScale : 1)
          .opacity(pulse ? 1 : 0)
      }
      .padding(3).accessibilityHidden(true)
      .animation(.easeInOut(duration: SidebarDesign.stateDuration), value: connected)
      .onChange(of: connected) { _, newValue in
        expanding = false
        pulse = newValue
      }
      .task(id: pulse) {
        guard pulse else { return }
        await Task.yield()
        withAnimation(.easeOut(duration: SidebarDesign.pulseDuration)) {
          expanding = true
          pulse = false
        }
      }
  }
}

private struct SidebarButtonStyle: ButtonStyle {
  let radius: CGFloat
  let palette: SidebarPalette
  func makeBody(configuration: Configuration) -> some View {
    SidebarButtonFeedback(configuration: configuration, radius: radius, palette: palette)
  }
}

private struct SidebarButtonFeedback: View {
  let configuration: ButtonStyle.Configuration
  let radius: CGFloat
  let palette: SidebarPalette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false

  var body: some View {
    configuration.label
      .overlay {
        RoundedRectangle(cornerRadius: radius)
          .fill(palette.overlay.opacity(hovering && enabled ? SidebarDesign.hoverLight : 0))
          .allowsHitTesting(false)
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? SidebarDesign.pressScale : 1)
      .opacity(configuration.isPressed && reduceMotion ? 0.88 : 1)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: SidebarDesign.pressDuration), value: configuration.isPressed)
      .animation(.easeOut(duration: SidebarDesign.pressDuration), value: hovering)
  }
}

private struct SidebarHighlight: View {
  let radius: CGFloat
  let strength: Double
  var body: some View {
    RoundedRectangle(cornerRadius: radius)
      .strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(strength), location: 0),
        .init(color: .clear, location: 0.31)], startPoint: .top, endPoint: .bottom),
        lineWidth: SidebarDesign.border)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

private var primaryGradient: LinearGradient {
  LinearGradient(colors: [SidebarDesign.primaryTop, SidebarDesign.primaryBottom],
    startPoint: .topLeading, endPoint: .bottomTrailing)
}

private enum SidebarCopy {
  static func text(_ chinese: String, _ english: String) -> String { L10n.language.hasPrefix("en") ? english : chinese }
  static let settings = text("设置", "Settings")
  static let transfer = text("文件传送", "File Transfer")
  static let pendingFiles = text("保存待接收文件", "Save incoming files")
  static let folder = text("打开接收文件夹", "Open received files folder")
  static let dropTitle = text("松开即发送到 MatePad", "Drop to send to MatePad")
  static let dropHint = text("文件会保存到平板的接收文件夹", "Files go to the tablet’s received files")
  static let dropAccepted = text("已加入发送队列", "Added to transfer queue")
  static let connected = text("已连接", "Connected")
  static let disconnect = text("断开", "Disconnect")
  static let copy = text("复制配对码", "Copy pairing code")
  static let copied = text("已复制", "Copied")
  static let keyboard = text("键盘", "Keyboard")
  static let microphone = text("麦克风", "Microphone")
  static let ready = text("就绪", "Ready")
  static let unavailable = text("不可用", "Unavailable")
}
