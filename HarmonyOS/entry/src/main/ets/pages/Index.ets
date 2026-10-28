import { LinkDeskTheme } from '../LinkDeskTheme';
import { DT, Strings, ConnectionState } from '../design/GeneratedDesign';
import { PageHeader, ConnectionPill } from '../design/Components';
import { WorkspaceSpec } from '../design/WorkspaceSpec';
import { InkWorkspace } from './InkWorkspace';
import { DesktopReceiver } from './DesktopReceiver';
import { KeyboardPanel } from '../keyboard/KeyboardPanel';
import { KeyboardClient } from '../keyboard/KeyboardClient';
import { KeyboardNotification } from '../keyboard/KeyboardNotification';

@Entry
@Component
struct Index {
  @StorageLink('LinkDeskKeyboardVisible') keyboardVisible: boolean = false;
  @StorageLink('LinkDeskKeyboardState') @Watch('keyboardChanged') keyboardState: string = 'disconnected';
  private keyboardChanged(): void { void KeyboardNotification.update(); }
  @StorageLink('LinkDeskDark') darkMode: boolean = false;
  @StorageLink('LinkDeskThemePreference') themePreference: string = 'automatic';
  @StorageLink('LinkDeskDestination') @Watch('routeChanged') destination: string = 'home';
  @StorageLink('LinkDeskInkConnected') inkConnected: boolean = false;
  @StorageLink('LinkDeskRelayReachable') relayReachable: boolean = false;
  @StorageLink('LinkDeskMirrorRunning') mirrorRunning: boolean = false;
  @StorageLink('LinkDeskReceiverState') receiverState: ConnectionState = ConnectionState.disconnected;
  @StorageLink('LinkDeskReceiverWorking') receiverWorking: boolean = false;
  @StorageLink('LinkDeskPairingCode') pairingCode: string = '';
  @StorageLink('LinkDeskTransport') transport: string = 'usb';
  @State private keyboardWidth: number = 960;
  @State private keyboardHeight: number = 640;
  @State private selected: string = 'home';
  @State private requestedMode: string = 'pdf';
  @State private activation: number = 0;
  @State private wide: boolean = false;
  @State private contentWidth: number = DT.layoutPageMax;

  onBackPress(): boolean {
    if (this.keyboardVisible) { this.keyboardVisible = false; return true; }
    if (this.selected === 'home') return false;
    this.open('home'); return true;
  }
  private routeChanged(): void {
    if (this.destination === 'home') this.selected = 'home';
    else if (this.destination === 'display') this.selected = 'display';
    else if (this.selected === 'home' || this.selected === 'display') this.selected = 'pdf';
  }
  private open(mode: string): void {
    this.selected = mode;
    if (mode !== 'home' && mode !== 'display') { this.requestedMode = mode; this.activation += 1; }
    this.destination = mode === 'home' ? 'home' : mode === 'display' ? 'display' : 'ink';
  }
  private state(): ConnectionState {
    if (this.selected === 'display') return this.receiverState;
    if (this.receiverWorking) return ConnectionState.working;
    if (this.selected === 'mirror') return this.mirrorRunning ? ConnectionState.working : this.relayReachable && this.transport === 'usb' ? ConnectionState.usbConnected : ConnectionState.disconnected;
    if (this.inkConnected) return this.selected === 'home' ? ConnectionState.waitingForMode : ConnectionState.working;
    if (this.relayReachable) return this.transport === 'usb' ? ConnectionState.usbConnected : ConnectionState.waitingForMode;
    return ConnectionState.disconnected;
  }

  @Builder themeControl() {
    Button(this.themePreference === 'automatic' ? Strings.themeAutomatic : this.darkMode ? Strings.themeDark : Strings.themeLight)
      .constraintSize({ minHeight: DT.layoutTouchTarget, minWidth: DT.layoutTouchTarget })
      .fontSize(DT.fontCaption).fontColor(DT.text(this.darkMode)).backgroundColor(DT.keyboardKey(this.darkMode)).borderRadius(DT.radiusSmall)
      .accessibilityText(Strings.themeAccessibility)
      .bindMenu([
        { value: Strings.themeAutomatic, action: () => LinkDeskTheme.select('automatic') },
        { value: Strings.themeLight, action: () => LinkDeskTheme.select('light') },
        { value: Strings.themeDark, action: () => LinkDeskTheme.select('dark') }
      ])
  }
  @Builder navigationItem(key: string, vertical: boolean) {
    Button({ type: ButtonType.Normal }) {
      Flex({ direction: vertical ? FlexDirection.Column : FlexDirection.Row, alignItems: ItemAlign.Center, justifyContent: FlexAlign.Center }) {
        Image(WorkspaceSpec.icon(key, this.darkMode)).width(DT.layoutIcon).height(DT.layoutIcon)
          
        Text(WorkspaceSpec.title(key)).fontSize(vertical ? DT.fontCaption : DT.fontBody)
          .fontWeight(this.selected === key ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(this.selected === key ? DT.accent(this.darkMode) : DT.text(this.darkMode))
          .margin(vertical ? { top: DT.spacingS4 } : { left: DT.spacingS12 })
          .maxLines(2).textAlign(vertical ? TextAlign.Center : TextAlign.Start)
      }.width('100%').padding(DT.spacingS8)
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(vertical ? DT.layoutBottomNavigation : DT.layoutTouchTarget)
      .width('100%').backgroundColor(this.selected === key ? DT.accentSoft(this.darkMode) : DT.clear(this.darkMode))
      .borderRadius(DT.radiusSmall).accessibilityText(WorkspaceSpec.title(key)).onClick(() => this.open(key))
  }
  @Builder sidebar() {
    Column({ space: DT.spacingS16 }) {
      Row({ space: DT.spacingS12 }) {
        Image($r('app.media.app_icon')).width(DT.layoutIconTile).height(DT.layoutIconTile)
        Text(Strings.productName).fontSize(DT.fontSection).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode))
      }.width('100%').margin({ bottom: DT.spacingS16 })
      ForEach(WorkspaceSpec.order, (key: string) => { this.navigationItem(key, false) }, (key: string) => key)
      Blank()
      ConnectionPill({ state: this.state() })
      if (this.pairingCode) {
        Text(Strings.get('pairingCodeValue', [this.pairingCode])).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
      }
      this.themeControl()
      Button(Strings.pairingTitle)
      .backgroundColor(DT.keyboardKey(this.darkMode)).fontColor(DT.text(this.darkMode)).fontSize(DT.fontBody).borderRadius(DT.radiusSmall)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).fontSize(DT.fontCaption)
        .onClick(() => { this.open('pdf'); AppStorage.setOrCreate('LinkDeskShowPairing', true); })
    }.width(DT.layoutSidebar).height('100%').padding(DT.spacingS16)
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
  }
  @Builder bottomNavigation() {
    Row({ space: DT.spacingS4 }) {
      ForEach(WorkspaceSpec.order, (key: string) => {
        Row() { this.navigationItem(key, true) }.layoutWeight(1)
      }, (key: string) => key)
    }.width('100%').padding({ left: DT.spacingS8, right: DT.spacingS8 })
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
  }
  @Builder workspaceCard(key: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: DT.spacingS16 }) {
        Stack() { Image(WorkspaceSpec.icon(key, this.darkMode)).width(DT.layoutIcon).height(DT.layoutIcon) }
          .width(DT.layoutIconTile).height(DT.layoutIconTile).backgroundColor(DT.accentSoft(this.darkMode)).borderRadius(DT.radiusSmall)
        Text(WorkspaceSpec.title(key)).fontSize(DT.fontLabel).fontWeight(FontWeight.Medium).fontColor(DT.text(this.darkMode)).width('100%')
        Text(WorkspaceSpec.subtitle(key)).fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).width('100%')
      }.alignItems(HorizontalAlign.Start).padding(DT.spacingS24).width('100%')
    }.width('100%').constraintSize({ minHeight: DT.layoutCardMinHeight }).backgroundColor(DT.keyboardGlass(this.darkMode))
      .linearGradient({ angle: 145, colors: [[DT.panelColor0(this.darkMode), 0], [DT.panelColor1(this.darkMode), 0.5], [DT.panelColor2(this.darkMode), 1]] })
      .border({ width: DT.layoutStroke, color: DT.keyboardRim(this.darkMode), radius: DT.radiusMedium }).borderRadius(DT.radiusMedium).clip(true)
      .accessibilityText(WorkspaceSpec.title(key)).onClick(() => this.open(key))
  }
  @Builder home() {
    Scroll() {
      Column({ space: DT.spacingS24 }) {
        PageHeader({ title: Strings.homeTitle, subtitle: Strings.homeSubtitle, state: this.state() })
        Column({ space: DT.spacingS16 }) {
          Text(Strings.macAndTablet).fontSize(DT.fontCaption).fontColor(DT.accent(this.darkMode)).width('100%')
          Text(Strings.heroTitle).fontSize(DT.fontTitle).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode)).width('100%')
          Text(Strings.heroSubtitle).fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).width('100%')
          if (!this.wide) {
            Row({ space: DT.spacingS8 }) {
              this.themeControl()
              Button(Strings.pairingTitle)
      .backgroundColor(DT.keyboardKey(this.darkMode)).fontColor(DT.text(this.darkMode)).fontSize(DT.fontBody).borderRadius(DT.radiusSmall)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).onClick(() => { this.open('pdf'); AppStorage.setOrCreate('LinkDeskShowPairing', true); })
            }
          }
        }.width('100%').padding(DT.spacingS24).backgroundColor(DT.keyboardGlass(this.darkMode)).borderRadius(DT.radiusMedium)
          .linearGradient({ angle: 145, colors: [[DT.panelColor0(this.darkMode), 0], [DT.panelColor1(this.darkMode), 0.5], [DT.panelColor2(this.darkMode), 1]] })
          .border({ width: DT.layoutStroke, color: DT.keyboardRim(this.darkMode), radius: DT.radiusMedium })
        GridRow({ columns: this.contentWidth < DT.layoutSingleColumnBreakpoint ? 1 : 2, gutter: DT.spacingS16 }) {
          ForEach(WorkspaceSpec.order.slice(1), (key: string) => { GridCol() { this.workspaceCard(key) } }, (key: string) => key)
        }.width('100%')
        Text(Strings.connectionHint).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode)).width('100%')
        Button(Strings.keyboardTitle).height(DT.layoutTouchTarget).fontSize(DT.fontBody)
          .backgroundColor(DT.keyboardKey(this.darkMode)).fontColor(DT.text(this.darkMode))
          .enabled(['ready', 'permission', 'secure-input'].includes(this.keyboardState)).onClick(() => { KeyboardClient.refresh(); this.keyboardVisible = true; })
        Text(this.keyboardState === 'permission' ? Strings.keyboardPermissionHint : this.keyboardState === 'pairing' ? Strings.keyboardPairingHint : this.keyboardState === 'ready' ? Strings.keyboardReady : Strings.keyboardDisconnected)
          .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode)).width('100%')
      }.width('100%').constraintSize({ maxWidth: DT.layoutPageMax }).padding(this.wide ? DT.layoutPagePadding : DT.layoutCompactPadding)
    }.width('100%').height('100%').align(Alignment.Top)
  }
  @Builder content() {
    Stack() {
      if (this.destination !== 'display') {
        // Keep the existing bridge mounted for document returns and pending hand input.
        InkWorkspace({ requestedMode: this.requestedMode, activation: this.activation,
          onExit: () => this.open('home'), onModeChange: (mode: string) => {
            if (this.destination === 'ink' && this.selected !== 'mirror') this.selected = mode;
          } })
          .visibility(this.destination === 'home' ? Visibility.Hidden : Visibility.Visible)
      }
      if (this.destination === 'home') { this.home() }
      if (this.destination === 'display') { DesktopReceiver({ onExit: () => this.open('home') }) }
    }.width('100%').height('100%').onAreaChange((_old: Area, current: Area) => { this.contentWidth = Number(current.width); })
  }
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
    Column({ space: DT.spacingS0 }) {
      Row({ space: DT.spacingS0 }) {
        if (this.wide && !this.receiverWorking) { this.sidebar() }
        Column() { this.content() }.layoutWeight(1)
      }.width('100%').layoutWeight(1)
      if (!this.wide && !this.receiverWorking) { this.bottomNavigation() }
    }.width('100%').height('100%').backgroundColor(DT.canvas(this.darkMode))
      .onAreaChange((_old: Area, current: Area) => { this.keyboardWidth = Number(current.width); this.keyboardHeight = Number(current.height); this.wide = Number(current.width) >= DT.layoutWideBreakpoint && Number(current.width) >= Number(current.height); })
    if (this.keyboardVisible) { KeyboardPanel({ viewportWidth: this.keyboardWidth, viewportHeight: this.keyboardHeight }).zIndex(30) }
    }.width('100%').height('100%')
  }
}
