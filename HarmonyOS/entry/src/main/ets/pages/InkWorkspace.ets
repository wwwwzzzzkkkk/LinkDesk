import { DT, Strings, ConnectionState, ConnectionPresentation } from '../design/GeneratedDesign';
import { PageHeader, ConnectionPill, SettingRow, EmptyState } from '../design/Components';
import { WorkspaceSpec } from '../design/WorkspaceSpec';
import { LinkDeskTheme } from '../LinkDeskTheme';
import { webview } from '@kit.ArkWeb';
import { promptAction } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { http, mdns } from '@kit.NetworkKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { window } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Want, common, wantAgent, WantAgent, wantConstant } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import screenMirror from 'libscreenmirror.so';
import { RoundTripBridge } from '../roundtrip/RoundTripBridge';
import { RoundTripLiveViewController } from '../roundtrip/RoundTripLiveViewController';

interface NativePenPoint {
  x: number;
  y: number;
  p: number;
  tiltX: number;
  tiltY: number;
  rollAngle?: number;
  timestamp: number;
  sampleIndex: number;
}

interface RelayCandidate {
  host: string;
  mode: string;
}

interface ScannedPairingLink {
  host: string;
  room: string;
}

interface PenBridgeCommand {
  kind: string;
  code?: string;
}

const INKBRIDGE_APP_VERSION: string = '1.6.10';
const INKBRIDGE_PROTOCOL_VERSION: number = 2;
const HIGHLIGHTER_HOLD_DELAY_MS: number = 2000;
const HIGHLIGHTER_HOLD_SLOP: number = 18;
const PEN_BRIDGE_MAX_SAMPLES_PER_CALL: number = 240;
const PEN_BRIDGE_MAX_PENDING_SAMPLES: number = 960;

@Component
export struct InkWorkspace {
  @StorageLink('LinkDeskDark') @Watch('applyWebTheme') darkMode: boolean = false;
  @StorageLink('LinkDeskThemePreference') themePreference: string = 'automatic';
  @Prop @Watch('requestedModeDidChange') requestedMode: string = 'pdf';
  @Prop @Watch('requestedModeDidChange') activation: number = 0;
  onExit: () => void = () => {};
  onModeChange: (mode: string) => void = () => {};
  private pendingInitialMode: boolean = false;
  private pendingMirrorStart: boolean = false;

  private requestedModeDidChange(): void {
    if (this.activation === 0) return;
    if (this.requestedMode === 'mirror') {
      this.pendingMirrorStart = false;
    } else {
      this.pendingInitialMode = true;
      this.switchAppMode(this.requestedMode, this.showPad);
    }
  }

  @State host: string = '';
  @State @Watch('publishConnection') room: string = '';
  @StorageLink('LinkDeskShowPairing') @Watch('showPairingRequested') showPairing: boolean = false;
  @State connectionMode: string = 'wifi';
  @State connectionPreference: string = 'automatic';
  @State appMode: string = 'pdf';
  @State showPad: boolean = false;
  @State @Watch('publishConnection') connected: boolean = false;
  @State documentName: string = Strings.waitPDFTitle;
  @State zoomPercent: number = 100;
  @State color: string = DT.inkInk;
  @State penWidth: number = 3.5;
  @State eraser: boolean = false;
  @State highlighter: boolean = false;
  @State highlighterWidth: number = 14;
  @State highlighterOpacity: number = 0.32;
  @State eraserSize: number = 48;
  @State pressureEraserEnabled: boolean = true;
  @State pressureSensitivity: string = 'standard';
  @State openToolMenu: string = '';
  @State canUndo: boolean = false;
  @State canRedo: boolean = false;
  @State strokeEraser: boolean = false;
  @State cursorVisible: boolean = false;
  @State cursorX: number = 0;
  @State cursorY: number = 0;
  @State padAreaWidth: number = 1;
  @State padAreaHeight: number = 1;
  @State systemTopInset: number = 0;
  @State cutoutTopInset: number = 0;
  @State systemBottomInset: number = 0;
  @State navigationBottomInset: number = 0;
  @State topBarCollapsed: boolean = false;
  @State headerWidth: number = 1000;
  @State headerLeftWidth: number = 0;
  @State headerRightWidth: number = 0;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @State @Watch('publishConnection') screenMirroring: boolean = false;
  @State roundTripId: string = '';
  @State roundTripName: string = '';
  @State roundTripStatus: string = '';

  private webController: webview.WebviewController = new webview.WebviewController();
  @State webUrl: string = '';
  private connectedHost: string = '';
  private connectedRoom: string = '';
  private hoverThrottleTimer: number | undefined = undefined;
  private pendingHoverX: number = 0;
  private pendingHoverY: number = 0;
  private hoverHideTimer: number | undefined = undefined;
  private statePollTimer: number | undefined = undefined;
  private penStrokeActive: boolean = false;
  private penSampleIndex: number = 0;
  private pendingPenStart: NativePenPoint | undefined = undefined;
  private pendingPenSamples: NativePenPoint[] = [];
  private pendingPenMaxPressure: number = 0;
  private pendingPenTimer: number | undefined = undefined;
  private highlighterHoldTimer: number | undefined = undefined;
  private highlighterStartPoint: NativePenPoint | undefined = undefined;
  private highlighterPausePoint: NativePenPoint | undefined = undefined;
  private highlighterLatestPoint: NativePenPoint | undefined = undefined;
  private highlighterStraightLocked: boolean = false;
  private penBridgeQueue: PenBridgeCommand[] = [];
  private penBridgeInFlight: boolean = false;
  private pendingNativeMoveSamples: NativePenPoint[] = [];
  private penMoveCommandQueued: boolean = false;
  private pendingStraightUpdate: NativePenPoint | undefined = undefined;
  private straightUpdateCommandQueued: boolean = false;
  private pendingTransportMode: string = '';
  private pendingTransportPreference: string = '';
  private pendingTransportRequestId: string = '';
  private activeTransportRequestId: string = '';
  private disconnectedPolls: number = 0;
  private reconnectTimer: number | undefined = undefined;
  private discoveryRestartTimer: number | undefined = undefined;
  private discoveryService: mdns.DiscoveryService | undefined = undefined;
  private serviceFoundCallback: ((serviceInfo: mdns.LocalServiceInfo) => void) | undefined = undefined;
  private serviceLostCallback: ((serviceInfo: mdns.LocalServiceInfo) => void) | undefined = undefined;
  private discoveredWirelessHost: string = '';
  private connectionAttemptInFlight: boolean = false;
  private connectionGeneration: number = 0;
  private mainWindow: window.Window | undefined = undefined;
  private avoidAreaListener: ((data: window.AvoidAreaOptions) => void) | undefined = undefined;

  aboutToAppear(): void {
    try {
      this.screenMirroring = screenMirror.isRunning() as boolean;
    } catch (_) {}
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!context) return;
      const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
      this.host = store.getSync('host', this.host) as string;
      this.room = store.getSync('room', this.room) as string;
      this.connectionMode = store.getSync('connectionMode', this.connectionMode) as string;
      this.connectionPreference = store.getSync('connectionPreference', this.connectionPreference) as string;
      this.appMode = store.getSync('appMode', this.appMode) as string;
      this.roundTripId = store.getSync('roundTripId', '') as string;
      this.roundTripName = store.getSync('roundTripName', '') as string;
      this.eraserSize = store.getSync('eraserSize', this.eraserSize) as number;
      this.highlighterWidth = store.getSync('highlighterWidth', this.highlighterWidth) as number;
      this.highlighterOpacity = store.getSync('highlighterOpacity', this.highlighterOpacity) as number;
      this.pressureEraserEnabled =
        store.getSync('pressureEraserEnabled', this.pressureEraserEnabled) as boolean;
      this.pressureSensitivity =
        store.getSync('pressureSensitivity', this.pressureSensitivity) as string;
      // One-time migration from the old Wi-Fi/IP-only default. Explicit
      // choices made after this release remain persistent.
      const migrated = store.getSync('automaticDiscoveryV1', false) as boolean;
      if (!migrated) {
        this.connectionPreference = 'automatic';
        store.putSync('connectionPreference', this.connectionPreference);
        store.putSync('automaticDiscoveryV1', true);
        store.flushSync();
      }
    } catch (_) {}
    RoundTripBridge.register((uri: string): void => {
      void this.uploadRoundTripURI(uri);
    });
    RoundTripBridge.registerLiveViewAction((action: string): void => {
      this.handleLiveViewAction(action);
    });
    if (this.activation > 0) {
      this.appMode = this.requestedMode === 'whiteboard' ? 'whiteboard' : 'pdf';
      this.pendingInitialMode = this.requestedMode !== 'mirror';
      this.pendingMirrorStart = false;
    }
    this.startRelayDiscovery();
    if (/^[A-Z0-9]{6}$/.test(this.room)) this.scheduleReconnect(120);
    void this.configureWindowInsets();
  }

  aboutToDisappear(): void {
    this.disconnect();
    if (this.screenMirroring || (screenMirror.isRunning() as boolean)) {
      this.stopScreenMirror(`workspace-exit-${Date.now()}`);
    }

    RoundTripBridge.unregister();
    RoundTripBridge.unregisterLiveViewAction();
    if (this.mainWindow && this.avoidAreaListener) {
      this.mainWindow.off('avoidAreaChange', this.avoidAreaListener);
    }
    this.avoidAreaListener = undefined;
    this.mainWindow = undefined;
    this.stopRelayDiscovery();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.discoveryRestartTimer) clearTimeout(this.discoveryRestartTimer);
    this.reconnectTimer = undefined;
    this.discoveryRestartTimer = undefined;
    this.handleHoverExit();
    this.clearPendingPenStart();
    this.clearHighlighterHold();
    if (this.penStrokeActive) {
      this.runJS('nativePenCancel()');
      this.penStrokeActive = false;
      this.strokeEraser = false;
    }
    this.resetPenBridge();
  }

  private showPairingRequested(): void {
    if (this.showPairing) { this.disconnect(); this.showPairing = false; }
  }
  private publishConnection(): void {
    AppStorage.setOrCreate('LinkDeskPairingCode', this.room);
    AppStorage.setOrCreate('LinkDeskMirrorRunning', this.screenMirroring);
    AppStorage.setOrCreate('LinkDeskInkConnected', this.connected);
    AppStorage.setOrCreate('LinkDeskTransport', this.connectionMode);
  }
  private connectionState(): ConnectionState {
    if (this.connected) return ConnectionState.working;
    return ConnectionState.disconnected;
  }

  @Builder themeControl() {
    Button(this.themePreference === 'automatic' ? Strings.themeAutomatic : this.darkMode ? Strings.themeDark : Strings.themeLight)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
      .fontSize(DT.fontCaption).height(DT.layoutTouchTarget).fontColor(DT.secondary(this.darkMode))
      .backgroundColor(DT.control(this.darkMode)).borderRadius(DT.radiusMedium)
      .accessibilityText(Strings.themeAccessibility)
      .bindMenu([
        { value: Strings.themeAutomatic, action: () => LinkDeskTheme.select('automatic') },
        { value: Strings.themeLight, action: () => LinkDeskTheme.select('light') },
        { value: Strings.themeDark, action: () => LinkDeskTheme.select('dark') }
      ])
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.showPad) {
        Stack() {
          this.PadArea()
          if (this.requestedMode === 'mirror') {
            this.MirrorPanel()
          }
          Column() {
            if (this.topBarCollapsed) {
              this.CollapsedHeaderButton()
            } else {
              this.HeaderRow()
            }
            Blank(1)
            this.ToolbarRow()
          }.visibility(this.requestedMode === 'mirror' ? Visibility.Hidden : Visibility.Visible)
          .width('100%').height('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: DT.spacingS12,
            right: DT.spacingS12,
            top: this.topSafeInset() + DT.spacingS8,
            bottom: this.bottomSafeInset() + DT.spacingS8
          })
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%').height('100%')
.backgroundColor(DT.canvas(this.darkMode))
      } else {
        this.ConnectionPanel()
      }

      if (this.showPad && this.openToolMenu === 'pen') {
        this.PenToolMenu()
      }
      if (this.showPad && this.openToolMenu === 'eraser') {
        this.EraserToolMenu()
      }
      if (this.showPad && this.openToolMenu === 'highlighter') {
        this.HighlighterToolMenu()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(DT.canvas(this.darkMode))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder MirrorPanel() {
    Scroll() {
      Column({ space: DT.spacingS24 }) {
        PageHeader({ title: Strings.mirrorTitle, subtitle: Strings.mirrorSubtitle,
          state: this.screenMirroring ? ConnectionState.working : this.connected && this.connectionMode === 'usb' ? ConnectionState.usbConnected : ConnectionState.disconnected })
        EmptyState({ icon: DT.iconMirror(this.darkMode), title: this.screenMirroring ? Strings.mirrorRunning : Strings.mirrorEmptyTitle,
          message: Strings.mirrorEmptyDescription, actionTitle: this.screenMirroring ? Strings.stopMirror : Strings.startMirror,
          action: () => this.toggleScreenMirror(), disabled: this.connectionMode !== 'usb' })
      }.width('100%').constraintSize({ maxWidth: DT.layoutPageMax }).padding(DT.layoutPagePadding)
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor(DT.canvas(this.darkMode))
  }

  // ==================== 连接面板 ====================
  @Builder ConnectionPanel() {
    Scroll() {
    Column({ space: DT.spacingS16 }) {
      PageHeader({ title: WorkspaceSpec.title(this.requestedMode), subtitle: WorkspaceSpec.subtitle(this.requestedMode), state: this.connectionState() })
      this.themeControl()
      Column({ space: DT.spacingS12 }) {
        Row({ space: DT.spacingS8 }) {
          Button(Strings.automatic)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
            .layoutWeight(1).height(DT.layoutTouchTarget).fontSize(DT.fontCaption)
            .backgroundColor(this.connectionPreference === 'automatic' ? DT.accent(this.darkMode) : DT.control(this.darkMode))
            .fontColor(this.connectionPreference === 'automatic' ? DT.onAccent(this.darkMode) : DT.secondary(this.darkMode))
            .borderRadius(DT.radiusSmall)
            .onClick(() => {
              this.connectionPreference = 'automatic';
              this.scheduleReconnect(0);
            })
          Button(Strings.transportWireless)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
            .layoutWeight(1).height(DT.layoutTouchTarget).fontSize(DT.fontCaption)
            .backgroundColor(this.connectionPreference === 'wifi' ? DT.accent(this.darkMode) : DT.control(this.darkMode))
            .fontColor(this.connectionPreference === 'wifi' ? DT.onAccent(this.darkMode) : DT.secondary(this.darkMode))
            .borderRadius(DT.radiusSmall)
            .onClick(() => {
              this.connectionMode = 'wifi';
              this.connectionPreference = 'wifi';
            })
          Button(Strings.transportUSB)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
            .layoutWeight(1).height(DT.layoutTouchTarget).fontSize(DT.fontCaption)
            .backgroundColor(this.connectionPreference === 'usb' ? DT.accent(this.darkMode) : DT.control(this.darkMode))
            .fontColor(this.connectionPreference === 'usb' ? DT.onAccent(this.darkMode) : DT.secondary(this.darkMode))
            .borderRadius(DT.radiusSmall)
            .onClick(() => {
              this.connectionMode = 'usb';
              this.connectionPreference = 'usb';
            })
        }.width('100%')

        if (this.connectionMode === 'wifi') {
          TextInput({ text: this.host, placeholder: Strings.automaticHostPlaceholder })
            .width('100%').height(DT.spacingS48).backgroundColor(DT.surface(this.darkMode)).borderRadius(DT.radiusSmall)
            .fontSize(DT.fontBody).padding({ left: DT.spacingS16, right: DT.spacingS16 })
            .border({ width: DT.layoutStroke, color: DT.border(this.darkMode) })
            .onChange((value: string) => this.host = value.trim())
        } else {
          Column({ space: DT.spacingS4 }) {
            Text(Strings.usbLowLatency).fontSize(DT.fontBody).fontWeight(FontWeight.Medium).fontColor(DT.text(this.darkMode))
            Text(Strings.usbAutoHint).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
          }
          .width('100%').height(DT.spacingS48).justifyContent(FlexAlign.Center)
          .backgroundColor(DT.surface(this.darkMode)).borderRadius(DT.radiusSmall)
          .border({ width: DT.layoutStroke, color: DT.border(this.darkMode) })
        }

        TextInput({ text: this.room, placeholder: Strings.pairingPlaceholder })
          .width('100%').height(DT.spacingS48).backgroundColor(DT.surface(this.darkMode)).borderRadius(DT.radiusSmall)
          .fontSize(DT.fontBody).padding({ left: DT.spacingS16, right: DT.spacingS16 })
          .letterSpacing(DT.spacingS4).maxLength(6)
          .border({ width: DT.layoutStroke, color: DT.border(this.darkMode) })
          .onChange((value: string) => {
            this.room = value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
          })

        Button(Strings.scanMac)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .width('100%').height(DT.layoutTouchTarget)
          .fontSize(DT.fontBody).fontWeight(FontWeight.Medium)
          .backgroundColor(DT.control(this.darkMode)).fontColor(DT.secondary(this.darkMode))
          .border({ width: DT.layoutStroke, color: DT.border(this.darkMode) })
          .borderRadius(DT.radiusSmall)
          .onClick(() => this.startNativePairingScan())

        Button(this.connectionPreference === 'automatic'
          ? Strings.autoConnectMac
          : (this.connectionMode === 'usb' ? Strings.usbConnectMac : Strings.wifiConnectMac))
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .width('100%').height(DT.spacingS48)
          .fontSize(DT.fontBody).fontWeight(FontWeight.Bold)
          .backgroundColor(DT.accent(this.darkMode)).fontColor(DT.onAccent(this.darkMode))
          .borderRadius(DT.radiusSmall)
          .onClick(() => this.connectToPad())
      }
      .width('100%').constraintSize({ maxWidth: DT.dimensionsD360 }).margin({ top: DT.spacingS12 })

      Column({ space: DT.spacingS4 }) {
        Text(this.connectionPreference === 'automatic'
          ? Strings.automaticHint
          : (this.connectionMode === 'usb' ? Strings.usbOnlyHint : Strings.wifiHint))
          .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
        Text(Strings.macPDFHint).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
      }.alignItems(HorizontalAlign.Center)

      Blank(1)
    }
    .width('100%')
    .padding({ left: DT.spacingS24, right: DT.spacingS24 })
    .backgroundColor(DT.canvas(this.darkMode))
    }.width('100%').height('100%').align(Alignment.Top)
  }

  // ==================== 顶部状态栏 ====================
  @Builder HeaderRow() {
    Column({ space: DT.spacingS8 }) {
      PageHeader({ title: WorkspaceSpec.title(this.appMode), subtitle: WorkspaceSpec.subtitle(this.appMode), state: this.connectionState() })
      Scroll() {
        Row({ space: DT.spacingS8 }) {
          Text(Strings.get('pairingCodeValue', [this.room])).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
          this.themeControl()
          if (this.roundTripId.length > 0) {
            Button(Strings.returnPDF)
      .backgroundColor(DT.control(this.darkMode)).fontColor(DT.text(this.darkMode)).fontSize(DT.fontBody).borderRadius(DT.radiusSmall)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).onClick(() => this.selectRoundTripReturnPDF())
          }
          Button(this.screenMirroring ? Strings.stopMirror : Strings.startMirror)
      .backgroundColor(DT.control(this.darkMode)).fontColor(DT.text(this.darkMode)).fontSize(DT.fontBody).borderRadius(DT.radiusSmall)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
            .height(DT.layoutTouchTarget).onClick(() => this.toggleScreenMirror())
          Button(Strings.collapseTools)
      .backgroundColor(DT.control(this.darkMode)).fontColor(DT.text(this.darkMode)).fontSize(DT.fontBody).borderRadius(DT.radiusSmall)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).onClick(() => this.setTopBarCollapsed(true))
        }.padding(DT.spacingS8)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
    }.width('100%').padding(DT.spacingS16).borderRadius(DT.radiusMedium)
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .backgroundColor(DT.glass(this.darkMode))
      .geometryTransition('inkbridge-topbar-roll')
  }

  @Builder CollapsedHeaderButton() {
    Button() {
      Stack({ alignContent: Alignment.Center }) {
        Text(Strings.productInitial).fontSize(DT.fontCaption).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode))
        Circle()
          .width(DT.spacingS8).height(DT.spacingS8)
          .fill(this.connected ? DT.success(this.darkMode) : DT.warning(this.darkMode))
          .position({ x: DT.spacingS36, y: DT.spacingS8 })
        Text(Strings.glyphExpand).fontSize(DT.fontCaption).fontColor(DT.text(this.darkMode))
          .position({ x: DT.spacingS32, y: DT.spacingS28 })
      }
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
    .width(DT.spacingS48).height(DT.spacingS48).padding(DT.spacingS0)
    .backgroundColor(DT.glass(this.darkMode))
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    
    .border({ width: DT.layoutStroke, color: DT.glass(this.darkMode) })
    .borderRadius(DT.radiusLarge)
    .clip(true)
    .shadow({ radius: DT.radiusSmall, color: DT.glass(this.darkMode), offsetX: DT.spacingS0, offsetY: DT.spacingS8 })
    .geometryTransition('inkbridge-topbar-roll')
    .accessibilityText(Strings.expandTools)
    .onClick(() => this.setTopBarCollapsed(false))
  }

  // ==================== PDF 批注区域（WebView + 悬停光标） ====================
  @Builder PadArea() {
    Stack() {
      Web({ src: this.webUrl, controller: this.webController })
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .overviewModeAccess(true)
        .zoomAccess(true)
        .onControllerAttached(() => {
          this.registerJavaScriptProxy();
        })
        .onPageEnd(() => {
          this.applyWebTheme();
          this.syncNativeToolSettings();
          this.startStatePolling();
        })
        .onErrorReceive((event) => {
          if (event?.error?.getErrorCode() === 1001) {
            this.connected = false;
            this.scheduleReconnect(250);
          }
        })
      if (this.appMode === 'pdf' && (this.documentName === Strings.source('waitPDFTitle') || this.documentName === Strings.waitPDFTitle)) {
        Column() {
          EmptyState({ icon: DT.iconPdf(this.darkMode), title: Strings.waitPDFTitle, message: Strings.waitPDFDescription,
            actionTitle: Strings.pairingTitle, action: () => this.disconnect() })
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(DT.canvas(this.darkMode))
      }
    }
    .width('100%').height('100%')
    .onHover((isHover: boolean, event: HoverEvent) => {
      if (!isHover) {
        this.handleHoverExit();
      }
    })
    .onHoverMove((event: HoverEvent) => {
      this.handleHoverMove(event);
    })
    .onTouch((event: TouchEvent) => {
      this.handlePenTouch(event);
    })
    .onAreaChange((_, area) => {
      this.padAreaWidth = Math.max(1, area.width as number);
      this.padAreaHeight = Math.max(1, area.height as number);
    })
  }

  // ==================== 底部原生工具栏 ====================
  @Builder ToolbarRow() {
    Scroll() {
      Row({ space: DT.spacingS4 }) {
        Button() {
          Text(Strings.glyphPen).fontSize(DT.fontBody).fontColor(!this.eraser && !this.highlighter ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
        }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
        .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0)
        .backgroundColor(!this.eraser && !this.highlighter ? DT.accentSoft(this.darkMode) : DT.control(this.darkMode))
        .fontColor(!this.eraser && !this.highlighter ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
        .border({ width: DT.layoutStroke, color: !this.eraser && !this.highlighter ? DT.accentSoft(this.darkMode) : DT.clear(this.darkMode) })
        .borderRadius(DT.radiusSmall)
        .accessibilityText(Strings.pen)
        .onClick(() => this.selectPenTool())

        Button() {
          this.HighlighterGlyph(this.highlighter)
        }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
        .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0)
        .backgroundColor(this.highlighter ? DT.accentSoft(this.darkMode) : DT.control(this.darkMode))
        .border({ width: DT.layoutStroke, color: this.highlighter ? DT.accentSoft(this.darkMode) : DT.clear(this.darkMode) })
        .borderRadius(DT.radiusSmall)
        .accessibilityText(Strings.highlighter)
        .onClick(() => this.selectHighlighterTool())

        Button() {
          this.EraserGlyph(this.eraser)
        }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
        .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0)
        .backgroundColor(this.eraser ? DT.accentSoft(this.darkMode) : DT.control(this.darkMode))
        .fontColor(this.eraser ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
        .border({ width: DT.layoutStroke, color: this.eraser ? DT.accentSoft(this.darkMode) : DT.clear(this.darkMode) })
        .borderRadius(DT.radiusSmall)
        .accessibilityText(Strings.eraser)
        .onClick(() => this.selectEraserTool())

        this.ToolDivider()
        Button(Strings.glyphUndo)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0).fontSize(DT.fontBody)
          .enabled(this.canUndo)
          .backgroundColor(DT.control(this.darkMode)).fontColor(this.canUndo ? DT.secondary(this.darkMode) : DT.secondary(this.darkMode))
          .borderRadius(DT.radiusSmall).accessibilityText(Strings.undo).onClick(() => this.runJS('nativeUndo()'))
        Button(Strings.glyphRedo)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0).fontSize(DT.fontBody)
          .enabled(this.canRedo)
          .backgroundColor(DT.control(this.darkMode)).fontColor(this.canRedo ? DT.secondary(this.darkMode) : DT.secondary(this.darkMode))
          .borderRadius(DT.radiusSmall).accessibilityText(Strings.redo).onClick(() => this.runJS('nativeRedo()'))

        if (this.appMode === 'pdf') {
          this.ToolDivider()
          Button(Strings.glyphZoomOut)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
            .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0).fontSize(DT.fontBody)
            .backgroundColor(DT.control(this.darkMode)).fontColor(DT.secondary(this.darkMode)).borderRadius(DT.radiusSmall)
            .onClick(() => this.runJS('nativeZoomOut()'))
          Text(Strings.get('percentValue', [Math.round(this.zoomPercent).toString()]))
            .fontSize(DT.fontCaption).fontWeight(FontWeight.Medium).fontColor(DT.secondary(this.darkMode))
            .width(DT.spacingS40).textAlign(TextAlign.Center)
          Button(Strings.glyphZoomIn)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
            .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0).fontSize(DT.fontBody)
            .backgroundColor(DT.control(this.darkMode)).fontColor(DT.secondary(this.darkMode)).borderRadius(DT.radiusSmall)
            .onClick(() => this.runJS('nativeZoomIn()'))
        }

        this.ToolDivider()

        Button(Strings.glyphClear)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget).padding(DT.spacingS0).fontSize(DT.fontBody).fontWeight(FontWeight.Medium)
          .backgroundColor(DT.control(this.darkMode)).fontColor(DT.error(this.darkMode))
          .borderRadius(DT.radiusSmall)
          .accessibilityText(this.appMode === 'pdf' ? Strings.clearAnnotations : Strings.clearWhiteboard)
          .onClick(() => this.confirmClear())
      }
      .padding({ left: DT.spacingS8, right: DT.spacingS8, top: DT.spacingS4, bottom: DT.spacingS4 })
      .backgroundColor(DT.glass(this.darkMode))
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      
      .border({ width: DT.layoutStroke, color: DT.glass(this.darkMode) })
      .borderRadius(DT.radiusMedium)
      .shadow({ radius: DT.radiusSmall, color: DT.glass(this.darkMode), offsetX: DT.spacingS0, offsetY: DT.spacingS8 })
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').height(DT.layoutToolbarHeight)
  }

  // ==================== 工具栏辅助组件 ====================
  @Builder PenToolMenu() {
    Column({ space: DT.spacingS12 }) {
      Row() {
        Text(Strings.penWidth).fontSize(DT.fontCaption).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode))
        Blank(1)
        Text(Strings.penWidthLevels).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
      }.width('100%')
      Row({ space: DT.spacingS8 }) {
        this.PenLevelButton(1.2, '1', 1)
        this.PenLevelButton(2.2, '2', 2)
        this.PenLevelButton(3.5, '3', 4)
        this.PenLevelButton(5.5, '4', 7)
      }
      Divider().color(DT.control(this.darkMode))
      Row() {
        Text(Strings.penColor).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium).fontColor(DT.secondary(this.darkMode))
        Blank(1)
        Row({ space: DT.spacingS8 }) {
          this.ColorSwatch(DT.inkInk)
          this.ColorSwatch(DT.inkColor7)
          this.ColorSwatch(DT.inkColor8)
          this.ColorSwatch(DT.inkColor9)
        }
      }.width('100%')
    }
    .width(Math.min(DT.layoutMenuMaxWidth, Math.max(DT.layoutTouchTarget, this.padAreaWidth - DT.spacingS32)))
    .padding({ left: DT.spacingS16, right: DT.spacingS16, top: DT.spacingS16, bottom: DT.spacingS16 })
    .margin({ bottom: this.bottomSafeInset() + DT.spacingS80 })
    .backgroundColor(DT.glass(this.darkMode))
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    
    .border({ width: DT.layoutStroke, color: DT.glass(this.darkMode) })
    .borderRadius(DT.radiusMedium)
    .shadow({ radius: DT.radiusSmall, color: DT.glass(this.darkMode), offsetX: DT.spacingS0, offsetY: DT.spacingS12 })
    .transition(this.toolMenuTransition())
    .zIndex(20)
  }

  @Builder EraserToolMenu() {
    Column({ space: DT.spacingS12 }) {
      Row() {
        Row({ space: DT.spacingS8 }) {
          this.EraserGlyph(true)
          Text(Strings.eraserSettings).fontSize(DT.fontCaption).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode))
        }
        Blank(1)
        Text(Strings.secondaryMenu).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
      }.width('100%')
      Row({ space: DT.spacingS12 }) {
        Stack() {
          Circle().width(DT.spacingS48).height(DT.spacingS48)
            .fill(DT.control(this.darkMode)).stroke(DT.secondary(this.darkMode)).strokeWidth(DT.layoutStroke)
          Text(Strings.get('pixelValue', [Math.round(this.eraserSize).toString()])).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium)
            .fontColor(DT.secondary(this.darkMode))
        }
        Column({ space: DT.spacingS4 }) {
          Text(Strings.eraserRange).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium).fontColor(DT.text(this.darkMode))
          Text(Strings.eraserRing).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
        }.alignItems(HorizontalAlign.Start)
      }
      .width('100%').padding(DT.spacingS8).backgroundColor(DT.control(this.darkMode)).borderRadius(DT.radiusSmall)
      Row({ space: DT.spacingS8 }) {
        this.EraserLevelButton(24, '1', 14)
        this.EraserLevelButton(40, '2', 20)
        this.EraserLevelButton(64, '3', 27)
        this.EraserLevelButton(96, '4', 34)
      }
      Row() {
        Button(this.pressureEraserEnabled ? Strings.pressureEraseOn : Strings.pressureEraseOff)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .height(DT.layoutTouchTarget).fontSize(DT.fontCaption).padding({ left: DT.spacingS8, right: DT.spacingS8 })
          .backgroundColor(this.pressureEraserEnabled
            ? DT.glass(this.darkMode)
            : DT.control(this.darkMode))
          .fontColor(this.pressureEraserEnabled ? DT.success(this.darkMode) : DT.secondary(this.darkMode))
          .border({
            width: DT.layoutStroke,
            color: this.pressureEraserEnabled
              ? DT.glass(this.darkMode)
              : DT.control(this.darkMode)
          })
          .borderRadius(DT.radiusSmall).onClick(() => this.togglePressureEraser())
        Blank(1)
        Button(Strings.get('sensitivityValue', [this.pressureSensitivityLabel()]))
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
          .height(DT.layoutTouchTarget).fontSize(DT.fontCaption).padding({ left: DT.spacingS8, right: DT.spacingS8 })
          .enabled(this.pressureEraserEnabled)
          .backgroundColor(DT.control(this.darkMode))
          .fontColor(this.pressureEraserEnabled ? DT.secondary(this.darkMode) : DT.secondary(this.darkMode))
          .border({ width: DT.layoutStroke, color: DT.control(this.darkMode) })
          .borderRadius(DT.radiusSmall).onClick(() => this.cyclePressureSensitivity())
      }.width('100%')
    }
    .width(Math.min(DT.layoutMenuMaxWidth, Math.max(DT.layoutTouchTarget, this.padAreaWidth - DT.spacingS32)))
    .padding({ left: DT.spacingS16, right: DT.spacingS16, top: DT.spacingS16, bottom: DT.spacingS16 })
    .margin({ bottom: this.bottomSafeInset() + DT.spacingS80 })
    .backgroundColor(DT.glass(this.darkMode))
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    
    .border({ width: DT.layoutStroke, color: DT.glass(this.darkMode) })
    .borderRadius(DT.radiusMedium)
    .shadow({ radius: DT.radiusSmall, color: DT.glass(this.darkMode), offsetX: DT.spacingS0, offsetY: DT.spacingS12 })
    .transition(this.toolMenuTransition())
    .zIndex(20)
  }

  @Builder HighlighterToolMenu() {
    Column({ space: DT.spacingS12 }) {
      Row() {
        Row({ space: DT.spacingS8 }) {
          this.HighlighterGlyph(true)
          Text(Strings.highlighter).fontSize(DT.fontCaption).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode))
        }
        Blank(1)
        Text(Strings.highlighterHold).fontSize(DT.fontCaption).fontColor(DT.warning(this.darkMode))
      }.width('100%')
      Column({ space: DT.spacingS8 }) {
        Row() {
          Text(Strings.width).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium).fontColor(DT.secondary(this.darkMode))
          Blank(1)
          Text(Strings.get('pixelValue', [Math.round(this.highlighterWidth).toString()])).fontSize(DT.fontCaption).fontColor(DT.warning(this.darkMode))
        }.width('100%')
        Row({ space: DT.spacingS8 }) {
          this.HighlighterWidthButton(8, '1', 3)
          this.HighlighterWidthButton(14, '2', 5)
          this.HighlighterWidthButton(22, '3', 8)
          this.HighlighterWidthButton(32, '4', 11)
        }
      }
      Divider().color(DT.control(this.darkMode))
      Column({ space: DT.spacingS8 }) {
        Row() {
          Text(Strings.opacity).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium).fontColor(DT.secondary(this.darkMode))
          Blank(1)
          Text(Strings.get('percentValue', [Math.round(this.highlighterOpacity * 100).toString()])).fontSize(DT.fontCaption).fontColor(DT.warning(this.darkMode))
        }.width('100%')
        Row({ space: DT.spacingS8 }) {
          this.HighlighterOpacityButton(0.18, '18%')
          this.HighlighterOpacityButton(0.28, '28%')
          this.HighlighterOpacityButton(0.40, '40%')
          this.HighlighterOpacityButton(0.55, '55%')
        }
      }
    }
    .width(Math.min(DT.layoutMenuMaxWidth, Math.max(DT.layoutTouchTarget, this.padAreaWidth - DT.spacingS32)))
    .padding({ left: DT.spacingS16, right: DT.spacingS16, top: DT.spacingS16, bottom: DT.spacingS16 })
    .margin({ bottom: this.bottomSafeInset() + DT.spacingS80 })
    .backgroundColor(DT.glass(this.darkMode))
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    
    .border({ width: DT.layoutStroke, color: DT.glass(this.darkMode) })
    .borderRadius(DT.radiusMedium)
    .shadow({ radius: DT.radiusSmall, color: DT.glass(this.darkMode), offsetX: DT.spacingS0, offsetY: DT.spacingS12 })
    .transition(this.toolMenuTransition())
    .zIndex(20)
  }

  @Builder EraserGlyph(active: boolean) {
    Row() {
      Rect().width(DT.spacingS8).height(DT.spacingS12).fill(active ? DT.accent(this.darkMode) : DT.secondary(this.darkMode))
      Rect().width(DT.spacingS8).height(DT.spacingS12).fill(DT.glass(this.darkMode))
    }
    .width(DT.spacingS20).height(DT.spacingS16)
    .border({ width: DT.layoutStroke, color: active ? DT.secondary(this.darkMode) : DT.secondary(this.darkMode) })
    .borderRadius(DT.radiusSmall)
    .rotate({ angle: -32 })
  }

  @Builder HighlighterGlyph(active: boolean) {
    Stack() {
      Rect().width(DT.spacingS8).height(DT.spacingS16)
        .fill(active ? DT.secondary(this.darkMode) : DT.secondary(this.darkMode))
        .borderRadius({ topLeft: DT.radiusSmall, topRight: DT.radiusSmall, bottomLeft: DT.radiusSmall, bottomRight: DT.radiusSmall })
      Rect().width(DT.spacingS16).height(DT.spacingS4)
        .fill(active ? DT.glass(this.darkMode) : DT.glass(this.darkMode))
        .margin({ top: DT.spacingS16 })
        .borderRadius(DT.radiusSmall)
    }
    .width(DT.spacingS24).height(DT.spacingS24)
    .rotate({ angle: -28 })
  }

  @Builder HighlighterWidthButton(widthValue: number, label: string, sampleWidth: number) {
    Button() {
      Column({ space: DT.spacingS4 }) {
        Divider().width(DT.spacingS40).strokeWidth(sampleWidth).color(DT.secondary(this.darkMode))
        Text(label).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium)
      }
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
    .layoutWeight(1).height(DT.spacingS56).padding(DT.spacingS0)
    .backgroundColor(this.highlighterWidth === widthValue
      ? DT.glass(this.darkMode)
      : DT.control(this.darkMode))
    .fontColor(this.highlighterWidth === widthValue ? DT.warning(this.darkMode) : DT.secondary(this.darkMode))
    .border({
      width: DT.layoutStroke,
      color: this.highlighterWidth === widthValue
        ? DT.glass(this.darkMode)
        : DT.control(this.darkMode)
    })
    .borderRadius(DT.radiusSmall)
    .onClick(() => this.setHighlighterWidth(widthValue))
  }

  @Builder HighlighterOpacityButton(opacityValue: number, label: string) {
    Button() {
      Column({ space: DT.spacingS4 }) {
        Rect().width(DT.spacingS40).height(DT.spacingS12).fill(DT.inkHighlight).opacity(opacityValue).borderRadius(DT.radiusSmall)
        Text(label).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium)
      }
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
    .layoutWeight(1).height(DT.spacingS52).padding(DT.spacingS0)
    .backgroundColor(Math.abs(this.highlighterOpacity - opacityValue) < 0.001
      ? DT.accentSoft(this.darkMode)
      : DT.control(this.darkMode))
    .fontColor(Math.abs(this.highlighterOpacity - opacityValue) < 0.001 ? DT.warning(this.darkMode) : DT.secondary(this.darkMode))
    .border({
      width: DT.layoutStroke,
      color: Math.abs(this.highlighterOpacity - opacityValue) < 0.001
        ? DT.accentSoft(this.darkMode)
        : DT.control(this.darkMode)
    })
    .borderRadius(DT.radiusSmall)
    .onClick(() => this.setHighlighterOpacity(opacityValue))
  }

  @Builder ColorSwatch(colorValue: string) {
    Button() {
      Circle().width(DT.spacingS20).height(DT.spacingS20).fill(colorValue)
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
    .width(DT.layoutTouchTarget).height(DT.layoutTouchTarget)
    .border({
      width: this.color === colorValue ? DT.layoutStroke * 2 : DT.layoutStroke,
      color: this.color === colorValue ? DT.text(this.darkMode) : DT.control(this.darkMode)
    })
    .backgroundColor(this.color === colorValue
      ? DT.accentSoft(this.darkMode)
      : DT.control(this.darkMode))
    .borderRadius(DT.radiusSmall)
    .onClick(() => {
      this.color = colorValue;
      this.eraser = false;
      this.highlighter = false;
      this.openToolMenu = 'pen';
      this.runJS("nativeSetTool('ink')");
      this.runJS(`nativeSetColor('${colorValue}')`);
    })
  }

  @Builder PenLevelButton(widthValue: number, label: string, sampleWidth: number) {
    Button() {
      Column({ space: DT.spacingS4 }) {
        Divider().width(DT.spacingS40).strokeWidth(sampleWidth)
          .color(this.penWidthLevel() === widthValue ? DT.accent(this.darkMode) : DT.secondary(this.darkMode))
        Text(label).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium)
      }
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
      .layoutWeight(1).height(DT.spacingS56)
      .backgroundColor(this.penWidthLevel() === widthValue
        ? DT.accentSoft(this.darkMode)
        : DT.control(this.darkMode))
      .fontColor(this.penWidthLevel() === widthValue ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
      .border({
        width: DT.layoutStroke,
        color: this.penWidthLevel() === widthValue
          ? DT.glass(this.darkMode)
          : DT.control(this.darkMode)
      })
      .borderRadius(DT.radiusSmall).padding(DT.spacingS0)
      .onClick(() => {
        this.penWidth = widthValue;
        this.eraser = false;
        this.highlighter = false;
        this.openToolMenu = 'pen';
        this.runJS("nativeSetTool('ink')");
        this.runJS(`nativeSetWidth(${widthValue})`);
      })
  }

  @Builder EraserLevelButton(sizeValue: number, label: string, previewSize: number) {
    Button() {
      Column({ space: DT.spacingS4 }) {
        Circle().width(previewSize).height(previewSize)
          .fill(this.eraserSizeLevel() === sizeValue
            ? DT.glass(this.darkMode)
            : DT.control(this.darkMode))
          .stroke(this.eraserSizeLevel() === sizeValue ? DT.accent(this.darkMode) : DT.secondary(this.darkMode)).strokeWidth(DT.layoutStroke)
        Text(label).fontSize(DT.fontCaption).fontWeight(FontWeight.Medium)
      }
    }
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget })
    .layoutWeight(1).height(DT.spacingS64).padding(DT.spacingS0)
    .backgroundColor(this.eraserSizeLevel() === sizeValue
      ? DT.accentSoft(this.darkMode)
      : DT.control(this.darkMode))
    .fontColor(this.eraserSizeLevel() === sizeValue ? DT.text(this.darkMode) : DT.secondary(this.darkMode))
    .border({
      width: DT.layoutStroke,
      color: this.eraserSizeLevel() === sizeValue
        ? DT.accentSoft(this.darkMode)
        : DT.control(this.darkMode)
    })
    .borderRadius(DT.radiusSmall)
    .onClick(() => this.setEraserSize(sizeValue))
  }

  @Builder ToolDivider() {
    Divider()
      .vertical(true)
      .height(DT.spacingS16).color(DT.control(this.darkMode))
      .margin({ left: DT.spacingS4, right: DT.spacingS4 })
  }

  private applyWebTheme(): void {
    this.runJS(`document.documentElement.dataset.linkdeskTheme='${this.darkMode ? 'dark' : 'light'}'`);
  }
  private headerTitleWidth(): number {
    const reservedSide = Math.max(this.headerLeftWidth, this.headerRightWidth) + 16;
    return Math.max(0, this.headerWidth - reservedSide * 2);
  }

  private setTopBarCollapsed(collapsed: boolean): void {
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? DT.durationNone : DT.durationCollapse,
      curve: DT.curveStandard()
    }, () => {
      this.topBarCollapsed = collapsed;
    });
  }

  private toolMenuTransition(): TransitionEffect {
    if (this.reduceMotion) return TransitionEffect.IDENTITY;
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: DT.spacingS12 }))
      .combine(TransitionEffect.scale({
        x: DT.transformMenuScale,
        y: DT.transformMenuScale,
        centerX: '50%',
        centerY: '100%'
      }))
      .animation({ duration: DT.durationMenuEnter, curve: DT.curveEnter() });
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: DT.spacingS8 }))
      .combine(TransitionEffect.scale({
        x: DT.transformExitScale,
        y: DT.transformExitScale,
        centerX: '50%',
        centerY: '100%'
      }))
      .animation({ duration: DT.durationMenuExit, curve: DT.curveExit() });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  private topSafeInset(): number {
    return Math.max(this.systemTopInset, this.cutoutTopInset);
  }

  private bottomSafeInset(): number {
    return Math.max(this.systemBottomInset, this.navigationBottomInset);
  }

  private updateWindowInset(type: window.AvoidAreaType, area: window.AvoidArea): void {
    const uiContext = this.getUIContext();
    const top = area.visible ? uiContext.px2vp(area.topRect.height) : 0;
    const bottom = area.visible ? uiContext.px2vp(area.bottomRect.height) : 0;
    if (type === window.AvoidAreaType.TYPE_SYSTEM) {
      this.systemTopInset = top;
      this.systemBottomInset = bottom;
    } else if (type === window.AvoidAreaType.TYPE_CUTOUT) {
      this.cutoutTopInset = top;
    } else if (type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      this.navigationBottomInset = bottom;
    }
  }

  private async configureWindowInsets(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const mainWindow = await window.getLastWindow(context);
      this.mainWindow = mainWindow;
      const types: window.AvoidAreaType[] = [
        window.AvoidAreaType.TYPE_SYSTEM,
        window.AvoidAreaType.TYPE_CUTOUT,
        window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
      ];
      for (const type of types) {
        this.updateWindowInset(type, mainWindow.getWindowAvoidArea(type));
      }
      this.avoidAreaListener = (data: window.AvoidAreaOptions): void => {
        this.updateWindowInset(data.type, data.area);
      };
      mainWindow.on('avoidAreaChange', this.avoidAreaListener);
    } catch (_) {}
  }

  private selectPenTool(): void {
    const shouldClose = !this.eraser && !this.highlighter && this.openToolMenu === 'pen';
    this.eraser = false;
    this.highlighter = false;
    this.openToolMenu = shouldClose ? '' : 'pen';
    this.runJS("nativeSetTool('ink')");
  }

  private selectHighlighterTool(): void {
    const shouldClose = this.highlighter && this.openToolMenu === 'highlighter';
    this.eraser = false;
    this.highlighter = true;
    this.openToolMenu = shouldClose ? '' : 'highlighter';
    this.runJS("nativeSetTool('highlighter')");
    this.runJS(`nativeSetHighlighterWidth(${this.highlighterWidth})`);
    this.runJS(`nativeSetHighlighterOpacity(${this.highlighterOpacity})`);
  }

  private selectEraserTool(): void {
    const shouldClose = this.eraser && this.openToolMenu === 'eraser';
    this.eraser = true;
    this.highlighter = false;
    this.openToolMenu = shouldClose ? '' : 'eraser';
    this.runJS("nativeSetTool('eraser')");
  }

  private toggleScreenMirror(): void {
    const requestId = `pad-${Date.now()}`;
    if (this.screenMirroring) {
      this.requestPeerScreenMirror('stop', requestId);
      this.stopScreenMirror(requestId);
      return;
    }
    this.requestPeerScreenMirror('start', requestId);
    setTimeout(() => this.startScreenMirror(requestId), 160);
  }

  private startScreenMirror(requestId: string): void {
    if (this.screenMirroring || (screenMirror.isRunning() as boolean)) {
      this.screenMirroring = true;
      this.reportScreenMirrorStatus('started', requestId);
      void this.refreshRoundTripLiveView();
      return;
    }
    if (this.connectionMode !== 'usb') {
      promptAction.showToast({ message: Strings.switchUSBFirst });
      this.reportScreenMirrorStatus('failed', requestId, Strings.source('mirrorUSBFailure'));
      return;
    }
    const result: number = screenMirror.start('127.0.0.1', 3211) as number;
    if (result === 0) {
      this.screenMirroring = true;
      void this.startMirrorBackgroundTask();
      this.reportScreenMirrorStatus('started', requestId);
      void this.refreshRoundTripLiveView();
      promptAction.showToast({ message: Strings.mirrorRunning });
    } else {
      const error = Strings.source('mirrorStartFailure').replace('{0}', result.toString());
      this.reportScreenMirrorStatus('failed', requestId, error);
      promptAction.showToast({ message: Strings.get('mirrorStartHint', [Strings.get('mirrorStartFailure', [result.toString()])]) });
    }
  }

  private stopScreenMirror(requestId: string): void {
    if (this.screenMirroring || (screenMirror.isRunning() as boolean)) {
      screenMirror.stop();
    }
    this.screenMirroring = false;
    void this.stopMirrorBackgroundTask();
    this.reportScreenMirrorStatus('stopped', requestId);
    void this.refreshRoundTripLiveView();
    promptAction.showToast({ message: Strings.mirrorStopped });
  }

  private handleLiveViewAction(action: string): void {
    if (action === 'startMirror') {
      if (!this.screenMirroring) this.toggleScreenMirror();
    } else if (action === 'stopMirror') {
      if (this.screenMirroring || (screenMirror.isRunning() as boolean)) this.toggleScreenMirror();
    }
  }

  private async refreshRoundTripLiveView(): Promise<void> {
    if (!this.roundTripId) return;
    await RoundTripLiveViewController.update(this.roundTripName, this.screenMirroring);
  }

  private handleScreenMirrorRequest(action: string, requestId: string): void {
    if (action === 'start') {
      this.startScreenMirror(requestId);
    } else if (action === 'stop') {
      this.stopScreenMirror(requestId);
    }
  }

  private reportScreenMirrorStatus(status: string, requestId: string, error: string = ''): void {
    this.runJS(`nativeReportScreenMirrorStatus(${JSON.stringify(status)}, `
      + `${JSON.stringify(requestId)}, ${JSON.stringify(error)})`);
  }

  private requestPeerScreenMirror(action: string, requestId: string): void {
    this.runJS(`nativeRequestScreenMirror(${JSON.stringify(action)}, ${JSON.stringify(requestId)})`);
  }

  private async startMirrorBackgroundTask(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.zhekuan.linkdesk',
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 3211,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(context, ['audioRecording'], agent);
    } catch (error) {
      const failure = error as BusinessError;
      console.error(`Failed to keep screen mirror in background: ${failure.code} ${failure.message}`);
      promptAction.showToast({ message: Strings.mirrorForegroundHint });
    }
  }

  private async stopMirrorBackgroundTask(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      const failure = error as BusinessError;
      console.error(`Failed to stop screen mirror background task: ${failure.code} ${failure.message}`);
    }
  }

  private async handleRoundTripOpen(data: Record<string, Object>): Promise<void> {
    const roundTripId = (data.roundTripId as string) || '';
    const name = (data.name as string) || 'document.pdf';
    const documentId = (data.documentId as string) || '';
    const documentVersion = Number(data.documentVersion || 0);
    const documentHash = (data.documentHash as string) || '';
    if (!roundTripId || !documentId || documentVersion <= 0 || !documentHash) return;
    this.roundTripId = roundTripId;
    this.roundTripName = name;
    this.roundTripStatus = Strings.pdfDownloading;
    this.saveRoundTripState();
    const request = http.createHttp();
    try {
      const url = `http://${this.hostForURL(this.connectedHost)}:3210/api/pdf/${this.connectedRoom}`
        + `?id=${encodeURIComponent(documentId)}&version=${documentVersion}&hash=${documentHash}`;
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 5000,
        readTimeout: 120000
      });
      if (Number(response.responseCode) !== 200) throw new Error(`HTTP ${response.responseCode}`);
      const dataBuffer = response.result as ArrayBuffer;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!context) throw new Error('No UI context');
      const safeName = this.safePDFName(name);
      const path = `${context.filesDir}/roundtrip-${roundTripId}-${safeName}`;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, dataBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      const uri = fileUri.getUriFromPath(path);
      const huaweiNotesWant: Want = {
        action: 'ohos.want.action.viewData',
        bundleName: 'com.huawei.hmos.hinote',
        abilityName: 'HiNotePcMainAbility',
        uri: uri,
        type: 'com.adobe.pdf',
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      const liveViewStarted = await RoundTripLiveViewController.show(this.roundTripName,
        this.screenMirroring);
      if (!liveViewStarted) {
        const reason = RoundTripLiveViewController.lastFailure();
        if (reason) promptAction.showToast({ message: Strings.get('mirrorReturnHint', [reason]) });
      }
      this.roundTripStatus = Strings.notesOpening;
      try {
        await context.startAbility(huaweiNotesWant);
        this.roundTripStatus = Strings.notesOpened;
      } catch (notesError) {
        const notesFailure = notesError as BusinessError;
        console.error(`Failed to open Huawei Notes: ${notesFailure.code} ${notesFailure.message}`);
        const fallbackWant: Want = {
          action: 'ohos.want.action.viewData',
          uri: uri,
          type: 'application/pdf',
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
        };
        await context.startAbility(fallbackWant);
        this.roundTripStatus = Strings.notesFallback;
      }
    } catch (error) {
      const failure = error as BusinessError;
      this.roundTripStatus = Strings.get('externalAppError', [failure.message ?? String(error)]);
      await RoundTripLiveViewController.stop();
      promptAction.showToast({ message: this.roundTripStatus });
    } finally {
      request.destroy();
    }
  }

  private async selectRoundTripReturnPDF(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context || !this.roundTripId) return;
    try {
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['PDF|.pdf']
      });
      if (uris.length > 0) await this.uploadRoundTripURI(uris[0]);
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code !== 13900012) {
        promptAction.showToast({ message: Strings.get('selectReturnError', [failure.message]) });
      }
    }
  }

  private async uploadRoundTripURI(uri: string): Promise<void> {
    if (!uri || !this.roundTripId) {
      promptAction.showToast({ message: Strings.noReturnTask });
      return;
    }
    let file: fileIo.File | undefined = undefined;
    const request = http.createHttp();
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > 250 * 1024 * 1024) throw new Error(Strings.fileSizeUnsupported);
      const buffer = new ArrayBuffer(stat.size);
      const readBytes = fileIo.readSync(file.fd, buffer);
      if (readBytes !== stat.size) throw new Error(Strings.fileReadIncomplete);
      let name = this.roundTripName.replace(/\.pdf$/i, '') + Strings.source('annotatedSuffix');
      try { name = new fileUri.FileUri(uri).name || name; } catch (_) {}
      this.roundTripStatus = Strings.pdfReturning;
      const response = await request.request(
        `http://${this.hostForURL(this.connectedHost)}:3210/api/roundtrip/return/${this.connectedRoom}`,
        {
          method: http.RequestMethod.POST,
          header: {
            'content-type': 'application/pdf',
            'x-roundtrip-id': this.roundTripId,
            'x-roundtrip-name': encodeURIComponent(name)
          },
          extraData: buffer,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 5000,
          readTimeout: 120000
        }
      );
      if (Number(response.responseCode) !== 201) throw new Error(`HTTP ${response.responseCode}`);
      this.roundTripStatus = Strings.returnedMac;
      this.roundTripId = '';
      this.roundTripName = '';
      this.saveRoundTripState();
      await RoundTripLiveViewController.stop();
      promptAction.showToast({ message: Strings.returnSaveHint });
    } catch (error) {
      const failure = error as BusinessError;
      this.roundTripStatus = Strings.get('returnError', [failure.message ?? String(error)]);
      promptAction.showToast({ message: this.roundTripStatus });
    } finally {
      if (file) fileIo.closeSync(file);
      request.destroy();
    }
  }

  private saveRoundTripState(): void {
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
      store.putSync('roundTripId', this.roundTripId);
      store.putSync('roundTripName', this.roundTripName);
      store.flushSync();
    } catch (_) {}
  }

  private safePDFName(value: string): string {
    const cleaned = value.replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim();
    const name = cleaned.length > 0 ? cleaned.slice(0, 160) : 'document.pdf';
    return name.toLowerCase().endsWith('.pdf') ? name : `${name}.pdf`;
  }

  private penWidthLevel(): number {
    if (this.penWidth < 1.8) return 1.2;
    if (this.penWidth < 2.9) return 2.2;
    if (this.penWidth < 4.6) return 3.5;
    return 5.5;
  }

  private eraserSizeLevel(): number {
    if (this.eraserSize <= 32) return 24;
    if (this.eraserSize <= 52) return 40;
    if (this.eraserSize <= 80) return 64;
    return 96;
  }

  private setEraserSize(sizeValue: number): void {
    this.eraserSize = sizeValue;
    this.runJS(`nativeSetEraserSize(${this.eraserSize})`);
    this.saveToolPreferences();
  }

  private setHighlighterWidth(widthValue: number): void {
    this.highlighterWidth = widthValue;
    this.runJS(`nativeSetHighlighterWidth(${widthValue})`);
    this.saveToolPreferences();
  }

  private setHighlighterOpacity(opacityValue: number): void {
    this.highlighterOpacity = opacityValue;
    this.runJS(`nativeSetHighlighterOpacity(${opacityValue})`);
    this.saveToolPreferences();
  }

  private confirmClear(): void {
    this.openToolMenu = '';
    promptAction.showDialog({
      title: this.appMode === 'pdf' ? Strings.clearAnnotations : Strings.clearWhiteboard,
      message: this.appMode === 'pdf'
        ? Strings.clearPDFConfirm
        : Strings.clearWhiteboardConfirm,
      buttons: [
        { text: Strings.cancel, color: DT.secondary(this.darkMode) },
        { text: Strings.confirm, color: DT.secondary(this.darkMode) }
      ]
    }).then((res: Object) => {
      if ((res as Record<string, number>)['index'] === 1) this.runJS('nativeClear()');
    }).catch(() => {});
  }

  private togglePressureEraser(): void {
    this.pressureEraserEnabled = !this.pressureEraserEnabled;
    this.saveToolPreferences();
  }

  private cyclePressureSensitivity(): void {
    if (this.pressureSensitivity === 'sensitive') {
      this.pressureSensitivity = 'standard';
    } else if (this.pressureSensitivity === 'standard') {
      this.pressureSensitivity = 'steady';
    } else {
      this.pressureSensitivity = 'sensitive';
    }
    this.saveToolPreferences();
  }

  private pressureSensitivityLabel(): string {
    if (this.pressureSensitivity === 'sensitive') return Strings.sensitivityHigh;
    if (this.pressureSensitivity === 'steady') return Strings.sensitivityLow;
    return Strings.sensitivityMedium;
  }

  private pressureEraserThreshold(): number {
    if (this.pressureSensitivity === 'sensitive') return 0.72;
    if (this.pressureSensitivity === 'steady') return 0.90;
    return 0.82;
  }

  private saveToolPreferences(): void {
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
      store.putSync('eraserSize', this.eraserSize);
      store.putSync('highlighterWidth', this.highlighterWidth);
      store.putSync('highlighterOpacity', this.highlighterOpacity);
      store.putSync('pressureEraserEnabled', this.pressureEraserEnabled);
      store.putSync('pressureSensitivity', this.pressureSensitivity);
      store.flushSync();
    } catch (_) {}
  }

  private syncNativeToolSettings(): void {
    [80, 320, 900].forEach((delay: number) => {
      setTimeout(() => this.applyNativeToolSettings(), delay);
    });
  }

  private applyNativeToolSettings(): void {
    this.runJS(`typeof nativeSetEraserSize === 'function' && nativeSetEraserSize(${this.eraserSize})`);
    this.runJS(`typeof nativeSetHighlighterWidth === 'function' && nativeSetHighlighterWidth(${this.highlighterWidth})`);
    this.runJS(`typeof nativeSetHighlighterOpacity === 'function' && nativeSetHighlighterOpacity(${this.highlighterOpacity})`);
    this.runJS(`typeof nativeSetTool === 'function' && nativeSetTool('${this.eraser ? 'eraser' : (this.highlighter ? 'highlighter' : 'ink')}')`);
  }

  // ==================== 安全调用 runJavaScript ====================
  private runJS(code: string): void {
    try {
      this.webController.runJavaScript(code);
    } catch (_) {}
  }

  private runJSPromise(code: string): void {
    try {
      this.webController.runJavaScript(code)
        .then(() => {})
        .catch(() => {});
    } catch (_) {}
  }

  private enqueuePenScript(code: string): void {
    this.penBridgeQueue.push({ kind: 'script', code });
    this.pumpPenBridge();
  }

  private enqueueNativePenMove(samples: NativePenPoint[]): void {
    if (samples.length === 0) return;
    this.pendingNativeMoveSamples.push(...samples);
    if (this.pendingNativeMoveSamples.length > PEN_BRIDGE_MAX_PENDING_SAMPLES) {
      this.pendingNativeMoveSamples.splice(
        0,
        this.pendingNativeMoveSamples.length - PEN_BRIDGE_MAX_PENDING_SAMPLES
      );
    }
    if (!this.penMoveCommandQueued) {
      this.penMoveCommandQueued = true;
      this.penBridgeQueue.push({ kind: 'move' });
    }
    this.pumpPenBridge();
  }

  private enqueueStraightUpdate(point: NativePenPoint): void {
    this.pendingStraightUpdate = point;
    if (!this.straightUpdateCommandQueued) {
      this.straightUpdateCommandQueued = true;
      this.penBridgeQueue.push({ kind: 'straight-update' });
    }
    this.pumpPenBridge();
  }

  private pumpPenBridge(): void {
    if (this.penBridgeInFlight) return;
    const command = this.penBridgeQueue.shift();
    if (!command) return;
    let code = command.code || '';
    if (command.kind === 'move') {
      this.penMoveCommandQueued = false;
      const samples = this.pendingNativeMoveSamples.splice(0, PEN_BRIDGE_MAX_SAMPLES_PER_CALL);
      if (this.pendingNativeMoveSamples.length > 0 && !this.penMoveCommandQueued) {
        this.penMoveCommandQueued = true;
        this.penBridgeQueue.unshift({ kind: 'move' });
      }
      if (samples.length === 0) {
        this.pumpPenBridge();
        return;
      }
      code = `nativePenMove(${JSON.stringify(samples)})`;
    } else if (command.kind === 'straight-update') {
      this.straightUpdateCommandQueued = false;
      const point = this.pendingStraightUpdate;
      this.pendingStraightUpdate = undefined;
      if (!point) {
        this.pumpPenBridge();
        return;
      }
      code = `nativePenUpdateStraight(${JSON.stringify(point)})`;
    }
    if (code.length === 0) {
      this.pumpPenBridge();
      return;
    }
    this.penBridgeInFlight = true;
    try {
      this.webController.runJavaScript(code)
        .then(() => this.finishPenBridgeCommand())
        .catch(() => this.finishPenBridgeCommand());
    } catch (_) {
      this.finishPenBridgeCommand();
    }
  }

  private finishPenBridgeCommand(): void {
    this.penBridgeInFlight = false;
    this.pumpPenBridge();
    if (!this.penBridgeInFlight && this.penBridgeQueue.length === 0 && !this.penStrokeActive) {
      this.applyPendingTransportSwitch();
    }
  }

  private resetPenBridge(): void {
    this.penBridgeQueue = [];
    this.pendingNativeMoveSamples = [];
    this.penMoveCommandQueued = false;
    this.pendingStraightUpdate = undefined;
    this.straightUpdateCommandQueued = false;
  }

  // ==================== 连接逻辑 ====================
  private async startNativePairingScan(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      });
      const pairing = this.parseScannedPairingLink(result.originalValue);
      if (!pairing) {
        promptAction.showToast({ message: Strings.scanInvalid });
        return;
      }
      this.applyScannedPairingLink(pairing);
    } catch (reason) {
      const error = reason as BusinessError;
      if (error.code !== 1000500002) {
        promptAction.showToast({ message: Strings.scanUnavailable });
      }
    }
  }

  private parseScannedPairingLink(value: string): ScannedPairingLink | undefined {
    const scanned = value.trim();
    let host = '';
    let room = '';

    const webAddress = scanned.match(
      /^https?:\/\/(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9.-]+)(?::(\d+))?(?:[\/?#]|$)/i
    );
    if (webAddress) {
      const port = webAddress[2] || '80';
      if (port !== '3210') return undefined;
      host = webAddress[1];
      const roomMatch = scanned.match(/[?&]room=([A-Za-z0-9]{6})(?:&|#|$)/i);
      room = roomMatch ? roomMatch[1] : '';
    } else if (/^bijiqiao:\/\/connect(?:\/)?\?/i.test(scanned)) {
      const hostMatch = scanned.match(/[?&]host=([^&#]+)/i);
      const roomMatch = scanned.match(/[?&]room=([A-Za-z0-9]{6})(?:&|#|$)/i);
      if (!hostMatch || !roomMatch) return undefined;
      try { host = decodeURIComponent(hostMatch[1]); } catch (_) { return undefined; }
      room = roomMatch[1];
    } else {
      return undefined;
    }

    const normalizedHost = this.normalizedWirelessHost(host);
    const validHost = /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(normalizedHost)
      || /^[0-9A-Fa-f:.%]+$/.test(normalizedHost);
    const normalizedRoom = room.toUpperCase();
    if (!validHost || !/^[A-Z0-9]{6}$/.test(normalizedRoom)) return undefined;
    return { host: normalizedHost, room: normalizedRoom };
  }

  private applyScannedPairingLink(pairing: ScannedPairingLink): void {
    this.connectionGeneration += 1;
    this.connectionAttemptInFlight = false;
    if (this.showPad) this.disconnect();
    this.room = pairing.room;
    this.host = pairing.host;
    this.discoveredWirelessHost = pairing.host;
    this.connectionMode = 'wifi';
    this.connectionPreference = 'automatic';
    this.connectedHost = '';
    this.connectedRoom = '';
    this.connected = false;

    try {
      const context = this.getUIContext().getHostContext();
      if (context) {
        const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
        store.putSync('host', pairing.host);
        store.putSync('room', pairing.room);
        store.putSync('connectionMode', 'wifi');
        store.putSync('connectionPreference', 'automatic');
        store.putSync('automaticDiscoveryV1', true);
        store.flushSync();
      }
    } catch (_) {}

    promptAction.showToast({ message: Strings.get('scanRecognized', [pairing.room]) });
    this.startRelayDiscovery();
    this.scheduleReconnect(0);
  }

  private connectToPad(): void {
    const normalizedRoom = this.room.trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(normalizedRoom)) return;
    this.room = normalizedRoom;
    this.startRelayDiscovery();
    this.scheduleReconnect(0);
  }

  private scheduleReconnect(delay: number = 400): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.attemptBestConnection();
    }, delay);
  }

  private async attemptBestConnection(): Promise<void> {
    if (this.connectionAttemptInFlight || !/^[A-Z0-9]{6}$/.test(this.room)) return;
    if (this.connected && this.showPad) return;
    this.connectionAttemptInFlight = true;
    const generation = this.connectionGeneration;
    const candidates: RelayCandidate[] = [];

    if (this.connectionPreference === 'automatic' || this.connectionPreference === 'usb') {
      candidates.push({ host: '127.0.0.1', mode: 'usb' });
    }
    if (this.connectionPreference === 'automatic' || this.connectionPreference === 'wifi') {
      if (this.discoveredWirelessHost.length > 0) {
        candidates.push({ host: this.discoveredWirelessHost, mode: 'wifi' });
      }
      const savedHost = this.normalizedWirelessHost(this.host);
      if (savedHost.length > 0 && savedHost !== this.discoveredWirelessHost) {
        candidates.push({ host: savedHost, mode: 'wifi' });
      }
    }

    let opened = false;
    try {
      for (const candidate of candidates) {
        const reachable = await this.isRelayReachable(candidate.host);
        if (generation !== this.connectionGeneration) break;
        if (reachable) {
          this.openRelay(candidate.host, candidate.mode);
          opened = true;
          break;
        }
      }
    } catch (_) {}
    this.connectionAttemptInFlight = false;

    if (!opened && !this.connected) {
      this.restartRelayDiscovery(1800);
      this.scheduleReconnect(2200);
    }
  }

  private async isRelayReachable(host: string): Promise<boolean> {
    const request = http.createHttp();
    try {
      const response = await request.request(`http://${this.hostForURL(host)}:3210/config`, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 850,
        readTimeout: 850
      });
      if (Number(response.responseCode) !== 200 || typeof response.result !== 'string') return false;
      const config = JSON.parse(response.result) as Record<string, Object>;
      return Number(config['relayVersion']) >= 10
        && Number(config['protocolVersion']) === INKBRIDGE_PROTOCOL_VERSION;
    } catch (_) {
      return false;
    } finally {
      request.destroy();
    }
  }

  private openRelay(host: string, mode: string): void {
    const normalizedRoom = this.room.trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(normalizedRoom)) return;
    const wasShowingPad = this.showPad;
    this.connectionMode = mode;
    this.connectionPreference = this.connectionPreference === 'automatic'
      ? 'automatic'
      : mode;
    if (mode === 'wifi') {
      this.host = host;
      this.discoveredWirelessHost = host;
    }

    try {
      const context = this.getUIContext().getHostContext();
      if (context) {
        const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
        store.putSync('host', mode === 'wifi' ? host : this.host);
        store.putSync('room', normalizedRoom);
        store.putSync('connectionMode', this.connectionMode);
        store.putSync('connectionPreference', this.connectionPreference);
        store.putSync('appMode', this.appMode);
        store.flushSync();
      }
    } catch (_) {}

    this.connectedHost = host;
    this.connectedRoom = normalizedRoom;
    this.connected = false;
    this.webUrl = this.makeModeUrl(this.appMode);
    this.showPad = true;
    if (wasShowingPad) {
      try { this.webController.loadUrl(this.webUrl); } catch (_) {}
    }
  }

  private normalizedWirelessHost(value: string): string {
    let host = value.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
    if (host.startsWith('[')) {
      const close = host.indexOf(']');
      return close > 1 ? host.slice(1, close) : '';
    }
    host = host.replace(/:\d+$/, '');
    return host;
  }

  private hostForURL(host: string): string {
    return host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
  }

  private startRelayDiscovery(): void {
    if (this.discoveryService) return;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const service = mdns.createDiscoveryService(context, '_inkbridge._tcp');
      this.serviceFoundCallback = (serviceInfo: mdns.LocalServiceInfo): void => {
        if (serviceInfo.serviceName !== `InkBridge-${this.room}`) return;
        void this.resolveRelayService(serviceInfo);
      };
      this.serviceLostCallback = (serviceInfo: mdns.LocalServiceInfo): void => {
        if (serviceInfo.serviceName !== `InkBridge-${this.room}`) return;
        this.discoveredWirelessHost = '';
        if (this.connectionMode === 'wifi') {
          this.connected = false;
          this.scheduleReconnect(300);
        }
      };
      service.on('serviceFound', this.serviceFoundCallback);
      service.on('serviceLost', this.serviceLostCallback);
      this.discoveryService = service;
      service.startSearchingMDNS();
    } catch (_) {
      this.discoveryService = undefined;
      this.restartRelayDiscovery(1500);
    }
  }

  private async resolveRelayService(serviceInfo: mdns.LocalServiceInfo): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) return;
      const resolved = await mdns.resolveLocalService(context, serviceInfo);
      const address = resolved.host?.address?.trim() ?? '';
      if (address.length === 0 || resolved.port !== 3210) return;
      this.discoveredWirelessHost = address;
      this.host = address;
      if (!this.connected && this.connectionPreference !== 'usb') this.scheduleReconnect(0);
    } catch (_) {
      this.restartRelayDiscovery(900);
    }
  }

  private restartRelayDiscovery(delay: number): void {
    if (this.discoveryRestartTimer) return;
    this.discoveryRestartTimer = setTimeout(() => {
      this.discoveryRestartTimer = undefined;
      this.stopRelayDiscovery();
      this.startRelayDiscovery();
    }, delay);
  }

  private stopRelayDiscovery(): void {
    const service = this.discoveryService;
    if (!service) return;
    try {
      if (this.serviceFoundCallback) service.off('serviceFound', this.serviceFoundCallback);
      if (this.serviceLostCallback) service.off('serviceLost', this.serviceLostCallback);
      service.stopSearchingMDNS();
    } catch (_) {}
    this.discoveryService = undefined;
    this.serviceFoundCallback = undefined;
    this.serviceLostCallback = undefined;
  }

  private makeModeUrl(mode: string): string {
    LinkDeskTheme.configure(this.connectedHost, this.connectedRoom);
    const role = mode === 'whiteboard' ? 'pad' : 'pdfpad';
    const request = this.activeTransportRequestId.length > 0
      ? `&transportRequestId=${encodeURIComponent(this.activeTransportRequestId)}`
      : '';
    return `http://${this.hostForURL(this.connectedHost)}:3210/?role=${role}&room=${this.connectedRoom}&nativeHover=true&nativeInput=true&transport=${this.connectionMode}&transportPreference=${this.connectionPreference}&appVersion=${INKBRIDGE_APP_VERSION}&protocolVersion=${INKBRIDGE_PROTOCOL_VERSION}${request}`;
  }

  private requestTransportSwitch(mode: string, preference: string, requestId: string): void {
    if (mode !== 'wifi' && mode !== 'usb') return;
    if (this.penStrokeActive || this.pendingPenStart !== undefined
      || this.penBridgeInFlight || this.penBridgeQueue.length > 0) {
      this.pendingTransportMode = mode;
      this.pendingTransportPreference = preference;
      this.pendingTransportRequestId = requestId;
      return;
    }
    this.applyTransportSwitch(mode, preference, requestId);
  }

  private applyTransportSwitch(mode: string, preference: string, requestId: string): void {
    const normalizedPreference = preference === 'automatic' || preference === 'usb' || preference === 'wifi'
      ? preference
      : mode;
    const wirelessHost = this.discoveredWirelessHost.length > 0
      ? this.discoveredWirelessHost
      : this.normalizedWirelessHost(this.host);
    if (mode === 'wifi' && wirelessHost.length === 0) {
      this.connectionPreference = normalizedPreference;
      this.restartRelayDiscovery(0);
      this.scheduleReconnect(200);
      return;
    }
    const nextHost = mode === 'usb' ? '127.0.0.1' : wirelessHost;
    this.connectionPreference = normalizedPreference;
    this.activeTransportRequestId = requestId;
    this.disconnectedPolls = 0;

    try {
      const context = this.getUIContext().getHostContext();
      if (context) {
        const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
        store.putSync('connectionMode', mode);
        store.putSync('connectionPreference', normalizedPreference);
        store.flushSync();
      }
    } catch (_) {}

    if (mode === this.connectionMode && nextHost === this.connectedHost) {
      this.runJS(`nativeReportTransportStatus('${mode}', '${requestId}')`);
      return;
    }
    this.connectionMode = mode;
    this.connectedHost = nextHost;
    this.connected = false;
    this.webUrl = this.makeModeUrl(this.appMode);
    try {
      this.webController.loadUrl(this.webUrl);
    } catch (_) {}
  }

  private applyPendingTransportSwitch(): void {
    if (this.penStrokeActive || this.penBridgeInFlight || this.penBridgeQueue.length > 0
      || this.pendingTransportMode.length === 0) return;
    const mode = this.pendingTransportMode;
    const preference = this.pendingTransportPreference;
    const requestId = this.pendingTransportRequestId;
    this.pendingTransportMode = '';
    this.pendingTransportPreference = '';
    this.pendingTransportRequestId = '';
    this.applyTransportSwitch(mode, preference, requestId);
  }

  private fallbackFromUSB(): void {
    if (this.connectionMode !== 'usb' || this.connectionPreference !== 'automatic') return;
    this.connected = false;
    this.scheduleReconnect(0);
  }

  private switchAppMode(mode: string, announce: boolean): void {
    if ((mode !== 'pdf' && mode !== 'whiteboard') || mode === this.appMode) return;
    this.openToolMenu = '';
    if (announce) {
      this.runJS(`nativeSwitchMode('${mode}')`);
      setTimeout(() => this.switchAppMode(mode, false), 80);
      return;
    }
    this.appMode = mode;
    this.onModeChange(mode);
    this.documentName = mode === 'whiteboard' ? Strings.whiteboardTitle : Strings.waitPDFTitle;
    this.zoomPercent = 100;
    if (this.showPad && this.connectedHost.length > 0 && this.connectedRoom.length === 6) {
      this.webUrl = this.makeModeUrl(mode);
      try {
        this.webController.loadUrl(this.webUrl);
      } catch (_) {}
    }
    try {
      const context = this.getUIContext().getHostContext();
      if (context) {
        const store = preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
        store.putSync('appMode', mode);
        store.flushSync();
      }
    } catch (_) {}
  }

  private disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    this.showPad = false;
    this.openToolMenu = '';
    this.cursorVisible = false;
    this.connected = false;
    this.documentName = Strings.waitPDFTitle;
    this.zoomPercent = 100;
    if (this.hoverThrottleTimer) {
      clearTimeout(this.hoverThrottleTimer);
      this.hoverThrottleTimer = undefined;
    }
    if (this.hoverHideTimer) {
      clearTimeout(this.hoverHideTimer);
      this.hoverHideTimer = undefined;
    }
    if (this.statePollTimer) {
      clearInterval(this.statePollTimer);
      this.statePollTimer = undefined;
    }
    try {
      this.webController.stop();
      this.webController.clearHistory();
    } catch (_) {}
  }

  // ==================== JavaScript Bridge ====================
  private registerJavaScriptProxy(): void {
    try {
      this.webController.registerJavaScriptProxy({
        postMessage: (message: string) => {
          try {
            const data: Record<string, Object> = JSON.parse(message) as Record<string, Object>;
            if (data.type === 'state') {
              this.connected = (data.connected as boolean) ?? false;
              this.documentName = (data.documentName as string) || Strings.waitPDFTitle;
              this.zoomPercent = Math.round(((data.zoom as number) || 1) * 100);
              this.color = (data.color as string) || this.color;
              this.penWidth = (data.width as number) || this.penWidth;
              this.eraser = (data.eraser as boolean) ?? this.eraser;
              const remoteTool = data.tool as string;
              if (remoteTool === 'highlighter') {
                this.highlighter = true;
                this.eraser = false;
              } else if (remoteTool === 'ink') {
                this.highlighter = false;
                this.eraser = false;
              } else if (remoteTool === 'eraser') {
                this.highlighter = false;
                this.eraser = true;
              }
              this.highlighterWidth = (data.highlighterWidth as number) || this.highlighterWidth;
              this.highlighterOpacity = (data.highlighterOpacity as number) || this.highlighterOpacity;
              this.eraserSize = (data.eraserSize as number) || this.eraserSize;
              this.canUndo = (data.canUndo as boolean) ?? this.canUndo;
              this.canRedo = (data.canRedo as boolean) ?? this.canRedo;
              const remoteMode = data.mode as string;
              if ((remoteMode === 'pdf' || remoteMode === 'whiteboard') && remoteMode !== this.appMode) {
                this.switchAppMode(remoteMode, false);
              }
            } else if (data.type === 'mode') {
              const remoteMode = data.mode as string;
              if (remoteMode === 'pdf' || remoteMode === 'whiteboard') this.switchAppMode(remoteMode, false);
            } else if (data.type === 'transport') {
              this.requestTransportSwitch(
                data.mode as string,
                data.preference as string,
                (data.requestId as string) || ''
              );
            } else if (data.type === 'screenMirror') {
              this.handleScreenMirrorRequest(
                data.action as string,
                (data.requestId as string) || ''
              );
            } else if (data.type === 'roundTripOpen') {
              void this.handleRoundTripOpen(data);
            }
          } catch (_) {}
        }
      }, '__nativeHost', ['postMessage']);
    } catch (_) {}
  }

  // ==================== 状态轮询 ====================
  private startStatePolling(): void {
    if (this.statePollTimer) {
      clearInterval(this.statePollTimer);
    }
    this.statePollTimer = setInterval(() => {
      if (this.showPad) {
        try {
          this.webController.runJavaScript("typeof nativeGetState === 'function' ? nativeGetState() : ''")
            .then((result: string) => {
              if (result && result.length > 0) {
                try {
                  const s: Record<string, Object> = JSON.parse(result) as Record<string, Object>;
                  this.connected = (s.connected as boolean) ?? this.connected;
                  if (this.connected) {
                    this.disconnectedPolls = 0;
                    if (this.pendingInitialMode) {
                      this.pendingInitialMode = false;
                      const desiredMode = this.requestedMode === 'whiteboard' ? 'whiteboard' : 'pdf';
                      this.runJS(`nativeSwitchMode('${desiredMode}')`);
                    }
                    if (this.pendingMirrorStart && this.connectionMode === 'usb') {
                      this.pendingMirrorStart = false;
                      this.toggleScreenMirror();
                    }
                  } else {
                    this.disconnectedPolls += 1;
                    if (this.disconnectedPolls >= 4) {
                      this.disconnectedPolls = 0;
                      this.scheduleReconnect(0);
                    }
                  }
                  this.documentName = (s.documentName as string) || this.documentName;
                  this.zoomPercent = Math.round(((s.zoom as number) || 1) * 100);
                  this.color = (s.color as string) || this.color;
                  this.penWidth = (s.width as number) || this.penWidth;
                  this.eraser = (s.eraser as boolean) ?? this.eraser;
                  const remoteTool = s.tool as string;
                  if (remoteTool === 'highlighter') {
                    this.highlighter = true;
                    this.eraser = false;
                  } else if (remoteTool === 'ink') {
                    this.highlighter = false;
                    this.eraser = false;
                  } else if (remoteTool === 'eraser') {
                    this.highlighter = false;
                    this.eraser = true;
                  }
                  this.highlighterWidth = (s.highlighterWidth as number) || this.highlighterWidth;
                  this.highlighterOpacity = (s.highlighterOpacity as number) || this.highlighterOpacity;
                  this.eraserSize = (s.eraserSize as number) || this.eraserSize;
                  this.canUndo = (s.canUndo as boolean) ?? this.canUndo;
                  this.canRedo = (s.canRedo as boolean) ?? this.canRedo;
                  const remoteMode = s.mode as string;
                  if ((remoteMode === 'pdf' || remoteMode === 'whiteboard') && remoteMode !== this.appMode) {
                    this.switchAppMode(remoteMode, false);
                  }
                } catch (_) {}
              }
            }).catch(() => {});
        } catch (_) {}
      }
    }, 500);
  }

  // ==================== 原生悬停处理 ====================
  private handleHoverMove(event: HoverEvent): void {
    if (event.sourceTool !== SourceTool.Pen) return;
    const x = event.x ?? 0;
    const y = event.y ?? 0;
    this.cursorVisible = true;
    this.cursorX = x;
    this.cursorY = y;
    this.pendingHoverX = x;
    this.pendingHoverY = y;
    if (this.hoverHideTimer) clearTimeout(this.hoverHideTimer);
    this.hoverHideTimer = setTimeout(() => this.handleHoverExit(), 240);
    if (!this.hoverThrottleTimer) {
      this.hoverThrottleTimer = setTimeout(() => {
        this.hoverThrottleTimer = undefined;
        this.runJS(`nativeReportHover(${this.pendingHoverX.toFixed(1)}, ${this.pendingHoverY.toFixed(1)})`);
      }, 16);
    }
  }

  private handleHoverExit(): void {
    const shouldNotify = this.cursorVisible || this.hoverThrottleTimer !== undefined;
    this.cursorVisible = false;
    if (this.hoverHideTimer) {
      clearTimeout(this.hoverHideTimer);
      this.hoverHideTimer = undefined;
    }
    if (this.hoverThrottleTimer) {
      clearTimeout(this.hoverThrottleTimer);
      this.hoverThrottleTimer = undefined;
    }
    if (shouldNotify) this.runJS('nativeReportHoverHidden()');
  }

  // 原生手写笔事件：保留历史采样与压感；手指事件继续交给 WebView 导航。
  private handlePenTouch(event: TouchEvent): void {
    if (event.sourceTool !== SourceTool.Pen) return;
    const touch = event.changedTouches[0];
    if (!touch) return;
    // Some HarmonyOS pen frames expose the useful force on BaseEvent while
    // TouchObject still carries zero. Prefer the stronger valid reading.
    const pressure = this.normalizePressure(Math.max(touch.pressure ?? 0, event.pressure ?? 0));

    if (event.type === TouchType.Down) {
      if (this.penStrokeActive || this.pendingPenStart !== undefined) return;
      if (this.hoverHideTimer) {
        clearTimeout(this.hoverHideTimer);
        this.hoverHideTimer = undefined;
      }
      this.penSampleIndex = 0;
      const point = this.nativePenPoint(
        touch.x, touch.y, pressure, event.tiltX, event.tiltY, event.rollAngle, event.timestamp
      );
      const pressureEraser = !this.eraser
        && this.pressureEraserEnabled
        && pressure >= this.pressureEraserThreshold();
      if (this.eraser || !this.pressureEraserEnabled || pressureEraser) {
        this.beginNativePenStroke(point, pressureEraser);
      } else {
        // M-Pencil contact-down commonly reports a light first sample even
        // for a firm press. Keep the first few samples uncommitted so a
        // pressure ramp can choose the tool before the complete stroke locks.
        this.pendingPenStart = point;
        this.pendingPenSamples = [];
        this.pendingPenMaxPressure = pressure;
        this.pendingPenTimer = setTimeout(() => this.commitPendingPenStart(false), 42);
      }
      return;
    }

    if (event.type === TouchType.Move
      && (this.penStrokeActive || this.pendingPenStart !== undefined)) {
      const points = this.nativePenPointsForMove(event, touch, pressure);
      if (this.pendingPenStart !== undefined) {
        this.pendingPenSamples.push(...points);
        points.forEach((point) => {
          this.pendingPenMaxPressure = Math.max(this.pendingPenMaxPressure, point.p);
        });
        if (this.pendingPenMaxPressure >= this.pressureEraserThreshold()) {
          this.commitPendingPenStart(true);
        }
        return;
      }
      // 一旦开始书写，本笔工具保持锁定；中途压力升高不能切换成橡皮擦。
      if (this.strokeEraser) {
        this.cursorVisible = true;
        this.cursorX = touch.x;
        this.cursorY = touch.y;
      }
      if (this.highlighter && !this.strokeEraser) {
        const latest = points[points.length - 1];
        if (latest) this.updateHighlighterStraightCandidate(latest);
        if (this.highlighterStraightLocked && latest) {
          this.enqueueStraightUpdate(latest);
        } else {
          this.enqueueNativePenMove(points);
        }
      } else {
        this.enqueueNativePenMove(points);
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pendingPenStart !== undefined) {
        if (event.type === TouchType.Cancel) {
          this.clearPendingPenStart();
          this.cursorVisible = false;
          this.runJS('nativeReportHoverHidden()');
          this.applyPendingTransportSwitch();
          return;
        }
        this.pendingPenMaxPressure = Math.max(this.pendingPenMaxPressure, pressure);
        this.commitPendingPenStart(
          this.pressureEraserEnabled
            && this.pendingPenMaxPressure >= this.pressureEraserThreshold()
        );
      }
      if (!this.penStrokeActive) return;
      const restorePenAfterStroke = this.strokeEraser && !this.eraser;
      const finalPoint = this.nativePenPoint(
        touch.x, touch.y, pressure, event.tiltX, event.tiltY, event.rollAngle, event.timestamp
      );
      if (event.type === TouchType.Cancel) {
        this.enqueuePenScript('nativePenCancel()');
      } else if (this.highlighterStraightLocked && !this.strokeEraser) {
        this.enqueueStraightUpdate(finalPoint);
        this.enqueuePenScript('nativePenEnd()');
      } else {
        this.enqueuePenScript(`nativePenEnd(${JSON.stringify(finalPoint)})`);
      }
      this.clearHighlighterHold();
      this.penStrokeActive = false;
      this.strokeEraser = false;
      this.cursorVisible = false;
      this.enqueuePenScript('nativeReportHoverHidden()');
      if (restorePenAfterStroke) this.enqueuePenScript('nativeSetEraser(false)');
      this.applyPendingTransportSwitch();
    }
  }

  private beginNativePenStroke(point: NativePenPoint, pressureEraser: boolean): void {
    this.penStrokeActive = true;
    this.strokeEraser = this.eraser || pressureEraser;
    this.cursorX = point.x;
    this.cursorY = point.y;
    this.cursorVisible = this.strokeEraser;
    this.enqueuePenScript(`nativePenStart(${JSON.stringify(point)}, ${pressureEraser})`);
    if (this.highlighter && !this.strokeEraser) this.beginHighlighterHold(point);
  }

  private commitPendingPenStart(pressureEraser: boolean): void {
    const start = this.pendingPenStart;
    if (!start) return;
    const samples = this.pendingPenSamples;
    this.clearPendingPenStart();
    this.beginNativePenStroke(start, pressureEraser);
    if (samples.length > 0) {
      if (this.strokeEraser) {
        const last = samples[samples.length - 1];
        this.cursorVisible = true;
        this.cursorX = last.x;
        this.cursorY = last.y;
      }
      this.enqueueNativePenMove(samples);
      if (this.highlighter && !this.strokeEraser) {
        const latest = samples[samples.length - 1];
        if (latest) this.updateHighlighterStraightCandidate(latest);
      }
    }
  }

  private beginHighlighterHold(point: NativePenPoint): void {
    this.clearHighlighterHold();
    this.highlighterStartPoint = point;
    this.highlighterPausePoint = point;
    this.highlighterLatestPoint = point;
    this.scheduleHighlighterHold();
  }

  private updateHighlighterStraightCandidate(point: NativePenPoint): void {
    this.highlighterLatestPoint = point;
    if (this.highlighterStraightLocked) return;
    const pause = this.highlighterPausePoint;
    if (!pause || Math.hypot(point.x - pause.x, point.y - pause.y) >= HIGHLIGHTER_HOLD_SLOP) {
      this.highlighterPausePoint = point;
      this.scheduleHighlighterHold();
    }
  }

  private scheduleHighlighterHold(): void {
    if (this.highlighterHoldTimer) clearTimeout(this.highlighterHoldTimer);
    this.highlighterHoldTimer = setTimeout(() => {
      this.highlighterHoldTimer = undefined;
      if (!this.penStrokeActive || this.strokeEraser || !this.highlighter
        || !this.highlighterStartPoint || !this.highlighterLatestPoint) return;
      const distance = Math.hypot(
        this.highlighterLatestPoint.x - this.highlighterStartPoint.x,
        this.highlighterLatestPoint.y - this.highlighterStartPoint.y
      );
      if (distance < 10) return;
      this.highlighterStraightLocked = true;
      this.enqueuePenScript('nativePenStraighten()');
    }, HIGHLIGHTER_HOLD_DELAY_MS);
  }

  private clearHighlighterHold(): void {
    if (this.highlighterHoldTimer) clearTimeout(this.highlighterHoldTimer);
    this.highlighterHoldTimer = undefined;
    this.highlighterStartPoint = undefined;
    this.highlighterPausePoint = undefined;
    this.highlighterLatestPoint = undefined;
    this.highlighterStraightLocked = false;
  }

  private clearPendingPenStart(): void {
    if (this.pendingPenTimer) {
      clearTimeout(this.pendingPenTimer);
      this.pendingPenTimer = undefined;
    }
    this.pendingPenStart = undefined;
    this.pendingPenSamples = [];
    this.pendingPenMaxPressure = 0;
  }

  private nativePenPointsForMove(
    event: TouchEvent,
    touch: TouchObject,
    pressure: number
  ): NativePenPoint[] {
    const points: NativePenPoint[] = [];
    event.getHistoricalPoints().forEach((item) => {
      points.push(this.nativePenPoint(
        item.touchObject.x,
        item.touchObject.y,
        this.normalizePressure(item.force),
        event.tiltX,
        event.tiltY,
        event.rollAngle,
        item.timestamp
      ));
    });
    points.push(this.nativePenPoint(
      touch.x, touch.y, pressure, event.tiltX, event.tiltY, event.rollAngle, event.timestamp
    ));
    return points;
  }

  private nativePenPoint(
    x: number,
    y: number,
    pressure: number,
    tiltX: number,
    tiltY: number,
    rollAngle: number | undefined,
    timestamp: number
  ): NativePenPoint {
    const point: NativePenPoint = {
      x,
      y,
      p: pressure,
      tiltX,
      tiltY,
      timestamp,
      sampleIndex: this.penSampleIndex++
    };
    if (rollAngle !== undefined) point.rollAngle = rollAngle;
    return point;
  }

  private normalizePressure(raw: number | undefined): number {
    const value = raw ?? 0.52;
    if (value > 1) return Math.max(0.08, Math.min(1, value / 65535));
    return Math.max(0.08, Math.min(1, value || 0.52));
  }
}
