import { pasteboard } from '@kit.BasicServicesKit';
import { curves, LengthMetrics } from '@kit.ArkUI';
import { KeyboardClient } from '../keyboard/KeyboardClient';
import { KeyboardNotification } from '../keyboard/KeyboardNotification';
import { WirelessMicrophone } from '../microphone/WirelessMicrophone';
import { LinkDeskTheme } from '../LinkDeskTheme';
import { DT, Strings } from './GeneratedDesign';
import { WorkspaceSpec } from './WorkspaceSpec';

function copy(zh: string, en: string): string {
  return Strings.language.startsWith('en') ? en : zh;
}

// Section numbers refer to the sidebar design. Sizes here are in vp/fp.
class SidebarDesign {
  static readonly width: number = 300; // §4 · card width in the reference
  static readonly inset: number = 20;
  static readonly radius: number = 22;
  static readonly navRadius: number = 13;
  static readonly navIcon: number = 20;
  static readonly navText: number = 14;
  static readonly logoSize: number = 36; // §4 · 17 bold wordmark
  static readonly logoText: number = 17;
  static readonly cardRadius: number = 18; // §4 · device card radius, inset, and gap
  static readonly cardInset: number = 16;
  static readonly gap: number = 14;
  static readonly body: number = 14;
  static readonly small: number = 12;
  static readonly fileRow: number = 44; // §3 · idle file row and offline opacity
  static readonly fileOffline: number = 0.45;
  static readonly slide: number = 6; // §5 · device motion capped at 6 vp
  static readonly connectionDuration: number = 250;
  static readonly highlightDuration: number = 300;
  static readonly copyDuration: number = 1200;
  static readonly primaryTop: string = '#5E6A9B'; // §4 · primary gradient and status tones
  static readonly primaryBottom: string = '#49547E';
  static readonly ready: string = '#78C2A0';
  static readonly offline: string = '#7C86A0';
  static primary(dark: boolean): string { return dark ? '#EEF1FA' : '#242D42'; }
  static secondary(dark: boolean): string { return dark ? '#AAB3C8' : '#4F5E76'; }
  static disabled(dark: boolean): string { return dark ? '#798298' : '#6C7687'; }
  static secondaryButton(dark: boolean): string { return dark ? '#E1E5F2' : '#334056'; }
  // ArkUI encodes translucent colors as #AARRGGBB.
  static glass(dark: boolean): string { return dark ? '#18FFFFFF' : '#18F6F8FE'; } // §4 · 9.5% tint
  static cast(dark: boolean): string { return dark ? '#9E41455F' : '#3DDCE1F3'; } // §4 · neutral blue-gray glass cast
  static device(dark: boolean): string { return dark ? '#13FFFFFF' : '#1333435F'; } // §4 · 7.5% tint
  static selection(dark: boolean): string { return dark ? '#1FFFFFFF' : '#1F33435F'; } // §4 · 12% fill
  static outline(dark: boolean): string { return dark ? '#29FFFFFF' : '#2633435F'; } // §4 · 1vp rim
  static control(dark: boolean): string { return dark ? '#14FFFFFF' : '#1433435F'; } // §4 · 8% button
}

@Component
struct SidebarGlyph {
  @Prop @Watch('draw') path: string = '';
  @Prop @Watch('draw') ink: string = '#AAB3C8';
  @Prop @Watch('draw') side: number = 20;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;

  private draw(): void {
    if (!this.ready) return;
    const context = this.context;
    context.resetTransform();
    context.clearRect(0, 0, this.side, this.side);
    // SVG command coordinates are interpreted as pixels on the tablet. Normalize
    // the 20-unit drawing to the requested vp size so it matches the Mac glyph.
    const scale = this.getUIContext().vp2px(this.side) / 20;
    context.scale(scale, scale);
    context.lineWidth = 1.5;
    context.lineCap = 'round';
    context.lineJoin = 'round';
    context.strokeStyle = this.ink;
    context.stroke(new Path2D(this.path));
  }

  build() {
    Canvas(this.context).width(this.side).height(this.side)
      .onReady(() => { this.ready = true; this.draw(); })
      .onAreaChange(() => this.draw()).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
}

// Match the neutral outline style of the Mac sidebar while leaving the workspace artwork alone.
function sidebarSymbol(key: string): string {
  switch (key) {
    case 'display': return 'M2 3H14V12H2ZM7 12V15M4 15H9M12 8H18V17H12Z';
    case 'pdf': return 'M4 2H12L16 6V18H4ZM12 2V6H16M7 10H13M7 13H13';
    case 'whiteboard': return 'M3 17L4 13L14 3L17 6L7 16ZM12 5L15 8';
    case 'mirror': return 'M2 4H18V14H2ZM8 17H12M10 7V11M8 9L10 11L12 9';
    default: return 'M2 2H8V8H2ZM12 2H18V8H12ZM2 12H8V18H2ZM12 12H18V18H12Z';
  }
}

@Component
export struct TabletDeviceShortcuts {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @StorageLink('LinkDeskKeyboardState') keyboardState: string = 'disconnected';
  @StorageLink('LinkDeskKeyboardVisible') keyboardVisible: boolean = false;
  @StorageLink('LinkDeskKeyboardNotification') keyboardNotice: boolean = false;
  @StorageLink('LinkDeskWirelessMicState') micState: string = 'off';
  @StorageLink('LinkDeskWirelessMicDetail') micDetail: string = '';
  @Prop compact: boolean = false;

  private micStatus(state: string): string {
    switch (state) {
      case 'starting': return copy('连接中', 'Connecting');
      case 'on': return copy('已开启', 'On');
      case 'paused': return copy('已暂停', 'Paused');
      case 'stopping': return copy('关闭中', 'Stopping');
      default: return copy('已关闭', 'Off');
    }
  }

  private micColor(state: string, dark: boolean): string {
    if (state === 'on') return dark ? SidebarDesign.ready : '#226B50';
    if (state === 'paused') return dark ? '#E8C284' : '#815820';
    return SidebarDesign.secondary(dark);
  }

  private shortcutGlyph(isMic: boolean, state: string): string {
    if (!isMic) return 'M2 5H18V15H2ZM5 8H6M9 8H10M13 8H14M5 11H15';
    switch (state) {
      case 'paused': return 'M6 4V16M14 4V16';
      case 'off':
      case 'stopping': return 'M7 7V5A3 3 0 0 1 13 5V10M4 9V10A6 6 0 0 0 14 14M10 16V19M7 19H13M2 2L18 18';
      default: return 'M7 5A3 3 0 0 1 13 5V10A3 3 0 0 1 7 10ZM4 9V10A6 6 0 0 0 16 10V9M10 16V19M7 19H13';
    }
  }

  @Builder shortcut(label: string, isMic: boolean, ready: boolean) {
    Row({ space: 1 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          SidebarGlyph({
            path: this.shortcutGlyph(isMic, this.micState), side: 17,
            ink: isMic ? this.micColor(this.micState, this.dark) : ready ? SidebarDesign.ready : SidebarDesign.secondary(this.dark)
          })
          if (!this.compact) {
            Column({ space: 2 }) {
              Text(label).fontSize(SidebarDesign.small).fontColor(SidebarDesign.primary(this.dark))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              if (isMic) {
                Text(this.micStatus(this.micState)).fontSize(11).fontColor(this.micColor(this.micState, this.dark))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }.alignItems(HorizontalAlign.Start)
          }
        }
      }.height(42).padding({ left: this.compact ? 4 : 8, right: 3 })
        .borderRadius(12).clip(true).stateEffect(false).hoverEffect(HoverEffect.None)
        .stateStyles({ normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(this.dark ? '#26FFFFFF' : '#2533435F') } })
        .enabled(!isMic || this.micState !== 'stopping')
        .accessibilityText(isMic ? label + ' · ' + this.micStatus(this.micState) : Strings.keyboardTitle)
        .accessibilityDescription(isMic ? this.micDetail : '')
        .onClick(() => {
          if (isMic) WirelessMicrophone.shared.toggle();
          else {
            KeyboardClient.refresh();
            this.keyboardVisible = !this.keyboardVisible;
          }
        })
      Button({ type: ButtonType.Normal }) {
        SidebarGlyph({ path: 'M5 7L10 12L15 7', side: 12, ink: SidebarDesign.secondary(this.dark) })
      }.width(this.compact ? 18 : 27).height(42).borderRadius(12).clip(true)
        .stateEffect(false).hoverEffect(HoverEffect.None)
        .stateStyles({ normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(this.dark ? '#26FFFFFF' : '#2533435F') } })
        .accessibilityText(label + copy('设置', ' settings'))
        .bindMenu(isMic ? [
          { value: copy('添加麦克风通知开关', 'Add microphone notification switch'),
            action: () => { void WirelessMicrophone.shared.enableNotification(); } }
        ] : [
          { value: this.keyboardNotice ? Strings.keyboardDisableNotice : Strings.keyboardEnableNotice,
            action: () => {
              if (this.keyboardNotice) void KeyboardNotification.disable();
              else void KeyboardNotification.enable();
            } }
        ])
    }.backgroundColor(SidebarDesign.control(this.dark)).borderRadius(14).clip(true)
  }

  build() {
    Flex({ direction: this.compact ? FlexDirection.Column : FlexDirection.Row,
      alignItems: ItemAlign.Center, justifyContent: this.compact ? FlexAlign.Center : FlexAlign.Start,
      space: { main: LengthMetrics.vp(6) } }) {
      this.shortcut(copy('键盘', 'Keyboard'), false, this.keyboardState === 'ready')
      this.shortcut(copy('麦克风', 'Mic'), true, this.micState === 'on')
    }.width('100%')
  }
}

@Component
export struct TabletWorkspaceSidebar {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @Prop compact: boolean = false;
  @Prop canCollapse: boolean = true;
  @Prop selection: string = 'home';
  @Prop @Watch('connectionChanged') connected: boolean = false;
  @Prop transport: string = 'USB';
  @Prop pairingCode: string = '';
  @Prop navigationHeight: number = 52;
  @Prop navigationGap: number = 6;
  @Prop resizing: boolean = false;
  @Prop filesCount: number = 0;
  navigate: (key: string) => void = (_key: string) => {};
  toggleCompact: () => void = () => {};
  connect: () => void = () => {};
  disconnect: () => void = () => {};
  showFiles: () => void = () => {};

  @State private copied: boolean = false;
  @State private dotScale: number = 1;
  @State private pulse: number = 0;
  private copyTimer: number = -1;
  private animationTimer: number = -1;

  aboutToAppear(): void { this.connectionChanged(); }
  aboutToDisappear(): void { clearTimeout(this.copyTimer); clearTimeout(this.animationTimer); }

  private connectionChanged(): void {
    clearTimeout(this.animationTimer);
    this.pulse = 0;
    this.dotScale = 1;
    if (!this.connected) return;
    this.pulse = this.reduceMotion ? 0 : 0.64;
    this.animationTimer = setTimeout(() => {
      this.getUIContext().animateTo({ duration: 520, curve: Curve.EaseOut }, () => {
        this.pulse = 0;
        this.dotScale = this.reduceMotion ? 1 : 2.15; // §5 · run the halo once on connection
      });
    }, 16);
  }

  private copyCode(): void {
    if (!this.pairingCode) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.pairingCode);
      void pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copied = true;
        clearTimeout(this.copyTimer);
        this.copyTimer = setTimeout(() => { this.copied = false; }, SidebarDesign.copyDuration);
      }).catch(() => {});
    } catch (_) {}
  }

  private deviceTransition(): TransitionEffect {
    const opacity = TransitionEffect.OPACITY;
    return (this.reduceMotion ? opacity : opacity.combine(TransitionEffect.translate({ y: SidebarDesign.slide })))
      .animation({ duration: SidebarDesign.connectionDuration, curve: Curve.EaseInOut });
  }

  @Builder lineIcon(path: string, size: number = 20, color: string = SidebarDesign.secondary(this.dark)) {
    SidebarGlyph({ path: path, side: size, ink: color })
  }

  @Builder header() {
    Flex({ direction: this.compact ? FlexDirection.Column : FlexDirection.Row,
      alignItems: ItemAlign.Center, justifyContent: this.compact ? FlexAlign.Center : FlexAlign.SpaceBetween }) {
      Row({ space: 10 }) {
        Stack() { this.lineIcon(sidebarSymbol('display'), SidebarDesign.navIcon, '#FFFFFF') }
          .width(SidebarDesign.logoSize).height(SidebarDesign.logoSize).borderRadius(11)
          .linearGradient({ angle: 135, colors: [[SidebarDesign.primaryTop, 0], [SidebarDesign.primaryBottom, 1]] })
          .accessibilityLevel('no')
        if (!this.compact) {
          Text(Strings.productName).fontSize(SidebarDesign.logoText)
            .fontWeight(FontWeight.Bold).fontColor(SidebarDesign.primary(this.dark))
        }
      }
      Button({ type: ButtonType.Normal }) {
        this.lineIcon('M8 2H12L12.5 4.3L14 5.1L16.2 4.5L18 7.5L16.4 9V11L18 12.5L16.2 15.5L14 14.9L12.5 15.7L12 18H8L7.5 15.7L6 14.9L3.8 15.5L2 12.5L3.6 11V9L2 7.5L3.8 4.5L6 5.1L7.5 4.3ZM12.5 10A2.5 2.5 0 1 1 7.5 10A2.5 2.5 0 1 1 12.5 10Z', 17)
      }.height(30).width(30).borderRadius(8).backgroundColor(Color.Transparent)
        .accessibilityText(copy('设置', 'Settings'))
        .bindMenu([
          { value: Strings.themeAutomatic, action: () => LinkDeskTheme.select('automatic') },
          { value: Strings.themeLight, action: () => LinkDeskTheme.select('light') },
          { value: Strings.themeDark, action: () => LinkDeskTheme.select('dark') },
          { value: Strings.pairingTitle, action: this.connect },
          { value: this.compact ? Strings.expandSidebar : Strings.collapseSidebar,
            enabled: this.canCollapse, action: this.toggleCompact }
        ])
    }.width('100%')
  }

  @Builder selectionHighlight() {
    Row().width('100%').height(this.navigationHeight).borderRadius(SidebarDesign.navRadius)
      .backgroundColor(SidebarDesign.selection(this.dark))
      .border({ width: { top: 1 }, color: SidebarDesign.outline(this.dark), radius: SidebarDesign.navRadius })
      .shadow({ radius: 6, offsetY: 4, color: '#1C000000' }).hitTestBehavior(HitTestMode.None)
  }

  @Builder navigation() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.reduceMotion) {
        Column() { this.selectionHighlight() }
          .translate({ y: Math.max(0, WorkspaceSpec.order.indexOf(this.selection)) *
            (this.navigationHeight + this.navigationGap) })
          .animation({ duration: SidebarDesign.highlightDuration,
            curve: curves.springMotion(0.35, 0.86) }) // §5 · one moving highlight
          .hitTestBehavior(HitTestMode.None)
      }
      Column({ space: this.navigationGap }) {
        ForEach(WorkspaceSpec.order, (name: string) => {
          Stack() {
            if (this.reduceMotion && name === this.selection) {
              Column() { this.selectionHighlight() }
                .transition(TransitionEffect.OPACITY.animation({ duration: SidebarDesign.connectionDuration }))
                .hitTestBehavior(HitTestMode.None)
            }
            Button({ type: ButtonType.Normal }) {
              Row({ space: 10 }) {
                this.lineIcon(sidebarSymbol(name), this.navigationHeight >= 62 ? 22 : SidebarDesign.navIcon,
                  this.selection === name ? SidebarDesign.primary(this.dark) : SidebarDesign.secondary(this.dark))
                if (!this.compact) {
                  Text(WorkspaceSpec.title(name)).fontSize(this.navigationHeight >= 62 ? 16 : SidebarDesign.navText)
                    .fontWeight(this.selection === name ? 600 : FontWeight.Medium)
                    .fontColor(this.selection === name && this.dark ? Color.White : SidebarDesign.secondary(this.dark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }.width('100%').justifyContent(this.compact ? FlexAlign.Center : FlexAlign.Start)
                .padding({ left: this.compact ? 0 : 14, right: this.compact ? 0 : 14 })
            }.height(this.navigationHeight).width('100%').borderRadius(SidebarDesign.navRadius)
              .backgroundColor(Color.Transparent).accessibilityText(WorkspaceSpec.title(name))
              .accessibilitySelected(this.selection === name).onClick(() => this.navigate(name))
          }.width('100%')
        }, (name: string) => name)
      }.width('100%')
    }.width('100%')
  }

  @Builder fileTransfer() {
    Row({ space: this.compact ? 3 : 10 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          this.lineIcon('M5 16V4M2 7L5 4L8 7M14 4V16M11 13L14 16L17 13')
          if (!this.compact) {
            Text(copy('文件传送', 'File Transfer')).fontSize(SidebarDesign.navText).fontWeight(FontWeight.Medium)
              .fontColor(SidebarDesign.secondary(this.dark))
            if (this.filesCount > 0) {
              Text(this.filesCount.toString()).fontSize(SidebarDesign.small).fontColor(SidebarDesign.secondary(this.dark))
            }
          }
        }.width('100%').justifyContent(this.compact ? FlexAlign.Center : FlexAlign.Start)
      }.layoutWeight(1).height(SidebarDesign.fileRow).backgroundColor(Color.Transparent)
        .enabled(this.connected).accessibilityText(copy('文件传送', 'File Transfer')).onClick(this.showFiles)
      Button({ type: ButtonType.Normal }) {
        this.lineIcon('M2 6V4H8L10 6H18V16H2Z')
      }.height(28).width(this.compact ? 22 : 28).backgroundColor(Color.Transparent)
        .accessibilityText(copy('打开接收文件', 'Open received files')).onClick(this.showFiles)
    }.height(SidebarDesign.fileRow).width('100%').padding(this.compact ? 0 : { left: 12, right: 12 })
      .opacity(this.connected ? 1 : SidebarDesign.fileOffline)
  }

  @Builder dot() {
    Stack() {
      Row().width(16).height(16).borderRadius(8).backgroundColor(SidebarDesign.ready).opacity(this.connected ? 0.22 : 0)
      Row().width(8).height(8).borderRadius(4).backgroundColor(this.connected ? SidebarDesign.ready : SidebarDesign.offline)
        .animation({ duration: SidebarDesign.connectionDuration, curve: Curve.EaseInOut })
      Row().width(10).height(10).borderRadius(5).border({ width: 1, color: SidebarDesign.ready, radius: 5 })
        .opacity(this.pulse).scale({ x: this.dotScale, y: this.dotScale })
    }.width(16).height(16).accessibilityLevel('no')
  }

  @Builder copyButton() {
    Button({ type: ButtonType.Normal }) {
      if (this.copied) {
        this.lineIcon('M3 9L7 13L15 5', 18, SidebarDesign.ready)
      } else {
        this.lineIcon('M7 7H16V16H7ZM4 13H2V2H13V4', 18)
      }
    }.width(23).height(26).borderRadius(6).backgroundColor(Color.Transparent)
      .enabled(this.pairingCode.length > 0).onClick(() => this.copyCode())
      .accessibilityText(this.copied ? copy('已复制配对码', 'Pairing code copied') : copy('复制配对码', 'Copy pairing code'))
  }

  @Builder deviceCard() {
    Column({ space: SidebarDesign.gap }) {
      Row({ space: this.compact ? 3 : 10 }) {
        this.dot()
        if (this.connected) {
          if (!this.compact) {
            Column({ space: 4 }) {
              Text('Mac').fontSize(SidebarDesign.body).fontWeight(600).fontColor(SidebarDesign.primary(this.dark))
              Text(Strings.stateConnected + ' · ' + this.transport).fontSize(SidebarDesign.small)
                .fontColor(SidebarDesign.secondary(this.dark))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).transition(this.deviceTransition())
          }
          Button(this.compact ? '×' : copy('断开', 'Disconnect'), { type: ButtonType.Normal })
            .height(this.compact ? 26 : 32).fontSize(SidebarDesign.small).borderRadius(9)
            .fontColor(SidebarDesign.secondaryButton(this.dark)).backgroundColor(SidebarDesign.control(this.dark))
            .border({ width: 1, color: SidebarDesign.selection(this.dark), radius: 9 })
            .padding({ left: this.compact ? 4 : 13, right: this.compact ? 4 : 13 })
            .accessibilityText(copy('断开', 'Disconnect')).onClick(this.disconnect).transition(this.deviceTransition())
        } else if (this.compact) {
          this.copyButton()
        } else {
          Column({ space: 3 }) {
            Text(Strings.stateDisconnected).fontSize(SidebarDesign.body).fontWeight(600)
              .fontColor(SidebarDesign.primary(this.dark))
            Row({ space: 6 }) {
              Text(Strings.pairingCode).fontSize(SidebarDesign.small).fontColor(SidebarDesign.secondary(this.dark))
              Text(this.pairingCode || '—').fontSize(SidebarDesign.small).fontWeight(600)
                .letterSpacing(1.2).fontColor(SidebarDesign.primary(this.dark)) // §2 · 0.1em tracking
              this.copyButton()
            }
          }.alignItems(HorizontalAlign.Start).transition(this.deviceTransition())
        }
      }.width('100%').justifyContent(this.compact ? FlexAlign.Center : FlexAlign.Start)
      if (this.connected) {
        TabletDeviceShortcuts({ compact: this.compact })
          .transition(this.deviceTransition())
      } else {
        Button(this.compact ? '↗' : copy('连接 Mac', 'Connect Mac'), { type: ButtonType.Normal })
          .height(this.compact ? 32 : 40).width('100%').borderRadius(11).fontSize(SidebarDesign.navText)
          .fontColor(Color.White).fontWeight(600)
          .linearGradient({ angle: 135, colors: [[SidebarDesign.primaryTop, 0], [SidebarDesign.primaryBottom, 1]] })
          .accessibilityText(copy('连接 Mac', 'Connect Mac')).onClick(this.connect).transition(this.deviceTransition())
      }
    }.width('100%').padding(this.compact ? 5 : SidebarDesign.cardInset)
      .borderRadius(SidebarDesign.cardRadius).backgroundColor(SidebarDesign.device(this.dark))
      .border({ width: 1, color: SidebarDesign.outline(this.dark), radius: SidebarDesign.cardRadius })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column().width('100%').height('100%').backgroundColor(SidebarDesign.glass(this.dark))
        // §4 · native backdrop diffusion remains fixed while rows animate.
        .backgroundBlurStyle(this.resizing ? BlurStyle.NONE : BlurStyle.COMPONENT_REGULAR,
          { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
        .hitTestBehavior(HitTestMode.None)
      Column().width('100%').height('100%').backgroundColor(SidebarDesign.cast(this.dark))
        .hitTestBehavior(HitTestMode.None)
      Row().width('86%').height(1).backgroundColor(this.dark ? '#38FFFFFF' : '#30FFFFFF')
        .margin({ top: 1 }).hitTestBehavior(HitTestMode.None) // §4 · one-pixel inside top highlight
      Column({ space: SidebarDesign.gap }) {
        this.header()
        Column({ space: 6 }) {
          this.navigation()
          // §4 · 1vp rule, 8% white, inset 6vp on both sides.
          Row().width('100%').height(1).backgroundColor(this.dark ? '#14FFFFFF' : '#1433435F')
            .margin({ left: 6, right: 6 })
        }.width('100%')
        this.fileTransfer()
        Blank()
        this.deviceCard()
      }.width('100%').height('100%').padding(this.compact ? 7 : SidebarDesign.inset)
    }.width(this.compact ? DT.layoutSidebarCompact : SidebarDesign.width).height('100%')
      .borderRadius(SidebarDesign.radius)
      .border({ width: 1, color: SidebarDesign.outline(this.dark), radius: SidebarDesign.radius })
      .clip(true).shadow({ radius: 18, offsetY: 9, color: '#39000000' })
  }
}
