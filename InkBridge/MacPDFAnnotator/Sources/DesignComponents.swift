import AppKit
import SwiftUI

extension ConnectionState {
  var isConnected: Bool { self == .usbConnected || self == .waitingForMode || self == .working }
}

struct ConnectionPill: View {
  let state: ConnectionState
  var home = false
  private var title: String { home && state.isConnected ? L10n.stateConnected : state.title }
  private var color: Color { home && state.isConnected ? DT.connectionBlue : state.color }

  var body: some View {
    HStack(spacing: DT.spacing.s8) {
      Circle().fill(color).frame(width: DT.layout.statusDot, height: DT.layout.statusDot)
        .overlay {
          Circle().fill(color).padding(-DT.spacing.s4)
            .modifier(ConnectionFlash(trigger: state, enabled: state != .disconnected))
        }
      Text(title).font(.system(size: DT.font.caption, weight: .medium)).foregroundStyle(DT.text)
    }
    .padding(.horizontal, DT.spacing.s16).padding(.vertical, DT.spacing.s8)
    .background(DT.workspaceSurface, in: Capsule())
    .overlay(Capsule().strokeBorder(DT.workspaceRim, lineWidth: DT.layout.stroke))
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.connectionStatus + ": " + title)
  }
}

struct PageHeader: View {
  let title: String
  let subtitle: String
  let state: ConnectionState
  var home = false
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: DT.spacing.s24) {
        titles
        Spacer(minLength: DT.spacing.s16)
        ConnectionPill(state: state, home: home)
      }
      VStack(alignment: .leading, spacing: DT.spacing.s16) {
        titles
        ConnectionPill(state: state, home: home)
      }
    }.frame(maxWidth: .infinity, minHeight: DT.layout.headerMinHeight, alignment: .topLeading)
  }
  private var titles: some View {
    VStack(alignment: .leading, spacing: DT.spacing.s8) {
      Text(title).font(.system(size: DT.font.title, weight: .bold)).foregroundStyle(DT.text)
      Text(subtitle).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct WorkspaceConnectionRim: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
      let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: 5) / 5
      let gradient = AngularGradient(stops: [
        .init(color: DT.connectionBlue.opacity(0.22), location: 0),
        .init(color: DT.connectionBlue.opacity(0.22), location: 0.48),
        .init(color: DT.connectionBlue, location: 0.66),
        .init(color: DT.connectionCyan, location: 0.79),
        .init(color: DT.connectionViolet, location: 0.88),
        .init(color: DT.connectionBlue.opacity(0.22), location: 1)
      ], center: .center, angle: .degrees(360 * turn))
      let rim = RoundedRectangle(cornerRadius: DT.radius.large)
      rim.strokeBorder(gradient, lineWidth: DT.layout.connectionRimStroke)
        .background { rim.strokeBorder(gradient.opacity(0.70), lineWidth: DT.layout.connectionRimGlow).blur(radius: DT.layout.connectionRimGlow) }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct WorkspaceToolbarBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      content.toolbarBackground(.hidden, for: .windowToolbar)
    }
  }
}

struct WorkspaceWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> ChromeView { ChromeView() }
  func updateNSView(_ view: ChromeView, context: Context) { view.configureWindow() }

  final class ChromeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      configureWindow()
    }

    func configureWindow() {
      guard let window else { return }
      if !window.styleMask.contains(.fullSizeContentView) {
        window.styleMask.insert(.fullSizeContentView)
      }
      window.isMovableByWindowBackground = false
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.titlebarSeparatorStyle = .none
    }
  }
}

struct WorkspaceScrollEdges: ViewModifier {
  private struct Overflow: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
  }

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var overflow = Overflow()
  private let depth: CGFloat = 24

  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content
        .onScrollGeometryChange(for: Overflow.self) { geometry in
          Overflow(
            top: min(max(geometry.visibleRect.minY, 0) / depth, 1),
            bottom: min(max(geometry.contentSize.height - geometry.visibleRect.maxY, 0) / depth, 1)
          )
        } action: { _, value in overflow = value }
        .overlay(alignment: .top) { edge(atTop: true).opacity(overflow.top) }
        .overlay(alignment: .bottom) { edge(atTop: false).opacity(overflow.bottom) }
    } else {
      content
    }
  }

  private func edge(atTop: Bool) -> some View {
    Rectangle()
      .fill(reduceTransparency ? AnyShapeStyle(DT.workspaceCanvas) : AnyShapeStyle(.regularMaterial))
      .mask(LinearGradient(colors: [.black, .clear],
        startPoint: atTop ? .top : .bottom, endPoint: atTop ? .bottom : .top))
      .frame(height: depth)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

struct EmptyState: View {
  let symbol: String
  let title: String
  let message: String
  let actionTitle: String
  let action: () -> Void
  var disabled = false
  var body: some View {
    VStack(spacing: DT.spacing.s16) {
      Image(systemName: symbol).font(.system(size: DT.font.section, weight: .medium))
        .foregroundStyle(DT.accent).frame(width: DT.layout.iconTile, height: DT.layout.iconTile)
        .background(DT.accentSoft, in: RoundedRectangle(cornerRadius: DT.radius.small))
      Text(title).font(.system(size: DT.font.section, weight: .semibold)).foregroundStyle(DT.text)
      Text(message).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary).multilineTextAlignment(.center)
      Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large).disabled(disabled)
    }.padding(DT.spacing.s32).frame(maxWidth: .infinity)
  }
}

struct SettingRow<Control: View>: View {
  let title: String
  let detail: String
  @ViewBuilder let control: () -> Control
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DT.spacing.s24) { labels; Spacer(minLength: DT.spacing.s16); control() }
      VStack(alignment: .leading, spacing: DT.spacing.s12) { labels; control() }
    }.frame(minHeight: DT.layout.settingRowMac)
  }
  private var labels: some View {
    VStack(alignment: .leading, spacing: DT.spacing.s8) {
      Text(title).font(.system(size: DT.font.body, weight: .medium)).foregroundStyle(DT.text)
      Text(detail).font(.system(size: DT.font.caption)).foregroundStyle(DT.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SurfacePanel<Content: View>: View {
  var highlighted = false
  @ViewBuilder var content: () -> Content
  var body: some View {
    content().padding(DT.spacing.s24).frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: DT.radius.large)
          .fill(LinearGradient(colors: [DT.workspaceTint, DT.workspaceSurface],
            startPoint: .topLeading, endPoint: .bottomTrailing))
      }
      .overlay {
        let shape = RoundedRectangle(cornerRadius: DT.radius.large)
        shape.strokeBorder(DT.workspaceRim, lineWidth: DT.layout.stroke)
          .overlay {
            shape.strokeBorder(DT.success, lineWidth: DT.layout.stroke)
              .modifier(ConnectionFlash(trigger: highlighted, enabled: highlighted))
          }
          .allowsHitTesting(false)
      }
  }
}

struct WorkspacePrimaryButton: View {
  let title: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: DT.font.body, weight: .semibold))
        .foregroundStyle(DT.workspaceOnAccent)
        .padding(.horizontal, DT.spacing.s24)
        .frame(minHeight: DT.layout.iconTile)
        .background(DT.workspaceAccent, in: Capsule())
    }.buttonStyle(.plain)
  }
}

struct WorkspaceDeviceIllustration: View {
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      RoundedRectangle(cornerRadius: DT.radius.small)
        .fill(DT.workspaceRim)
        .overlay(alignment: .topLeading) {
          VStack(alignment: .leading, spacing: DT.spacing.s8) {
            HStack(spacing: DT.spacing.s8) {
              ForEach(0..<3) { _ in Circle().fill(DT.workspaceDeviceInk).frame(width: DT.spacing.s8, height: DT.spacing.s8) }
            }
            ForEach([DT.spacing.s96, DT.spacing.s80, DT.spacing.s64], id: \.self) { width in
              Capsule().fill(DT.workspaceDeviceInk).frame(width: width, height: DT.spacing.s8)
            }
          }.padding(DT.spacing.s16)
        }
        .padding(.trailing, DT.spacing.s48).padding(.bottom, DT.spacing.s16)
      RoundedRectangle(cornerRadius: DT.radius.small)
        .fill(LinearGradient(colors: [.white, DT.workspaceDevice], startPoint: .top, endPoint: .bottom))
        .frame(width: DT.layout.heroDeviceWidth, height: DT.layout.heroDeviceHeight)
        .overlay(alignment: .topLeading) {
          Capsule().fill(DT.workspaceDeviceInk).frame(width: DT.spacing.s48, height: DT.spacing.s8)
            .padding(DT.spacing.s16)
        }
    }.frame(width: DT.layout.heroIllustrationWidth, height: DT.layout.heroIllustrationHeight)
      .accessibilityHidden(true)
  }
}

private struct ConnectionFlash<Trigger: Equatable>: ViewModifier {
  let trigger: Trigger
  let enabled: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var previous: Trigger?
  @State private var opacity = 0.0

  func body(content: Content) -> some View {
    content.opacity(opacity).allowsHitTesting(false)
      .task(id: trigger) {
        let changed = previous != nil && previous != trigger
        previous = trigger
        opacity = 0
        guard changed, enabled, !reduceMotion else { return }
        do { try await Task.sleep(for: .seconds(DT.motion.workspaceExit)) } catch { return }
        withAnimation(.easeIn(duration: DT.motion.workspacePulseIn)) { opacity = DT.motion.workspacePulse }
        do { try await Task.sleep(for: .seconds(DT.motion.workspacePulseIn)) } catch { return }
        withAnimation(.easeOut(duration: DT.motion.workspacePulseOut)) { opacity = 0 }
      }
  }
}

struct ControlMaterial: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) { content.glassEffect(.regular, in: Capsule()) }
    else { content.background(.regularMaterial, in: Capsule()) }
  }
}
