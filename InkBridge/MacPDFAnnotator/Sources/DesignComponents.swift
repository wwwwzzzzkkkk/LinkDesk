import AppKit
import SwiftUI

struct ConnectionPill: View {
  let state: ConnectionState
  var body: some View {
    HStack(spacing: DT.spacing.s8) {
      Circle().fill(state.color).frame(width: DT.layout.statusDot, height: DT.layout.statusDot)
      Text(state.title).font(.system(size: DT.font.caption, weight: .medium)).foregroundStyle(DT.text)
    }
    .padding(.horizontal, DT.spacing.s12).padding(.vertical, DT.spacing.s8)
    .modifier(ControlMaterial())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.connectionStatus + ": " + state.title)
  }
}

struct PageHeader: View {
  let title: String
  let subtitle: String
  let state: ConnectionState
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: DT.spacing.s24) {
        titles
        Spacer(minLength: DT.spacing.s16)
        ConnectionPill(state: state)
      }
      VStack(alignment: .leading, spacing: DT.spacing.s12) {
        titles
        ConnectionPill(state: state)
      }
    }.frame(maxWidth: .infinity, minHeight: DT.layout.headerMinHeight, alignment: .leading)
  }
  private var titles: some View {
    VStack(alignment: .leading, spacing: DT.spacing.s8) {
      Text(title).font(.system(size: DT.font.title, weight: .semibold, design: .rounded)).foregroundStyle(DT.text)
      Text(subtitle).font(.system(size: DT.font.body)).foregroundStyle(DT.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
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
    VStack(alignment: .leading, spacing: DT.spacing.s4) {
      Text(title).font(.system(size: DT.font.body, weight: .medium)).foregroundStyle(DT.text)
      Text(detail).font(.system(size: DT.font.caption)).foregroundStyle(DT.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SurfacePanel<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View {
    content().padding(DT.spacing.s24).frame(maxWidth: .infinity, alignment: .leading)
      .background(DT.surface, in: RoundedRectangle(cornerRadius: DT.radius.medium))
      .overlay(RoundedRectangle(cornerRadius: DT.radius.medium).strokeBorder(DT.border, lineWidth: DT.layout.stroke))
  }
}

struct ControlMaterial: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) { content.glassEffect(.regular, in: Capsule()) }
    else { content.background(.regularMaterial, in: Capsule()) }
  }
}
