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
  private pendingInitialMode: boolean = false;
  private pendingMirrorStart: boolean = false;

  private requestedModeDidChange(): void {
    if (this.activation === 0) return;
    if (this.requestedMode === 'mirror') {
      this.pendingMirrorStart = true;
    } else {
      this.pendingInitialMode = true;
      this.switchAppMode(this.requestedMode, this.showPad);
    }
  }

  @State host: string = '';
  @State room: string = '';
  @State connectionMode: string = 'wifi';
  @State connectionPreference: string = 'automatic';
  @State appMode: string = 'pdf';
  @State showPad: boolean = false;
  @State connected: boolean = false;
  @State documentName: string = '等待 Mac 打开 PDF';
  @State zoomPercent: number = 100;
  @State color: string = '#152441';
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
  @State reduceMotion: boolean = false;
  @State screenMirroring: boolean = false;
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
      this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
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
      this.pendingMirrorStart = this.requestedMode === 'mirror';
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

  @Builder themeControl() {
    Button(this.themePreference === 'automatic' ? '◐  跟随系统' : this.darkMode ? '☾  深色' : '☼  浅色')
      .fontSize(12).height(34).fontColor(this.darkMode ? '#C8D5E8' : '#526781')
      .backgroundColor(this.darkMode ? '#223149' : '#E8EDF5').borderRadius(17)
      .accessibilityText('切换外观，两端同步')
      .bindMenu([
        { value: '跟随 Mac 系统', action: () => LinkDeskTheme.select('automatic') },
        { value: '浅色', action: () => LinkDeskTheme.select('light') },
        { value: '深色', action: () => LinkDeskTheme.select('dark') }
      ])
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.showPad) {
        Stack() {
          this.PadArea()
          Column() {
            if (this.topBarCollapsed) {
              this.CollapsedHeaderButton()
            } else {
              this.HeaderRow()
            }
            Blank(1)
            this.ToolbarRow()
          }
          .width('100%').height('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: 12,
            right: 12,
            top: this.topSafeInset() + 6,
            bottom: this.bottomSafeInset() + 6
          })
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%').height('100%')
        .backgroundColor('#0b1420')
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
    .backgroundColor(this.darkMode ? '#0E1523' : '#F4F6FA')
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ==================== 连接面板 ====================
  @Builder ConnectionPanel() {
    Column({ space: 18 }) {
      this.themeControl()
      Button('‹  工作台').onClick(() => this.onExit()).fontSize(13).backgroundColor(this.chromeColor('#E8EDF5')).fontColor(this.chromeColor('#263B5B'))
      Column() {
        Text('LinkDesk').fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.chromeColor('#152441'))
        Text(this.requestedMode === 'mirror' ? '连接 Mac，开始平板投屏' : 'PDF 批注 · 无限白板 · 双端同步').fontSize(14).fontColor(this.chromeColor('#728096')).margin({ top: 4 })
        Text('触控笔悬停定位 · 压感书写 · 实时同步').fontSize(12).fontColor(this.chromeColor('#a0aec0')).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center).margin({ top: 80 })

      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Button('自动')
            .layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.connectionPreference === 'automatic' ? '#4F8FF7' : this.chromeColor('#e8edf5'))
            .fontColor(this.connectionPreference === 'automatic' ? Color.White : this.chromeColor('#526078'))
            .borderRadius(10)
            .onClick(() => {
              this.connectionPreference = 'automatic';
              this.scheduleReconnect(0);
            })
          Button('Wi-Fi')
            .layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.connectionPreference === 'wifi' ? '#4F8FF7' : this.chromeColor('#e8edf5'))
            .fontColor(this.connectionPreference === 'wifi' ? Color.White : this.chromeColor('#526078'))
            .borderRadius(10)
            .onClick(() => {
              this.connectionMode = 'wifi';
              this.connectionPreference = 'wifi';
            })
          Button('USB')
            .layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.connectionPreference === 'usb' ? '#4F8FF7' : this.chromeColor('#e8edf5'))
            .fontColor(this.connectionPreference === 'usb' ? Color.White : this.chromeColor('#526078'))
            .borderRadius(10)
            .onClick(() => {
              this.connectionMode = 'usb';
              this.connectionPreference = 'usb';
            })
        }.width('100%')

        if (this.connectionMode === 'wifi') {
          TextInput({ text: this.host, placeholder: '自动发现 Mac（也可手动输入 IP）' })
            .width('100%').height(48).backgroundColor(this.chromeColor('#ffffff')).borderRadius(12)
            .fontSize(15).padding({ left: 16, right: 16 })
            .border({ width: 1, color: this.chromeColor('#dfe5ef') })
            .onChange((value: string) => this.host = value.trim())
        } else {
          Column({ space: 3 }) {
            Text('USB 超低延时连接').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#152441'))
            Text('保持数据线连接，Mac 会自动建立有线通道').fontSize(11).fontColor(this.chromeColor('#728096'))
          }
          .width('100%').height(48).justifyContent(FlexAlign.Center)
          .backgroundColor(this.chromeColor('#ffffff')).borderRadius(12)
          .border({ width: 1, color: this.chromeColor('#dfe5ef') })
        }

        TextInput({ text: this.room, placeholder: '6 位房间号' })
          .width('100%').height(48).backgroundColor(this.chromeColor('#ffffff')).borderRadius(12)
          .fontSize(18).padding({ left: 16, right: 16 })
          .letterSpacing(4).maxLength(6)
          .border({ width: 1, color: this.chromeColor('#dfe5ef') })
          .onChange((value: string) => {
            this.room = value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
          })

        Button('扫描 Mac 二维码')
          .width('100%').height(44)
          .fontSize(15).fontWeight(FontWeight.Medium)
          .backgroundColor(this.chromeColor('#e8edf5')).fontColor(this.chromeColor('#263b5b'))
          .border({ width: 1, color: this.chromeColor('#d7dfeb') })
          .borderRadius(12)
          .onClick(() => this.startNativePairingScan())

        Button(this.connectionPreference === 'automatic'
          ? '自动连接 Mac'
          : (this.connectionMode === 'usb' ? '通过 USB 连接 Mac' : '通过 Wi-Fi 连接 Mac'))
          .width('100%').height(48)
          .fontSize(16).fontWeight(FontWeight.Bold)
          .backgroundColor(this.darkMode ? '#326ED6' : '#152441').fontColor(Color.White)
          .borderRadius(12)
          .onClick(() => this.connectToPad())
      }
      .width('100%').constraintSize({ maxWidth: 360 }).margin({ top: 12 })

      Column({ space: 4 }) {
        Text(this.connectionPreference === 'automatic'
          ? '优先 USB，无数据线时自动发现同 Wi-Fi 下的 Mac'
          : (this.connectionMode === 'usb' ? 'USB 模式不使用 Wi-Fi，保持数据线连接即可' : '确保平板与 Mac 处于同一 Wi-Fi 网络'))
          .fontSize(12).fontColor(this.chromeColor('#8993a3'))
        Text('Mac 端需先启动LinkDesk服务并打开 PDF').fontSize(12).fontColor(this.chromeColor('#8993a3'))
        Text(`版本 ${INKBRIDGE_APP_VERSION} · 协议 v${INKBRIDGE_PROTOCOL_VERSION}`)
          .fontSize(10).fontColor(this.chromeColor('#a0a8b5'))
      }.alignItems(HorizontalAlign.Center)

      Blank(1)
    }
    .width('100%').layoutWeight(1)
    .padding({ left: 24, right: 24 })
    .backgroundColor(this.chromeColor('#f4f6fa'))
  }

  // ==================== 顶部状态栏 ====================
  @Builder HeaderRow() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.documentName)
        .fontSize(12).fontColor(this.chromeColor('#b8c5d6'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.headerTitleWidth())
        .textAlign(TextAlign.Center)
        .accessibilityText(`当前文件 ${this.documentName}`)

      Row() {
        Row({ space: 6 }) {
          Row({ space: 6 }) {
            Stack() {
              Text('L').fontSize(12).fontWeight(FontWeight.Bold).fontColor(Color.White)
            }
            .width(28).height(28)
            .borderRadius(9)
            .linearGradient({
              angle: 145,
              colors: [['#4f8ff7', 0], ['#58d3b7', 1]]
            })
            .shadow({ radius: 12, color: this.glassColor('rgba(42, 112, 219, 0.34)'), offsetX: 0, offsetY: 5 })
            if (this.padAreaWidth >= 900) {
              Text('LinkDesk').fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.chromeColor('#f4f8ff'))
              Text(this.connectionMode === 'usb' ? 'USB' : 'Wi-Fi')
                .fontSize(10).fontWeight(FontWeight.Medium)
                .fontColor(this.connectionMode === 'usb' ? this.chromeColor('#9be5d2') : this.chromeColor('#d4e1f2'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(this.connectionMode === 'usb'
                  ? this.glassColor('rgba(45, 187, 149, 0.18)')
                  : this.glassColor('rgba(255, 255, 255, 0.10)'))
                .borderRadius(7)
            }
          }
          .onClick(() => this.onExit())
          .hitTestBehavior(HitTestMode.Block)

          Row({ space: 3 }) {
            Button() {
              Stack({ alignContent: Alignment.Center }) {
                Text('PDF').fontSize(11)
                  .fontColor(this.appMode === 'pdf' ? (this.darkMode ? Color.White : '#152441') : this.chromeColor('#aebdd0'))
              }
            }
              .width(50).height(30).padding(0)
              .backgroundColor(this.appMode === 'pdf' ? this.glassColor('rgba(255, 255, 255, 0.18)') : Color.Transparent)
              .fontColor(this.appMode === 'pdf' ? (this.darkMode ? Color.White : '#152441') : this.chromeColor('#aebdd0'))
              .borderRadius(8)
              .onClick(() => this.switchAppMode('pdf', true))
            Button() {
              Stack({ alignContent: Alignment.Center }) {
                Text('白板').fontSize(11)
                  .fontColor(this.appMode === 'whiteboard' ? (this.darkMode ? Color.White : '#152441') : this.chromeColor('#aebdd0'))
              }
            }
              .width(50).height(30).padding(0)
              .backgroundColor(this.appMode === 'whiteboard' ? this.glassColor('rgba(255, 255, 255, 0.18)') : Color.Transparent)
              .fontColor(this.appMode === 'whiteboard' ? (this.darkMode ? Color.White : '#152441') : this.chromeColor('#aebdd0'))
              .borderRadius(8)
              .onClick(() => this.switchAppMode('whiteboard', true))
          }
          .padding(3)
          .backgroundColor(this.glassColor('rgba(0, 0, 0, 0.16)'))
          .borderRadius(11)
        }
        .onAreaChange((_, area) => {
          this.headerLeftWidth = Math.max(0, area.width as number);
        })

        Blank(1)

        Row({ space: 6 }) {
          if (this.padAreaWidth >= 720) {
            Text(this.room)
              .fontSize(9).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#aab9cc'))
              .maxLines(1)
          }
          Row({ space: 5 }) {
            Circle()
              .width(7).height(7)
              .fill(this.connected ? '#58d3b7' : this.chromeColor('#f0b74d'))
            if (this.padAreaWidth >= 620) {
              Text(this.connected ? '已连接' : '等待连接')
                .fontSize(11).fontWeight(FontWeight.Medium)
                .fontColor(this.connected ? this.chromeColor('#9be5d2') : this.chromeColor('#d4bd8a'))
            }
          }
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(this.connected ? this.glassColor('rgba(45, 187, 149, 0.13)') : this.glassColor('rgba(240, 183, 77, 0.12)'))
          .borderRadius(12)

          if (this.roundTripId.length > 0) {
            Button('回传批注')
              .height(30).padding({ left: 10, right: 10 })
              .fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(this.chromeColor('#d7e9ff'))
              .backgroundColor(this.glassColor('rgba(88, 211, 183, 0.17)'))
              .borderRadius(9)
              .accessibilityText('选择已批注 PDF 并回传到 Mac')
              .onClick(() => this.selectRoundTripReturnPDF())
          }

          this.themeControl()
          Button(this.screenMirroring ? '停止投屏' : '投屏')
            .height(30).padding({ left: 10, right: 10 })
            .fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor(this.screenMirroring ? this.chromeColor('#ffbbb4') : this.chromeColor('#d7e9ff'))
            .backgroundColor(this.screenMirroring
              ? this.glassColor('rgba(221, 82, 72, 0.18)')
              : this.glassColor('rgba(79, 143, 247, 0.16)'))
            .borderRadius(9)
            .accessibilityText(this.screenMirroring ? '停止投屏到 Mac' : '通过 USB 投屏到 Mac')
            .onClick(() => this.toggleScreenMirror())

          Button('⌃')
            .width(30).height(30).padding(0).fontSize(14)
            .fontColor(this.chromeColor('#d7e9ff'))
            .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)'))
            .borderRadius(9)
            .accessibilityText('收起顶部菜单')
            .onClick(() => this.setTopBarCollapsed(true))
        }
        .onAreaChange((_, area) => {
          this.headerRightWidth = Math.max(0, area.width as number);
        })
      }
      .width('100%')
    }
    .width('100%').height(46)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.glassColor('rgba(12, 24, 38, 0.20)'))
    .backgroundEffect({
      radius: 24,
      saturation: 1.15,
      brightness: this.darkMode ? 0.88 : 1.06,
      color: this.glassColor('rgba(12, 24, 38, 0.18)')
    })
    .linearGradient({
      angle: 125,
      colors: [
        [this.glassColor('rgba(76, 130, 181, 0.20)'), 0],
        [this.glassColor('rgba(12, 24, 38, 0.24)'), 0.48],
        [this.glassColor('rgba(38, 116, 127, 0.17)'), 1]
      ]
    })
    .border({ width: 1, color: this.glassColor('rgba(210, 232, 255, 0.40)') })
    .borderRadius(18)
    .clip(true)
    .shadow({ radius: 18, color: this.glassColor('rgba(0, 0, 0, 0.26)'), offsetX: 0, offsetY: 7 })
    .geometryTransition('inkbridge-topbar-roll')
    .onAreaChange((_, area) => {
      this.headerWidth = Math.max(1, area.width as number);
    })
  }

  @Builder CollapsedHeaderButton() {
    Button() {
      Stack({ alignContent: Alignment.Center }) {
        Text('L').fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.chromeColor('#f4f8ff'))
        Circle()
          .width(6).height(6)
          .fill(this.connected ? '#58d3b7' : this.chromeColor('#f0b74d'))
          .position({ x: 37, y: 7 })
        Text('⌄').fontSize(10).fontColor(this.chromeColor('#d7e9ff'))
          .position({ x: 32, y: 29 })
      }
    }
    .width(48).height(48).padding(0)
    .backgroundColor(this.glassColor('rgba(12, 24, 38, 0.20)'))
    .backgroundEffect({
      radius: 24,
      saturation: 1.15,
      brightness: this.darkMode ? 0.88 : 1.06,
      color: this.glassColor('rgba(12, 24, 38, 0.18)')
    })
    .linearGradient({
      angle: 145,
      colors: [
        [this.glassColor('rgba(79, 143, 247, 0.42)'), 0],
        [this.glassColor('rgba(88, 211, 183, 0.22)'), 1]
      ]
    })
    .border({ width: 1, color: this.glassColor('rgba(210, 232, 255, 0.40)') })
    .borderRadius(24)
    .clip(true)
    .shadow({ radius: 18, color: this.glassColor('rgba(0, 0, 0, 0.26)'), offsetX: 0, offsetY: 7 })
    .geometryTransition('inkbridge-topbar-roll')
    .accessibilityText('展开顶部菜单')
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
    Row() {
      Blank(1)
      Row({ space: 5 }) {
        Button() {
          Text('✎').fontSize(17).fontColor(!this.eraser && !this.highlighter ? this.chromeColor('#d7e9ff') : this.chromeColor('#c3cede'))
        }
        .width(38).height(36).padding(0)
        .backgroundColor(!this.eraser && !this.highlighter ? this.glassColor('rgba(75, 138, 232, 0.30)') : this.glassColor('rgba(255, 255, 255, 0.055)'))
        .fontColor(!this.eraser && !this.highlighter ? this.chromeColor('#d7e9ff') : this.chromeColor('#c3cede'))
        .border({ width: 1, color: !this.eraser && !this.highlighter ? this.glassColor('rgba(130, 177, 246, 0.20)') : Color.Transparent })
        .borderRadius(10)
        .accessibilityText('画笔')
        .onClick(() => this.selectPenTool())

        Button() {
          this.HighlighterGlyph(this.highlighter)
        }
        .width(38).height(36).padding(0)
        .backgroundColor(this.highlighter ? this.glassColor('rgba(237, 205, 70, 0.24)') : this.glassColor('rgba(255, 255, 255, 0.055)'))
        .border({ width: 1, color: this.highlighter ? this.glassColor('rgba(255, 231, 116, 0.34)') : Color.Transparent })
        .borderRadius(10)
        .accessibilityText('荧光笔')
        .onClick(() => this.selectHighlighterTool())

        Button() {
          this.EraserGlyph(this.eraser)
        }
        .width(38).height(36).padding(0)
        .backgroundColor(this.eraser ? this.glassColor('rgba(75, 138, 232, 0.30)') : this.glassColor('rgba(255, 255, 255, 0.055)'))
        .fontColor(this.eraser ? this.chromeColor('#d7e9ff') : this.chromeColor('#c3cede'))
        .border({ width: 1, color: this.eraser ? this.glassColor('rgba(130, 177, 246, 0.20)') : Color.Transparent })
        .borderRadius(10)
        .accessibilityText('橡皮擦')
        .onClick(() => this.selectEraserTool())

        this.ToolDivider()
        Button('↶')
          .width(36).height(36).padding(0).fontSize(16)
          .enabled(this.canUndo)
          .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)')).fontColor(this.canUndo ? this.chromeColor('#c3cede') : this.chromeColor('#748195'))
          .borderRadius(10).accessibilityText('撤销').onClick(() => this.runJS('nativeUndo()'))
        Button('↷')
          .width(36).height(36).padding(0).fontSize(16)
          .enabled(this.canRedo)
          .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)')).fontColor(this.canRedo ? this.chromeColor('#c3cede') : this.chromeColor('#748195'))
          .borderRadius(10).accessibilityText('重做').onClick(() => this.runJS('nativeRedo()'))

        if (this.appMode === 'pdf') {
          this.ToolDivider()
          Button('−')
            .width(34).height(36).padding(0).fontSize(16)
            .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)')).fontColor(this.chromeColor('#c3cede')).borderRadius(10)
            .onClick(() => this.runJS('nativeZoomOut()'))
          Text(`${Math.round(this.zoomPercent)}%`)
            .fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#d2dbe8'))
            .width(42).textAlign(TextAlign.Center)
          Button('+')
            .width(34).height(36).padding(0).fontSize(16)
            .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)')).fontColor(this.chromeColor('#c3cede')).borderRadius(10)
            .onClick(() => this.runJS('nativeZoomIn()'))
        }

        this.ToolDivider()

        Button('⌫')
          .width(38).height(36).padding(0).fontSize(17).fontWeight(FontWeight.Medium)
          .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)')).fontColor(this.chromeColor('#ffaaa6'))
          .borderRadius(10)
          .accessibilityText(this.appMode === 'pdf' ? '清空批注' : '清空白板')
          .onClick(() => this.confirmClear())
      }
      .padding({ left: 7, right: 7, top: 5, bottom: 5 })
      .backgroundColor(this.glassColor('rgba(12, 24, 38, 0.20)'))
      .backgroundEffect({
        radius: 24,
        saturation: 1.15,
        brightness: this.darkMode ? 0.88 : 1.06,
        color: this.glassColor('rgba(12, 24, 38, 0.18)')
      })
      .linearGradient({
        angle: 125,
        colors: [
          [this.glassColor('rgba(76, 130, 181, 0.20)'), 0],
          [this.glassColor('rgba(12, 24, 38, 0.24)'), 0.48],
          [this.glassColor('rgba(38, 116, 127, 0.17)'), 1]
        ]
      })
      .border({ width: 1, color: this.glassColor('rgba(210, 232, 255, 0.40)') })
      .borderRadius(18)
      .shadow({ radius: 18, color: this.glassColor('rgba(0, 0, 0, 0.28)'), offsetX: 0, offsetY: 8 })
      Blank(1)
    }
    .width('100%').height(50)
  }

  // ==================== 工具栏辅助组件 ====================
  @Builder PenToolMenu() {
    Column({ space: 13 }) {
      Row() {
        Text('画笔粗细').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.chromeColor('#eef5ff'))
        Blank(1)
        Text('4 档').fontSize(10).fontColor(this.chromeColor('#aebdd0'))
      }.width('100%')
      Row({ space: 8 }) {
        this.PenLevelButton(1.2, '1', 1)
        this.PenLevelButton(2.2, '2', 2)
        this.PenLevelButton(3.5, '3', 4)
        this.PenLevelButton(5.5, '4', 7)
      }
      Divider().color(this.glassColor('rgba(255, 255, 255, 0.12)'))
      Row() {
        Text('画笔颜色').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#bdcadb'))
        Blank(1)
        Row({ space: 7 }) {
          this.ColorSwatch('#152441')
          this.ColorSwatch('#2269ef')
          this.ColorSwatch('#e45a4f')
          this.ColorSwatch('#1b9a7e')
        }
      }.width('100%')
    }
    .width(360)
    .padding({ left: 16, right: 16, top: 15, bottom: 14 })
    .margin({ bottom: this.bottomSafeInset() + 60 })
    .backgroundColor(this.glassColor('rgba(12, 26, 40, 0.38)'))
    .backgroundEffect({
      radius: 28,
      saturation: 1.15,
      brightness: this.darkMode ? 0.88 : 1.06,
      color: this.glassColor('rgba(12, 26, 40, 0.20)')
    })
    .linearGradient({
      angle: 135,
      colors: [
        [this.glassColor('rgba(67, 116, 163, 0.38)'), 0],
        [this.glassColor('rgba(12, 26, 40, 0.44)'), 0.62],
        [this.glassColor('rgba(36, 104, 113, 0.32)'), 1]
      ]
    })
    .border({ width: 1, color: this.glassColor('rgba(169, 210, 255, 0.24)') })
    .borderRadius(18)
    .shadow({ radius: 28, color: this.glassColor('rgba(0, 0, 0, 0.38)'), offsetX: 0, offsetY: 12 })
    .transition(this.toolMenuTransition())
    .zIndex(20)
  }

  @Builder EraserToolMenu() {
    Column({ space: 13 }) {
      Row() {
        Row({ space: 9 }) {
          this.EraserGlyph(true)
          Text('橡皮设置').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.chromeColor('#eef5ff'))
        }
        Blank(1)
        Text('独立二级菜单').fontSize(10).fontColor(this.chromeColor('#aebdd0'))
      }.width('100%')
      Row({ space: 12 }) {
        Stack() {
          Circle().width(48).height(48)
            .fill(this.glassColor('rgba(255, 255, 255, 0.06)')).stroke(this.chromeColor('#a8b5c8')).strokeWidth(1.5)
          Text(`${Math.round(this.eraserSize)} px`).fontSize(9).fontWeight(FontWeight.Medium)
            .fontColor(this.chromeColor('#c5d0df'))
        }
        Column({ space: 3 }) {
          Text('当前擦除范围').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#eef5ff'))
          Text('擦除时显示灰色范围圆环').fontSize(10).fontColor(this.chromeColor('#aebdd0'))
        }.alignItems(HorizontalAlign.Start)
      }
      .width('100%').padding(10).backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)')).borderRadius(12)
      Row({ space: 8 }) {
        this.EraserLevelButton(24, '1', 14)
        this.EraserLevelButton(40, '2', 20)
        this.EraserLevelButton(64, '3', 27)
        this.EraserLevelButton(96, '4', 34)
      }
      Row() {
        Button(this.pressureEraserEnabled ? '重按临时擦除 开' : '重按临时擦除 关')
          .height(30).fontSize(10).padding({ left: 10, right: 10 })
          .backgroundColor(this.pressureEraserEnabled
            ? this.glassColor('rgba(45, 187, 149, 0.16)')
            : this.glassColor('rgba(255, 255, 255, 0.055)'))
          .fontColor(this.pressureEraserEnabled ? this.chromeColor('#9be5d2') : this.chromeColor('#aebdd0'))
          .border({
            width: 1,
            color: this.pressureEraserEnabled
              ? this.glassColor('rgba(102, 215, 186, 0.34)')
              : this.glassColor('rgba(255, 255, 255, 0.12)')
          })
          .borderRadius(8).onClick(() => this.togglePressureEraser())
        Blank(1)
        Button(`灵敏度 ${this.pressureSensitivityLabel()}`)
          .height(30).fontSize(10).padding({ left: 10, right: 10 })
          .enabled(this.pressureEraserEnabled)
          .backgroundColor(this.glassColor('rgba(255, 255, 255, 0.055)'))
          .fontColor(this.pressureEraserEnabled ? this.chromeColor('#c3cede') : this.chromeColor('#748195'))
          .border({ width: 1, color: this.glassColor('rgba(255, 255, 255, 0.12)') })
          .borderRadius(8).onClick(() => this.cyclePressureSensitivity())
      }.width('100%')
    }
    .width(380)
    .padding({ left: 16, right: 16, top: 15, bottom: 14 })
    .margin({ bottom: this.bottomSafeInset() + 60 })
    .backgroundColor(this.glassColor('rgba(12, 26, 40, 0.38)'))
    .backgroundEffect({
      radius: 28,
      saturation: 1.15,
      brightness: this.darkMode ? 0.88 : 1.06,
      color: this.glassColor('rgba(12, 26, 40, 0.20)')
    })
    .linearGradient({
      angle: 135,
      colors: [
        [this.glassColor('rgba(67, 116, 163, 0.38)'), 0],
        [this.glassColor('rgba(12, 26, 40, 0.44)'), 0.62],
        [this.glassColor('rgba(36, 104, 113, 0.32)'), 1]
      ]
    })
    .border({ width: 1, color: this.glassColor('rgba(169, 210, 255, 0.24)') })
    .borderRadius(18)
    .shadow({ radius: 28, color: this.glassColor('rgba(0, 0, 0, 0.38)'), offsetX: 0, offsetY: 12 })
    .transition(this.toolMenuTransition())
    .zIndex(20)
  }

  @Builder HighlighterToolMenu() {
    Column({ space: 13 }) {
      Row() {
        Row({ space: 9 }) {
          this.HighlighterGlyph(true)
          Text('荧光笔').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.chromeColor('#eef5ff'))
        }
        Blank(1)
        Text('停顿 2 秒自动拉直').fontSize(10).fontColor(this.chromeColor('#d9c969'))
      }.width('100%')
      Column({ space: 8 }) {
        Row() {
          Text('粗细').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#bdcadb'))
          Blank(1)
          Text(`${Math.round(this.highlighterWidth)} px`).fontSize(10).fontColor(this.chromeColor('#fff0a2'))
        }.width('100%')
        Row({ space: 8 }) {
          this.HighlighterWidthButton(8, '1', 3)
          this.HighlighterWidthButton(14, '2', 5)
          this.HighlighterWidthButton(22, '3', 8)
          this.HighlighterWidthButton(32, '4', 11)
        }
      }
      Divider().color(this.glassColor('rgba(255, 255, 255, 0.12)'))
      Column({ space: 8 }) {
        Row() {
          Text('不透明度').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.chromeColor('#bdcadb'))
          Blank(1)
          Text(`${Math.round(this.highlighterOpacity * 100)}%`).fontSize(10).fontColor(this.chromeColor('#fff0a2'))
        }.width('100%')
        Row({ space: 8 }) {
          this.HighlighterOpacityButton(0.18, '18%')
          this.HighlighterOpacityButton(0.28, '28%')
          this.HighlighterOpacityButton(0.40, '40%')
          this.HighlighterOpacityButton(0.55, '55%')
        }
      }
    }
    .width(390)
    .padding({ left: 16, right: 16, top: 15, bottom: 14 })
    .margin({ bottom: this.bottomSafeInset() + 60 })
    .backgroundColor(this.glassColor('rgba(12, 26, 40, 0.38)'))
    .backgroundEffect({
      radius: 28,
      saturation: 1.15,
      brightness: this.darkMode ? 0.90 : 1.06,
      color: this.glassColor('rgba(12, 26, 40, 0.20)')
    })
    .linearGradient({
      angle: 135,
      colors: [
        [this.glassColor('rgba(151, 130, 50, 0.28)'), 0],
        [this.glassColor('rgba(12, 26, 40, 0.44)'), 0.62],
        [this.glassColor('rgba(36, 104, 113, 0.28)'), 1]
      ]
    })
    .border({ width: 1, color: this.glassColor('rgba(255, 230, 116, 0.28)') })
    .borderRadius(18)
    .shadow({ radius: 28, color: this.glassColor('rgba(0, 0, 0, 0.38)'), offsetX: 0, offsetY: 12 })
    .transition(this.toolMenuTransition())
    .zIndex(20)
  }

  @Builder EraserGlyph(active: boolean) {
    Row() {
      Rect().width(9).height(12).fill(active ? this.chromeColor('#87b8ff') : this.chromeColor('#aab7c9'))
      Rect().width(9).height(12).fill(this.glassColor('rgba(244, 248, 255, 0.92)'))
    }
    .width(20).height(14)
    .border({ width: 1.5, color: active ? this.chromeColor('#9bc5ff') : this.chromeColor('#b6c2d2') })
    .borderRadius(3)
    .rotate({ angle: -32 })
  }

  @Builder HighlighterGlyph(active: boolean) {
    Stack() {
      Rect().width(10).height(18)
        .fill(active ? '#ffe56f' : this.chromeColor('#c8c28f'))
        .borderRadius({ topLeft: 2, topRight: 2, bottomLeft: 1, bottomRight: 1 })
      Rect().width(14).height(5)
        .fill(active ? this.glassColor('rgba(255, 235, 122, 0.94)') : this.glassColor('rgba(221, 219, 185, 0.86)'))
        .margin({ top: 17 })
        .borderRadius(2)
    }
    .width(22).height(24)
    .rotate({ angle: -28 })
  }

  @Builder HighlighterWidthButton(widthValue: number, label: string, sampleWidth: number) {
    Button() {
      Column({ space: 5 }) {
        Divider().width(38).strokeWidth(sampleWidth).color('#ffe56f')
        Text(label).fontSize(10).fontWeight(FontWeight.Medium)
      }
    }
    .width(81).height(58).padding(0)
    .backgroundColor(this.highlighterWidth === widthValue
      ? this.glassColor('rgba(237, 205, 70, 0.22)')
      : this.glassColor('rgba(255, 255, 255, 0.045)'))
    .fontColor(this.highlighterWidth === widthValue ? this.chromeColor('#fff0a2') : this.chromeColor('#bdcadb'))
    .border({
      width: 1,
      color: this.highlighterWidth === widthValue
        ? this.glassColor('rgba(255, 231, 116, 0.34)')
        : this.glassColor('rgba(255, 255, 255, 0.08)')
    })
    .borderRadius(10)
    .onClick(() => this.setHighlighterWidth(widthValue))
  }

  @Builder HighlighterOpacityButton(opacityValue: number, label: string) {
    Button() {
      Column({ space: 5 }) {
        Rect().width(40).height(12).fill(`rgba(255, 229, 91, ${opacityValue})`).borderRadius(4)
        Text(label).fontSize(10).fontWeight(FontWeight.Medium)
      }
    }
    .width(81).height(52).padding(0)
    .backgroundColor(Math.abs(this.highlighterOpacity - opacityValue) < 0.001
      ? this.glassColor('rgba(237, 205, 70, 0.22)')
      : this.glassColor('rgba(255, 255, 255, 0.045)'))
    .fontColor(Math.abs(this.highlighterOpacity - opacityValue) < 0.001 ? this.chromeColor('#fff0a2') : this.chromeColor('#bdcadb'))
    .border({
      width: 1,
      color: Math.abs(this.highlighterOpacity - opacityValue) < 0.001
        ? this.glassColor('rgba(255, 231, 116, 0.34)')
        : this.glassColor('rgba(255, 255, 255, 0.08)')
    })
    .borderRadius(10)
    .onClick(() => this.setHighlighterOpacity(opacityValue))
  }

  @Builder ColorSwatch(colorValue: string) {
    Button() {
      Circle().width(20).height(20).fill(colorValue)
    }
    .width(28).height(28)
    .border({
      width: this.color === colorValue ? 2 : 1,
      color: this.color === colorValue ? this.chromeColor('#d7e9ff') : this.glassColor('rgba(255, 255, 255, 0.22)')
    })
    .backgroundColor(this.color === colorValue
      ? this.glassColor('rgba(130, 177, 246, 0.18)')
      : this.glassColor('rgba(255, 255, 255, 0.055)'))
    .borderRadius(14)
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
      Column({ space: 5 }) {
        Divider().width(38).strokeWidth(sampleWidth)
          .color(this.penWidthLevel() === widthValue ? this.chromeColor('#9bc5ff') : this.chromeColor('#bdcadb'))
        Text(label).fontSize(10).fontWeight(FontWeight.Medium)
      }
    }
      .width(76).height(58)
      .backgroundColor(this.penWidthLevel() === widthValue
        ? this.glassColor('rgba(75, 138, 232, 0.28)')
        : this.glassColor('rgba(255, 255, 255, 0.055)'))
      .fontColor(this.penWidthLevel() === widthValue ? this.chromeColor('#d7e9ff') : this.chromeColor('#bdcadb'))
      .border({
        width: 1,
        color: this.penWidthLevel() === widthValue
          ? this.glassColor('rgba(130, 177, 246, 0.28)')
          : this.glassColor('rgba(255, 255, 255, 0.10)')
      })
      .borderRadius(10).padding(0)
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
      Column({ space: 4 }) {
        Circle().width(previewSize).height(previewSize)
          .fill(this.eraserSizeLevel() === sizeValue
            ? this.glassColor('rgba(75, 138, 232, 0.22)')
            : this.glassColor('rgba(255, 255, 255, 0.045)'))
          .stroke(this.eraserSizeLevel() === sizeValue ? this.chromeColor('#9bc5ff') : this.chromeColor('#aab7c9')).strokeWidth(1.5)
        Text(label).fontSize(10).fontWeight(FontWeight.Medium)
      }
    }
    .width(81).height(62).padding(0)
    .backgroundColor(this.eraserSizeLevel() === sizeValue
      ? this.glassColor('rgba(75, 138, 232, 0.26)')
      : this.glassColor('rgba(255, 255, 255, 0.045)'))
    .fontColor(this.eraserSizeLevel() === sizeValue ? this.chromeColor('#d7e9ff') : this.chromeColor('#bdcadb'))
    .border({
      width: 1,
      color: this.eraserSizeLevel() === sizeValue
        ? this.glassColor('rgba(130, 177, 246, 0.26)')
        : this.glassColor('rgba(255, 255, 255, 0.08)')
    })
    .borderRadius(10)
    .onClick(() => this.setEraserSize(sizeValue))
  }

  @Builder ToolDivider() {
    Divider()
      .vertical(true)
      .height(18).color(this.glassColor('rgba(255, 255, 255, 0.12)'))
      .margin({ left: 2, right: 2 })
  }

  private applyWebTheme(): void {
    this.runJS(`document.documentElement.dataset.linkdeskTheme='${this.darkMode ? 'dark' : 'light'}'`);
  }
  private chromeColor(color: string): string {
    const c = color.toLowerCase();
    if (this.darkMode) {
      if (c === '#f4f6fa') return '#0E1523';
      if (c === '#ffffff') return '#182337';
      if (c === '#152441') return '#E8EEF8';
      if (c === '#e8edf5') return '#223149';
      if (c === '#dfe5ef' || c === '#d7dfeb') return '#2B3B55';
      if (c === '#526078' || c === '#263b5b') return '#A5B4CA';
      return color;
    }
    if (c === '#f4f8ff' || c === '#d7e9ff' || c === '#c3cede' || c === '#d2dbe8') return '#152441';
    if (c === '#b8c5d6' || c === '#aebdd0' || c === '#aab9cc' || c === '#bdcadb' || c === '#b7c6d8' || c === '#d4e1f2') return '#526781';
    if (c === '#9be5d2') return '#1B806B';
    if (c === '#d4bd8a') return '#94670D';
    if (c === '#ffbbb4' || c === '#ffaaa6') return '#B83D44';
    if (c === '#fff0a2') return '#8A6600';
    if (c === '#0b1420') return '#EDF2F8';
    return color;
  }
  private glassColor(color: string): string {
    if (this.darkMode) return color;
    if (color.startsWith('rgba(12,') || color.startsWith('rgba(10,') || color.startsWith('rgba(14,')) return 'rgba(248, 251, 255, 0.82)';
    if (color.startsWith('rgba(0,')) return 'rgba(20, 40, 70, 0.10)';
    if (color.startsWith('rgba(255, 255, 255,')) return 'rgba(35, 65, 105, 0.06)';
    return color;
  }

  private headerTitleWidth(): number {
    const reservedSide = Math.max(this.headerLeftWidth, this.headerRightWidth) + 16;
    return Math.max(0, this.headerWidth - reservedSide * 2);
  }

  private setTopBarCollapsed(collapsed: boolean): void {
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? 0 : 520,
      curve: Curve.EaseInOut
    }, () => {
      this.topBarCollapsed = collapsed;
    });
  }

  private toolMenuTransition(): TransitionEffect {
    if (this.reduceMotion) return TransitionEffect.IDENTITY;
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: 12 }))
      .combine(TransitionEffect.scale({
        x: 0.96,
        y: 0.96,
        centerX: '50%',
        centerY: '100%'
      }))
      .animation({ duration: 240, curve: Curve.EaseOut });
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate({ y: 8 }))
      .combine(TransitionEffect.scale({
        x: 0.98,
        y: 0.98,
        centerX: '50%',
        centerY: '100%'
      }))
      .animation({ duration: 180, curve: Curve.EaseIn });
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
      promptAction.showToast({ message: '请先切换到 USB 连接' });
      this.reportScreenMirrorStatus('failed', requestId, '平板当前不是 USB 连接');
      return;
    }
    const result: number = screenMirror.start('127.0.0.1', 3211) as number;
    if (result === 0) {
      this.screenMirroring = true;
      void this.startMirrorBackgroundTask();
      this.reportScreenMirrorStatus('started', requestId);
      void this.refreshRoundTripLiveView();
      promptAction.showToast({ message: '正在投屏到 Mac' });
    } else {
      const error = `投屏启动失败 (${result})`;
      this.reportScreenMirrorStatus('failed', requestId, error);
      promptAction.showToast({ message: `${error}，请确认 Mac 端LinkDesk已打开` });
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
    promptAction.showToast({ message: '已停止投屏' });
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
      promptAction.showToast({ message: '全局投屏保活失败，请保持LinkDesk在前台' });
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
    this.roundTripStatus = '正在下载到平板…';
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
        if (reason) promptAction.showToast({ message: `${reason}，可返回LinkDesk控制投屏` });
      }
      this.roundTripStatus = '正在用华为笔记打开…';
      try {
        await context.startAbility(huaweiNotesWant);
        this.roundTripStatus = '已在华为笔记打开，批注后请导出并分享到LinkDesk';
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
        this.roundTripStatus = '华为笔记不可用，已交给系统 PDF 应用';
      }
    } catch (error) {
      const failure = error as BusinessError;
      this.roundTripStatus = `打开外部应用失败：${failure.message ?? String(error)}`;
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
        promptAction.showToast({ message: `选择批注文件失败：${failure.message}` });
      }
    }
  }

  private async uploadRoundTripURI(uri: string): Promise<void> {
    if (!uri || !this.roundTripId) {
      promptAction.showToast({ message: '没有等待回传的 PDF 任务' });
      return;
    }
    let file: fileIo.File | undefined = undefined;
    const request = http.createHttp();
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > 250 * 1024 * 1024) throw new Error('文件大小不受支持');
      const buffer = new ArrayBuffer(stat.size);
      const readBytes = fileIo.readSync(file.fd, buffer);
      if (readBytes !== stat.size) throw new Error('文件读取不完整');
      let name = `${this.roundTripName.replace(/\.pdf$/i, '')}_已批注.pdf`;
      try { name = new fileUri.FileUri(uri).name || name; } catch (_) {}
      this.roundTripStatus = '正在回传到 Mac…';
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
      this.roundTripStatus = '已回传到 Mac';
      this.roundTripId = '';
      this.roundTripName = '';
      this.saveRoundTripState();
      await RoundTripLiveViewController.stop();
      promptAction.showToast({ message: '批注版已回传，请在 Mac 选择保存位置' });
    } catch (error) {
      const failure = error as BusinessError;
      this.roundTripStatus = `回传失败：${failure.message ?? String(error)}`;
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
      title: this.appMode === 'pdf' ? '清空批注' : '清空白板',
      message: this.appMode === 'pdf'
        ? '确定要清空全部 PDF 批注吗？清空后仍可撤销。'
        : '确定要清空白板吗？清空后仍可撤销。',
      buttons: [
        { text: '取消', color: '#526079' },
        { text: '确定', color: '#e1534a' }
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
    if (this.pressureSensitivity === 'sensitive') return '高';
    if (this.pressureSensitivity === 'steady') return '低';
    return '中';
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
        promptAction.showToast({ message: '未识别到有效的LinkDesk连接二维码' });
        return;
      }
      this.applyScannedPairingLink(pairing);
    } catch (reason) {
      const error = reason as BusinessError;
      if (error.code !== 1000500002) {
        promptAction.showToast({ message: '无法启动系统扫码服务' });
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

    promptAction.showToast({ message: `已识别房间 ${pairing.room}，正在自动选择 USB / Wi-Fi` });
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
    this.documentName = mode === 'whiteboard' ? '实时白板' : '等待 Mac 打开 PDF';
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
    this.documentName = '等待 Mac 打开 PDF';
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
              this.documentName = (data.documentName as string) || '等待 Mac 打开 PDF';
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
