import { LinkDeskTheme } from '../LinkDeskTheme';
import { DT, Strings, ConnectionState } from '../design/GeneratedDesign';
import { PageHeader, WorkspaceRim, isConnected } from '../design/Components';
import { TabletDeviceShortcuts, TabletWorkspaceSidebar } from '../design/WorkspaceSidebar';
import { WorkspaceSpec } from '../design/WorkspaceSpec';
import { InkWorkspace } from './InkWorkspace';
import { DesktopReceiver } from './DesktopReceiver';
import { KeyboardPanel } from '../keyboard/KeyboardPanel';
import { FileTransferClient, IncomingFile } from '../roundtrip/FileTransferClient';

@Entry
@Component
struct Index {
  @StorageLink('LinkDeskKeyboardVisible') keyboardVisible: boolean = false;
  @StorageLink('LinkDeskKeyboardState') keyboardState: string = 'disconnected';
  @StorageLink('LinkDeskDark') darkMode: boolean = false;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @StorageLink('LinkDeskSidebarDisconnected') sidebarDisconnected: boolean = false;
  @StorageLink('LinkDeskDestination') @Watch('routeChanged') destination: string = 'home';
  @StorageLink('LinkDeskInkConnected') inkConnected: boolean = false;
  @StorageLink('LinkDeskRelayReachable') relayReachable: boolean = false;
  @StorageLink('LinkDeskMacUnavailable') macUnavailable: boolean = false;
  @StorageLink('LinkDeskRelayTransport') relayTransport: string = 'usb';
  @StorageLink('LinkDeskMirrorRunning') mirrorRunning: boolean = false;
  @StorageLink('LinkDeskReceiverState') receiverState: ConnectionState = ConnectionState.disconnected;
  @StorageLink('LinkDeskReceiverWorking') receiverWorking: boolean = false;
  @StorageLink('LinkDeskPairingCode') pairingCode: string = '';
  @StorageLink('LinkDeskTransport') transport: string = 'usb';
  @StorageLink('LinkDeskFilesVisible') filesVisible: boolean = false;
  @StorageLink('LinkDeskIncomingFiles') incomingFiles: IncomingFile[] = [];
  @StorageLink('LinkDeskFileStatus') fileStatus: string = '';
  @StorageLink('LinkDeskFileNoticeEnabled') fileNoticeEnabled: boolean = false;
  @StorageLink('LinkDeskFileNoticeStatus') fileNoticeStatus: string = '';
  @StorageLink('LinkDeskFileAnnotationActive') fileAnnotationActive: boolean = false;
  @StorageLink('LinkDeskWirelessMicState') wirelessMicState: string = 'off';
  @State private keyboardWidth: number = 960;
  @State private keyboardHeight: number = 640;
  @State private selected: string = 'home';
  @State private requestedMode: string = 'pdf';
  @State private activation: number = 0;
  @State private wide: boolean = false;
  @State private homeColumns: number = 4;
  @State private navigationHeight: number = 52;
  @State private navigationGap: number = 6;
  @State private resizing: boolean = false;
  @State private heroWidth: number = 0;
  @State private heroHeight: number = 0;
  @State private prefersCompact: boolean = false;
  @State private contentOpacity: number = 1;
  @State private contentOffset: number = 0;
  @State private cardsVisible: boolean = true;
  private pageTimer: number = -1;
  private resizeTimer: number = -1;
  private measuredWindow: boolean = false;

  private compact(): boolean {
    return this.prefersCompact || this.keyboardWidth < DT.layoutSidebarCollapseBreakpoint;
  }

  aboutToDisappear(): void {
    clearTimeout(this.pageTimer);
    clearTimeout(this.resizeTimer);
  }

  private updateWindowSize(width: number, height: number): void {
    if (this.measuredWindow) {
      if (!this.resizing) this.resizing = true;
      clearTimeout(this.resizeTimer);
      this.resizeTimer = setTimeout(() => { this.resizing = false; }, 150);
    }
    this.measuredWindow = true;
    this.wide = width >= DT.layoutWideBreakpoint && width >= height;
    this.keyboardWidth = width;
    this.keyboardHeight = height;
    // Give the five destinations more space on the full tablet, while leaving room for the device card.
    this.navigationHeight = height >= 800 ? 72 : height >= 720 ? 62 : height >= 610 ? 56 : 48;
    this.navigationGap = height >= 800 ? 16 : height >= 720 ? 13 : height >= 610 ? 8 : 4;
  }

  onBackPress(): boolean {
    if (this.filesVisible) { this.filesVisible = false; return true; }
    if (this.keyboardVisible) { this.keyboardVisible = false; return true; }
    if (this.selected === 'home') return false;
    this.open('home'); return true;
  }
  private routeChanged(): void {
    if (this.destination === 'home') this.selected = 'home';
    else if (this.destination === 'display') this.selected = 'display';
    else if (this.selected === 'home' || this.selected === 'display') this.selected = 'pdf';
  }
  private open(mode: string, pairing: boolean = false): void {
    clearTimeout(this.pageTimer);
    if (mode === this.selected && !pairing) {
      this.enterPage();
      return;
    }
    const ui = this.getUIContext();
    ui.animateTo({ duration: DT.durationWorkspaceExit, curve: DT.curveExit() }, () => {
      this.contentOpacity = 0;
    });
    this.pageTimer = setTimeout(() => {
      this.selected = mode;
      if (mode !== 'home' && mode !== 'display') { this.requestedMode = mode; this.activation += 1; }
      this.destination = mode === 'home' ? 'home' : mode === 'display' ? 'display' : 'ink';
      if (pairing) AppStorage.setOrCreate('LinkDeskShowPairing', true);
      this.contentOffset = this.reduceMotion ? 0 : DT.spacingS8;
      this.cardsVisible = false;
      this.pageTimer = setTimeout(() => this.enterPage(), DT.durationWorkspaceLayoutFrame);
    }, DT.durationWorkspaceExit);
  }

  private enterPage(): void {
    this.getUIContext().animateTo({ duration: DT.durationWorkspaceEnter, curve: DT.curveWorkspace() }, () => {
      this.contentOpacity = 1;
      this.contentOffset = 0;
    });
    this.cardsVisible = true;
  }

  private isConnectedCanvas(): boolean {
    return (this.selected === 'pdf' || this.selected === 'whiteboard') &&
      !this.sidebarDisconnected && !this.macUnavailable && (this.inkConnected || this.relayReachable);
  }

  private highlightIndex(): number { return Math.max(0, WorkspaceSpec.order.indexOf(this.selected)); }

  private state(): ConnectionState {
    if (this.sidebarDisconnected) return ConnectionState.disconnected;
    if (this.selected === 'display') return this.receiverState;
    if (this.macUnavailable && !this.receiverWorking) return ConnectionState.disconnected;
    if (this.receiverWorking || (this.selected === 'home' && this.mirrorRunning)) return ConnectionState.working;
    if (this.selected === 'mirror') return this.mirrorRunning ? ConnectionState.working : this.relayReachable && this.relayTransport === 'usb' ? ConnectionState.usbConnected : ConnectionState.disconnected;
    if (this.inkConnected) return ConnectionState.working;
    if (this.relayReachable) return this.relayTransport === 'usb' ? ConnectionState.usbConnected : ConnectionState.waitingForMode;
    return ConnectionState.disconnected;
  }

  private connectTablet(): void {
    this.sidebarDisconnected = false;
    this.open('pdf', true);
  }

  private disconnectTablet(): void {
    this.sidebarDisconnected = true;
    this.open('home');
  }

  private sidebarConnected(): boolean {
    return !this.sidebarDisconnected && (this.receiverWorking || (!this.macUnavailable &&
      (this.inkConnected || this.relayReachable || this.mirrorRunning ||
      this.wirelessMicState === 'on' || this.wirelessMicState === 'paused')));
  }

  @Builder themeControl() {
    Button('⚙︎', { type: ButtonType.Normal })
      .constraintSize({ minHeight: DT.layoutTouchTarget, minWidth: DT.layoutTouchTarget })
      .fontSize(DT.fontLabel).fontColor(DT.text(this.darkMode)).backgroundColor(DT.keyboardKey(this.darkMode))
      .borderRadius(DT.radiusSmall).accessibilityText(Strings.appearance)
      .bindMenu([
        { value: Strings.themeAutomatic, action: () => LinkDeskTheme.select('automatic') },
        { value: Strings.themeLight, action: () => LinkDeskTheme.select('light') },
        { value: Strings.themeDark, action: () => LinkDeskTheme.select('dark') },
        { value: Strings.pairingTitle, action: () => this.connectTablet() }
      ])
  }
  @Builder navigationItem(key: string, bottom: boolean) {
    Button({ type: ButtonType.Normal }) {
      Flex({ direction: bottom ? FlexDirection.Column : FlexDirection.Row, alignItems: ItemAlign.Center,
        justifyContent: bottom || this.compact() ? FlexAlign.Center : FlexAlign.Start }) {
        Image(WorkspaceSpec.icon(key, this.darkMode)).width(DT.layoutIcon).height(DT.layoutIcon)
          .fillColor(this.selected === key ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
        if (bottom || !this.compact()) {
          Text(WorkspaceSpec.title(key)).fontSize(bottom ? DT.fontCaption : DT.fontBody)
            .fontWeight(this.selected === key ? FontWeight.Bold : FontWeight.Regular)
            .fontColor(this.selected === key ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
            .margin(bottom ? { top: DT.spacingS8 } : { left: DT.spacingS8 }).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.width('100%').padding(bottom || this.compact() ? DT.spacingS0 : DT.spacingS16)
    }.width('100%').height(bottom ? DT.spacingS64 : DT.layoutTouchTarget)
      .backgroundColor(Color.Transparent).borderRadius(DT.radiusSmall)
      .accessibilityText(WorkspaceSpec.title(key)).accessibilitySelected(this.selected === key)
      .onClick(() => this.open(key))
  }

  @Builder sidebar() {
    TabletWorkspaceSidebar({
      compact: this.compact(),
      canCollapse: this.keyboardWidth >= DT.layoutSidebarCollapseBreakpoint,
      selection: this.selected,
      connected: this.sidebarConnected(),
      transport: (this.inkConnected ? this.transport : this.relayTransport) === 'usb' ? 'USB' : 'Wi-Fi',
      pairingCode: this.pairingCode,
      navigationHeight: this.navigationHeight,
      navigationGap: this.navigationGap,
      resizing: this.resizing,
      filesCount: this.incomingFiles.length,
      navigate: (key: string) => this.open(key),
      toggleCompact: () => { this.prefersCompact = !this.prefersCompact; },
      connect: () => this.connectTablet(),
      disconnect: () => this.disconnectTablet(),
      showFiles: () => this.showFileTransfer()
    })
  }

  @Builder bottomNavigation() {
    Stack({ alignContent: Alignment.Start }) {
      if (!this.reduceMotion) {
        Row().width((this.keyboardWidth - DT.spacingS16) / WorkspaceSpec.order.length).height(DT.spacingS64)
          .borderRadius(DT.radiusSmall).backgroundColor(DT.workspaceSelection(this.darkMode))
          .translate({ x: this.highlightIndex() * (this.keyboardWidth - DT.spacingS16) / WorkspaceSpec.order.length })
          .animation({ duration: DT.durationWorkspaceEnter, curve: DT.curveWorkspace() })
          .hitTestBehavior(HitTestMode.None)
      }
      Row() {
        ForEach(WorkspaceSpec.order, (key: string) => {
          Stack() {
            if (this.reduceMotion && key === this.selected) {
              Row().width('100%').height('100%').backgroundColor(DT.workspaceSelection(this.darkMode))
                .borderRadius(DT.radiusSmall)
                .transition(TransitionEffect.OPACITY.animation({ duration: DT.durationWorkspaceEnter }))
            }
            this.navigationItem(key, true)
          }.layoutWeight(1).height(DT.spacingS64)
        }, (key: string) => key)
      }.width('100%')
    }.width('100%').padding(DT.spacingS8).backgroundColor(DT.workspaceTint(this.darkMode))
  }

  @Builder workspaceCard(key: string, index: number) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: DT.spacingS16 }) {
        Stack() { Image(WorkspaceSpec.icon(key, this.darkMode)).width(DT.layoutIcon).height(DT.layoutIcon) }
          .width(DT.layoutIconTile).height(DT.layoutIconTile).backgroundColor(DT.workspaceControl(this.darkMode)).borderRadius(DT.radiusSmall)
        Column({ space: DT.spacingS8 }) {
          Text(WorkspaceSpec.title(key)).fontSize(DT.fontLabel).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode)).width('100%')
          Text(WorkspaceSpec.subtitle(key)).fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).width('100%')
        }.alignItems(HorizontalAlign.Start)
      }.alignItems(HorizontalAlign.Start).padding(DT.spacingS24).width('100%')
    }.width('100%').constraintSize({ minHeight: DT.layoutCardMinHeight }).backgroundColor(DT.workspaceSurface(this.darkMode))
      .border({ width: DT.layoutStroke, color: DT.workspaceRim(this.darkMode), radius: DT.radiusLarge }).borderRadius(DT.radiusLarge).clip(true)
      .accessibilityText(WorkspaceSpec.title(key)).onClick(() => this.open(key))
      .opacity(this.reduceMotion || this.cardsVisible ? 1 : 0)
      .animation({ duration: this.cardsVisible ? DT.durationWorkspaceCard : DT.durationNone,
        delay: this.cardsVisible && !this.reduceMotion ? index * DT.durationWorkspaceStagger : DT.durationNone, curve: DT.curveWorkspace() })
  }

  @Builder deviceIllustration() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: DT.spacingS8 }) {
        Row({ space: DT.spacingS8 }) {
          ForEach([0, 1, 2], (index: number) => {
            Row().width(DT.spacingS8).height(DT.spacingS8).borderRadius(DT.radiusSmall).backgroundColor(DT.workspaceDeviceInk(this.darkMode))
          }, (index: number) => index.toString())
        }.margin({ bottom: DT.spacingS8 })
        ForEach([DT.spacingS96, DT.spacingS80, DT.spacingS64], (width: number) => {
          Row().width(width).height(DT.spacingS8).borderRadius(DT.radiusSmall).backgroundColor(DT.workspaceDeviceInk(this.darkMode))
        }, (width: number) => width.toString())
      }.alignItems(HorizontalAlign.Start).padding(DT.spacingS16)
        .width(DT.layoutHeroIllustrationWidth - DT.spacingS48).height(DT.layoutHeroIllustrationHeight - DT.spacingS16)
        .borderRadius(DT.radiusSmall).backgroundColor(DT.workspaceRim(this.darkMode))
        .margin({ right: DT.spacingS48, bottom: DT.spacingS16 })
      Column() {
        Row().width(DT.spacingS48).height(DT.spacingS8).borderRadius(DT.radiusSmall).backgroundColor(DT.workspaceDeviceInk(this.darkMode))
      }.alignItems(HorizontalAlign.Start).padding(DT.spacingS16)
        .width(DT.layoutHeroDeviceWidth).height(DT.layoutHeroDeviceHeight)
        .borderRadius(DT.radiusSmall).backgroundColor(DT.workspaceDevice(this.darkMode))
    }.width(DT.layoutHeroIllustrationWidth).height(DT.layoutHeroIllustrationHeight).accessibilityLevel('no-hide-descendants')
  }

  @Builder home() {
    Scroll() {
      Column({ space: DT.spacingS24 }) {
        Stack() {
          Row({ space: DT.spacingS24 }) {
            Column({ space: DT.spacingS16 }) {
              Text(Strings.macAndTablet).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode)).width('100%')
              Text(Strings.heroTitle).fontSize(DT.fontTitle).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode)).width('100%')
              Text(Strings.heroSubtitle).fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).width('100%')
              if (isConnected(this.state())) {
                Button(Strings.pairingTitle).height(DT.layoutTouchTarget)
                  .backgroundColor(DT.workspaceControl(this.darkMode)).fontColor(DT.text(this.darkMode))
                  .onClick(() => this.connectTablet())
              } else {
                Button(Strings.connectMac).height(DT.layoutTouchTarget).padding({ left: DT.spacingS24, right: DT.spacingS24 })
                  .backgroundColor(DT.workspaceAccent(this.darkMode)).fontColor(DT.workspaceOnAccent(this.darkMode))
                  .onClick(() => this.connectTablet())
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.homeColumns > 1) { this.deviceIllustration() }
          }.width('100%').padding(DT.spacingS24)
            .onAreaChange((_old: Area, current: Area) => {
              this.heroWidth = Number(current.width);
              this.heroHeight = Number(current.height);
            })
          if (isConnected(this.state()) && this.heroWidth > 0 && this.heroHeight > 0) {
            WorkspaceRim({ rimWidth: this.heroWidth, rimHeight: this.heroHeight }).position({ x: 0, y: 0 })
              .hitTestBehavior(HitTestMode.None)
          }
        }.width('100%').backgroundColor(DT.workspaceSurface(this.darkMode))
          .linearGradient({ angle: 125, colors: [[DT.workspaceTint(this.darkMode), 0], [DT.workspaceSurface(this.darkMode), 1]] })
          .border({ width: DT.layoutStroke, color: DT.workspaceRim(this.darkMode), radius: DT.radiusLarge }).borderRadius(DT.radiusLarge)
        GridRow({ columns: this.homeColumns, gutter: DT.spacingS16 }) {
          ForEach(WorkspaceSpec.order.slice(1), (key: string, index: number) => {
            GridCol() { this.workspaceCard(key, index) }
          }, (key: string) => key)
        }.width('100%')
      }.width('100%').padding({ left: DT.spacingS16, right: DT.spacingS16, bottom: DT.spacingS24 })
        .constraintSize({ maxWidth: DT.layoutPageMax + DT.spacingS32 })
    }.width('100%').height('100%').align(Alignment.Top)
  }

  @Builder content() {
    Stack() {
      if (this.destination !== 'display') {
        // Keep the existing bridge mounted for document returns and pending hand input.
        InkWorkspace({ requestedMode: this.requestedMode, activation: this.activation, resizing: this.resizing,
          onExit: () => this.open('home'), onModeChange: (mode: string) => {
            if (this.destination === 'ink' && this.selected !== 'mirror') this.selected = mode;
          } })
          .visibility(this.destination === 'home' ? Visibility.Hidden : Visibility.Visible)
      }
      if (this.destination === 'home') { this.home() }
      if (this.destination === 'display') { DesktopReceiver({ onExit: () => this.open('home') }) }
    }.width('100%').height('100%')
      .opacity(this.receiverWorking ? 1 : this.contentOpacity)
      .translate({ y: this.receiverWorking || this.reduceMotion ? 0 : this.contentOffset })
      .onSizeChange((_old, size) => {
        const width = Number(size.width);
        this.homeColumns = width - DT.spacingS32 >= DT.layoutWorkspaceFourCards ? 4 :
          width >= DT.layoutSingleColumnBreakpoint ? 2 : 1;
      })
  }
  private showFileTransfer(): void {
    this.filesVisible = true;
    void FileTransferClient.refresh();
  }

  @Builder fileTransferPanel() {
    Stack({ alignContent: Alignment.Center }) {
      Row().width('100%').height('100%').backgroundColor(DT.scrim(this.darkMode)).opacity(0.4)
        .onClick(() => { this.filesVisible = false; })
      Column({ space: DT.spacingS16 }) {
        Row({ space: DT.spacingS8 }) {
          Text(Strings.transferFiles).fontSize(DT.fontSection).fontWeight(FontWeight.Bold)
            .fontColor(DT.text(this.darkMode)).layoutWeight(1)
          Button(Strings.close).height(DT.layoutTouchTarget).backgroundColor(DT.workspaceControl(this.darkMode))
            .fontColor(DT.text(this.darkMode)).onClick(() => { this.filesVisible = false; })
        }.width('100%')
        Button(Strings.selectAndSendToMac).height(DT.layoutTouchTarget)
          .backgroundColor(DT.workspaceAccent(this.darkMode)).fontColor(DT.workspaceOnAccent(this.darkMode))
          .onClick(() => { void FileTransferClient.selectFiles(); })
        Row({ space: DT.spacingS12 }) {
          Column({ space: DT.spacingS4 }) {
            Text(Strings.backgroundInboxNotifications).fontSize(DT.fontBody).fontColor(DT.text(this.darkMode))
            if (this.fileNoticeStatus) {
              Text(this.fileNoticeStatus).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.fileNoticeEnabled })
            .accessibilityText(Strings.backgroundInboxNotifications)
            .onChange((enabled: boolean) => { void FileTransferClient.setNotifications(enabled); })
        }.width('100%')
        if (this.fileStatus) {
          Text(this.fileStatus).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode)).width('100%')
        }
        if (this.fileAnnotationActive) {
          Button(Strings.finishAnnotationSession).height(DT.layoutTouchTarget)
            .backgroundColor(DT.workspaceControl(this.darkMode)).fontColor(DT.text(this.darkMode))
            .onClick(() => FileTransferClient.finishAnnotation())
        }
        if (!this.incomingFiles.length) {
          Text(Strings.emptyFileInbox).fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).width('100%')
        } else {
          Scroll() {
            Column({ space: DT.spacingS12 }) {
              ForEach(this.incomingFiles, (item: IncomingFile) => {
                Column({ space: DT.spacingS8 }) {
                  Text(item.name).fontSize(DT.fontBody).fontColor(DT.text(this.darkMode))
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  Row({ space: DT.spacingS8 }) {
                    if (item.annotationID) {
                      Button(Strings.annotateInHuaweiNotes).height(DT.layoutTouchTarget)
                        .backgroundColor(DT.workspaceAccent(this.darkMode)).fontColor(DT.workspaceOnAccent(this.darkMode))
                        .onClick(() => { void FileTransferClient.receive(item, true); })
                    }
                    Button(Strings.openReceivedFile).height(DT.layoutTouchTarget)
                      .backgroundColor(DT.workspaceControl(this.darkMode)).fontColor(DT.text(this.darkMode))
                      .onClick(() => { void FileTransferClient.receive(item, false, true); })
                    Button(Strings.saveReceivedCopy).height(DT.layoutTouchTarget)
                      .backgroundColor(DT.workspaceControl(this.darkMode)).fontColor(DT.text(this.darkMode))
                      .onClick(() => { void FileTransferClient.receive(item, false); })
                  }.width('100%')
                }.padding(DT.spacingS12).width('100%').alignItems(HorizontalAlign.Start)
                  .backgroundColor(DT.workspaceTint(this.darkMode)).borderRadius(DT.radiusSmall)
              }, (item: IncomingFile) => item.id)
            }.width('100%')
          }.width('100%').constraintSize({ maxHeight: 350 })
        }
      }.width('92%').constraintSize({ maxWidth: 520 }).padding(DT.spacingS24)
        .alignItems(HorizontalAlign.Start).backgroundColor(DT.workspaceSurface(this.darkMode))
        .borderRadius(DT.radiusLarge)
    }.width('100%').height('100%').zIndex(40)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
    Column().width('100%').height('100%').backgroundColor(DT.workspaceCanvas(this.darkMode))
      .linearGradient({ angle: 135, colors: [[DT.workspaceWash(this.darkMode), 0], [DT.workspaceCanvas(this.darkMode), 0.55], [DT.workspaceGlow(this.darkMode), 1]] })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .hitTestBehavior(HitTestMode.None)
    Column({ space: DT.spacingS0 }) {
      Row({ space: DT.spacingS0 }) {
        if (this.wide && !this.receiverWorking) {
          Column() { this.sidebar() }.height('100%').padding({ left: DT.spacingS16, top: DT.spacingS16, bottom: DT.spacingS16 })
        }
        Column() {
          if (!this.receiverWorking && !this.isConnectedCanvas()) {
            Column() {
              PageHeader({ title: WorkspaceSpec.title(this.selected), subtitle: WorkspaceSpec.subtitle(this.selected),
                state: this.state(), home: this.selected === 'home' })
            }.width('100%')
              .padding({ left: DT.spacingS16, right: DT.spacingS16, top: DT.spacingS16, bottom: DT.spacingS16 })
              .constraintSize({ maxWidth: DT.layoutPageMax + DT.spacingS32 })
          }
          Column() { this.content() }.layoutWeight(1).width('100%')
        }.layoutWeight(1).height('100%')
      }.width('100%').layoutWeight(1)
      if (!this.wide && !this.receiverWorking) {
        if (this.selected === 'home') {
          Row({ space: DT.spacingS8 }) {
            TabletDeviceShortcuts().layoutWeight(1)
            Button(Strings.transferFiles).height(DT.layoutTouchTarget).onClick(() => this.showFileTransfer())
            this.themeControl()
          }.width('100%').padding({ left: DT.spacingS8, right: DT.spacingS8 })
        }
        this.bottomNavigation()
      }
    }.width('100%').height('100%')
      .onSizeChange((_old, size) => this.updateWindowSize(Number(size.width), Number(size.height)))
    if (this.filesVisible) { this.fileTransferPanel() }
    if (this.keyboardVisible) {
      KeyboardPanel({ viewportWidth: this.keyboardWidth, viewportHeight: this.keyboardHeight }).zIndex(30)
        .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.opacity(0)
          .combine(TransitionEffect.translate({ y: DT.spacingS20 }))
          .animation({ duration: DT.durationMenuEnter, curve: DT.curveEnter() }))
    }
    }.width('100%').height('100%')
  }
}
