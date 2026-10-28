import { PlatformUI } from '../design/PlatformUI';
import { PageHeader, EmptyState, SettingRow } from '../design/Components';
import { DT, Strings, ConnectionState, ConnectionPresentation } from '../design/GeneratedDesign';
import { curves } from '@kit.ArkUI';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import linkdesk from 'liblinkdesk.so';
import systemDateTime from '@ohos.systemDateTime';
import { DisplayContext } from '../DisplayContext';
import { CursorOverlay } from './CursorOverlay';

interface ReceiverStats {
  microphoneState: number;
  microphoneRequested: boolean;
  hostRequestState: number;
  audioState: number;
  audioFrames: number;
  state: number;
  frames: number;
  bytes: number;
  error: number;
  width: number;
  height: number;
  targetFPS: number;
  vsyncHz: number;
  screenHz: number;
  latestMode: boolean;
  timedSupported: boolean;
  timedSubmissions: number;
  receiveSubmitUs: number;
  decodeUs: number;
  submitUs: number;
  hdrAvailable: boolean;
  hdrActive: boolean;
}

interface FrameSample {
  timeMs: number;
  frames: number;
}

@Component
export struct DesktopReceiver {
  @StorageLink('LinkDeskKeyboardState') keyboardState: string = 'disconnected';
  @StorageLink('LinkDeskDark') darkMode: boolean = false;
  @StorageLink('LinkDeskThemePreference') themePreference: string = 'automatic';
  onExit: () => void = () => {};
  @State private microphoneAllowed: boolean = false;
  @State private microphoneState: number = 0;
  @State private microphoneMessage: string = Strings.microphoneOff;
  private surface: XComponentController = new XComponentController();
  private timer: number = -1;
  @State private state: number = 1;
  @State private hostRequestState: number = 0;
  private frameSamples: FrameSample[] = [];
  @State private realtimeFPS: number = 0;
  @State private error: number = 0;
  @State private streamWidth: number = 2880;
  @State private streamHeight: number = 1920;
  @State private targetFPS: number = 60;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @State private controlsVisible: boolean = true;
  @State private panelRight: number = 16;
  @State private panelTop: number = 16;
  @State private viewportWidth: number = 960;
  @State private viewportHeight: number = 640;
  private dragRight: number = 16;
  private dragTop: number = 16;
  private active: boolean = false;
  @State private microphonePending: boolean = false;
  @State private screenHz: number = 0;
  @State private latestMode: boolean = true;
  @State private timedSupported: boolean = true;
  @State private audioState: number = 0;
  @State private processMs: number = 0;
  @State private displayWidth: number = 960;
  @State private displayHeight: number = 640;
  @State private hdrActive: boolean = false;

  private updateFPS(info: ReceiverStats): void {
    const now = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    if (info.state !== 3) {
      this.frameSamples = [];
      this.realtimeFPS = 0;
      return;
    }
    if (this.frameSamples.length > 0) {
      const last = this.frameSamples[this.frameSamples.length - 1];
      if (info.frames < last.frames || now <= last.timeMs || now - last.timeMs > 2000) {
        this.frameSamples = [];
      }
    }
    this.frameSamples.push({ timeMs: now, frames: info.frames });
    if (this.frameSamples.length > 3) this.frameSamples.shift();
    const first = this.frameSamples[0];
    const elapsed = now - first.timeMs;
    this.realtimeFPS = elapsed > 0 ? Math.max(0, (info.frames - first.frames) * 1000 / elapsed) : 0;
  }

  private connect(): void {
    // Reset stale status immediately; keep the panel available while reconnecting.
    this.state = 1;
    this.error = 0;
    this.hostRequestState = 0;
    this.frameSamples = [];
    this.realtimeFPS = 0;
    this.screenHz = 0;
    AppStorage.setOrCreate('LinkDeskReceiverWorking', false);
    PlatformUI.setReceiver(false);
    linkdesk.setLatestMode(this.latestMode);
    linkdesk.start(this.surface.getXComponentSurfaceId(), DisplayContext.windowId);
    if (this.microphoneAllowed) { linkdesk.setMicrophoneRequested(true); linkdesk.setMicrophoneEnabled(true); }
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = setInterval(() => {
      const info = JSON.parse(linkdesk.stats()) as ReceiverStats;
      this.state = info.state;
      AppStorage.setOrCreate('LinkDeskReceiverWorking', info.state === 3);
      PlatformUI.setReceiver(info.state === 3);
      this.hostRequestState = info.hostRequestState;
      this.audioState = info.audioState;
      this.screenHz = info.screenHz;
      this.microphoneState = info.microphoneState;
      // One shared intent, with tablet OS permission resolved only in foreground.
      if (!this.microphonePending && DisplayContext.foreground) {
        if (info.microphoneRequested && !this.microphoneAllowed) void this.toggleMicrophone(true);
        else if (!info.microphoneRequested && this.microphoneAllowed) this.disableMicrophone(Strings.microphoneOff, false);
      }
      if(this.microphoneAllowed&&!DisplayContext.microphoneAllowed){this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;this.microphoneMessage=Strings.microphoneForeground;}
      this.updateFPS(info);
      this.error = info.error;
      this.streamWidth = info.width;
      this.streamHeight = info.height;
      this.targetFPS = info.targetFPS;
      this.latestMode = info.latestMode;
      this.timedSupported = info.timedSupported;
      this.processMs = info.receiveSubmitUs / 1000;
      this.hdrActive = info.hdrActive;
      AppStorage.setOrCreate('LinkDeskReceiverState', this.connectionState());
    }, 500);
  }

  private disableMicrophone(message: string = Strings.microphoneOff, publish: boolean = true): void {
    if (publish) linkdesk.setMicrophoneRequested(false);
    linkdesk.setMicrophoneEnabled(false);
    this.microphoneAllowed = false;
    DisplayContext.microphoneAllowed = false;
    this.microphoneMessage = message;
  }
  private async toggleMicrophone(fromMac: boolean = false): Promise<void> {
    if (this.microphonePending) return;
    if (this.microphoneAllowed) { this.disableMicrophone(); return; }
    this.microphonePending = true;
    if (!fromMac) linkdesk.setMicrophoneRequested(true);
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(getContext(this) as common.UIAbilityContext, ['ohos.permission.MICROPHONE']);
      if (!this.active || !DisplayContext.foreground) { this.disableMicrophone(); return; }
      const latest = JSON.parse(linkdesk.stats()) as ReceiverStats;
      if (!latest.microphoneRequested) { this.microphoneMessage = Strings.microphoneOff; return; }
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        // Capture only: granting permission must not re-publish an old ON intent.
        linkdesk.setMicrophoneEnabled(true);
        this.microphoneAllowed = true;
        DisplayContext.microphoneAllowed = true;
        this.microphoneMessage = Strings.panelMicWaiting;
      } else this.disableMicrophone(Strings.microphoneDenied);
    } catch (_) { this.disableMicrophone(Strings.microphoneError); }
    finally { this.microphonePending = false; }
  }
  @Builder microphoneAction() {
    Button(this.microphoneAllowed ? Strings.disableMicrophone : Strings.allowMicrophone)
      .backgroundColor(DT.keyboardKey(this.darkMode)).fontColor(DT.text(this.darkMode)).fontSize(DT.fontBody).borderRadius(DT.radiusSmall)
      .constraintSize({ minHeight: DT.layoutTouchTarget, minWidth: DT.layoutTouchTarget })
      .onClick(() => { void this.toggleMicrophone(); })
  }
  @Builder microphoneControl() {
    SettingRow({ title: Strings.tabletMicrophone,
      detail: this.microphoneState === 2 ? Strings.microphoneSending : this.microphoneState === -1 ? Strings.microphoneError : this.microphoneMessage,
      control: (): void => { this.microphoneAction(); } })
  }
  aboutToAppear(): void { this.active = true; }

  aboutToDisappear(): void {
    this.active = false;
    PlatformUI.setReceiver(false);
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    this.disableMicrophone();
    linkdesk.stop();
    AppStorage.setOrCreate('LinkDeskReceiverWorking', false);
    AppStorage.setOrCreate('LinkDeskReceiverState', ConnectionState.disconnected);
  }

  private connectionState(): ConnectionState {
    if (this.error !== 0) return ConnectionState.error;
    if (this.state === 3) return ConnectionState.working;
    if (this.hostRequestState > 0) return ConnectionState.waitingForMode;
    return ConnectionState.disconnected;
  }
  private connectionHint(): string {
    if (this.hostRequestState === 3) return Strings.capturePermissionHint;
    if (this.hostRequestState === 4) return Strings.macNotResponding;
    if (this.hostRequestState === 5) return Strings.usbChannelHint;
    return Strings.displayEmptyDescription;
  }
  private panelWidth(): number {
    return this.controlsVisible ? Math.min(DT.dimensionsPanelValue336, this.viewportWidth - DT.dimensionsPanelValue24) : 132;
  }
  private panelHeight(): number { return this.controlsVisible ? 224 : 48; }
  private clampPanel(): void {
    this.panelRight = Math.max(12, Math.min(this.panelRight, this.viewportWidth - this.panelWidth() - 12));
    this.panelTop = Math.max(12, Math.min(this.panelTop, this.viewportHeight - this.panelHeight() - 12));
  }
  private setControlsVisible(visible: boolean): void {
    this.getUIContext().animateTo({
      duration: this.reduceMotion ? 0 : 360,
      curve: curves.interpolatingSpring(0, 1, 280, 32)
    }, () => {
      this.controlsVisible = visible;
      this.clampPanel();
    });
  }
  private microphoneDetail(): string {
    if (this.microphoneState === -1) return Strings.microphoneError;
    if (this.microphoneAllowed && this.microphoneState === 2) return Strings.microphoneSending;
    return this.microphoneMessage;
  }
  private microphoneLabel(): string {
    if (this.microphoneState === -1) return Strings.panelMicError;
    if (!this.microphoneAllowed) return Strings.panelMicOff;
    return this.microphoneState === 2 ? Strings.panelMicSending : Strings.panelMicWaiting;
  }
  @Builder panelHeader() {
    Row({ space: 8 }) {
      Text('⠿').fontSize(DT.dimensionsPanelValue18).fontColor(DT.secondary(this.darkMode))
      Text(Strings.displayTitle).fontSize(DT.dimensionsPanelValue13).fontWeight(FontWeight.Medium).fontColor(DT.text(this.darkMode))
      Blank()
      Row().width(DT.dimensionsPanelValue6).height(DT.dimensionsPanelValue6).borderRadius(DT.dimensionsPanelValue3)
        .backgroundColor(this.state === 3 ? DT.success(this.darkMode) : DT.warning(this.darkMode))
      Text(ConnectionPresentation.title(this.connectionState())).fontSize(DT.dimensionsPanelValue11).fontColor(DT.secondary(this.darkMode))
    }.width('100%').height(DT.dimensionsPanelValue32)
      .accessibilityText(Strings.panelDrag)
      .gesture(PanGesture({ distance: 5 })
        .onActionStart(() => { this.dragRight = this.panelRight; this.dragTop = this.panelTop; })
        .onActionUpdate((event: GestureEvent) => {
          this.panelRight = this.dragRight - event.offsetX;
          this.panelTop = this.dragTop + event.offsetY;
          this.clampPanel();
        }))
  }
  @Builder panelAction(title: string, action: () => void, disabled: boolean = false) {
    Button(title).layoutWeight(1).height(DT.dimensionsPanelValue48).fontSize(DT.dimensionsPanelValue12)
      .backgroundColor(DT.keyboardKey(this.darkMode)).fontColor(DT.text(this.darkMode)).borderRadius(DT.dimensionsPanelValue12)
      .enabled(!disabled).accessibilityText(title).onClick(action)
  }
  @Builder floatingPanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.controlsVisible) {
        Column({ space: 4 }) {
        this.panelHeader()
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(`${this.realtimeFPS.toFixed(0)} fps`).fontSize(DT.dimensionsPanelValue18).fontWeight(FontWeight.Medium)
              .fontColor(DT.text(this.darkMode))
            Text(Strings.panelActualFPS).fontSize(DT.dimensionsPanelValue10).fontColor(DT.secondary(this.darkMode))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            .accessibilityText(Strings.get('panelFPSDescription', [this.realtimeFPS.toFixed(0), this.targetFPS.toString()]))
          Column({ space: 2 }) {
            Text(this.screenHz > 0 ? `${this.screenHz} Hz` : '— Hz').fontSize(DT.dimensionsPanelValue13).fontColor(DT.text(this.darkMode))
            Text(`${this.streamWidth} × ${this.streamHeight}${this.hdrActive ? ' · HDR10' : ''}`).fontSize(DT.dimensionsPanelValue10).fontColor(DT.secondary(this.darkMode))
          }.alignItems(HorizontalAlign.End)
            .accessibilityText(Strings.get('panelScreenRefresh', [this.screenHz.toString()]))
          Toggle({ type: ToggleType.Button, isOn: this.latestMode }) {
            Text(Strings.lowLatency).fontSize(DT.dimensionsPanelValue11).fontColor(DT.text(this.darkMode))
          }
            .height(DT.dimensionsPanelValue48).padding({ left: 10, right: 10 }).borderRadius(DT.dimensionsPanelValue12)
            .backgroundColor(DT.keyboardKey(this.darkMode)).selectedColor(DT.accentSoft(this.darkMode))
            .enabled(this.timedSupported).accessibilityText(Strings.lowLatency)
            .onChange((value: boolean) => { this.latestMode = value; linkdesk.setLatestMode(value); })
        }.width('100%').height(DT.dimensionsPanelValue48)
        Button() {
          Row({ space: 8 }) {
            Row().width(DT.dimensionsPanelValue6).height(DT.dimensionsPanelValue6).borderRadius(DT.dimensionsPanelValue3).backgroundColor(this.microphoneAllowed && this.microphoneState === 2
              ? DT.success(this.darkMode) : DT.secondary(this.darkMode))
            Column({ space: 2 }) {
              Text(this.microphoneLabel()).fontSize(DT.dimensionsPanelValue12).fontColor(DT.text(this.darkMode))
              Text(this.microphoneDetail()).fontSize(DT.dimensionsPanelValue10).fontColor(DT.secondary(this.darkMode))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(this.microphoneAllowed ? Strings.panelTurnOff : Strings.panelTurnOn)
              .fontSize(DT.dimensionsPanelValue11).fontColor(DT.secondary(this.darkMode))
          }.width('100%').padding({ left: 12, right: 12 })
        }.width('100%').height(DT.dimensionsPanelValue48).borderRadius(DT.dimensionsPanelValue12).backgroundColor(DT.keyboardKey(this.darkMode))
          .enabled(!this.microphonePending)
          .accessibilityText(`${this.microphoneDetail()} · ${this.microphoneAllowed ? Strings.disableMicrophone : Strings.allowMicrophone}`)
          .onClick(() => { void this.toggleMicrophone(); })
        Row({ space: 6 }) {
          this.panelAction(Strings.keyboardShort, () => AppStorage.setOrCreate('LinkDeskKeyboardVisible', true), !['ready', 'permission', 'secure-input'].includes(this.keyboardState))
          this.panelAction(Strings.backHome, () => this.onExit())
          this.panelAction(Strings.reconnect, () => this.connect())
          this.panelAction(Strings.hide, () => this.setControlsVisible(false))
        }.width('100%').height(DT.dimensionsPanelValue48)
        }.padding(DT.dimensionsPanelValue12).width(Math.min(DT.dimensionsPanelValue336, this.viewportWidth - DT.dimensionsPanelValue24)).height(DT.dimensionsPanelValue224)
          .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.OPACITY.animation({ duration: DT.durationPanelFade }))
      } else {
        Button() {
          Row({ space: 8 }) {
            Row().width(DT.dimensionsPanelValue6).height(DT.dimensionsPanelValue6).borderRadius(DT.dimensionsPanelValue3).backgroundColor(this.state === 3 ? DT.success(this.darkMode) : DT.warning(this.darkMode))
            Text(`${this.realtimeFPS.toFixed(0)} fps`).fontSize(DT.dimensionsPanelValue12).fontColor(DT.text(this.darkMode))
            Text('⌃').fontSize(DT.dimensionsPanelValue14).fontColor(DT.secondary(this.darkMode))
          }
        }.width('100%').height(DT.dimensionsPanelValue48).backgroundColor(Color.Transparent)
          .accessibilityText(`${Strings.panelExpand} · ${this.microphoneLabel()}`)
          .onClick(() => this.setControlsVisible(true))
          .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.OPACITY.animation({ duration: DT.durationPanelFade }))
      }
    }
      .width(this.panelWidth()).height(this.panelHeight()).borderRadius(DT.dimensionsPanelValue24)
      .backgroundColor(DT.keyboardGlass(this.darkMode))
      .linearGradient({ angle: 145, colors: [[DT.panelColor0(this.darkMode), 0], [DT.panelColor1(this.darkMode), 0.5], [DT.panelColor2(this.darkMode), 1]] })
      // A single bounded blur; no per-frame JS animation or full-screen hit target.
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .border({ width: 1, color: this.darkMode ? DT.panelColor3(this.darkMode) : DT.panelColor4(this.darkMode) })
      .shadow({ radius: 16, color: DT.panelColor5(this.darkMode), offsetY: 6 }).clip(true)
      .position({ x: this.viewportWidth - this.panelRight - this.panelWidth(), y: this.panelTop })
      .zIndex(10).hitTestBehavior(HitTestMode.Default)
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'LinkDeskDisplay', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.displayWidth).height(this.displayHeight)
        .onLoad(() => this.connect()).onDestroy(() => linkdesk.stop())
      CursorOverlay({ displayWidth: this.displayWidth, displayHeight: this.displayHeight }).zIndex(5)
      if (this.state !== 3) {
        Scroll() {
          Column({ space: DT.spacingS24 }) {
            PageHeader({ title: Strings.displayTitle, subtitle: Strings.displaySubtitle, state: this.connectionState() })
            EmptyState({ icon: DT.iconDisplay(this.darkMode), title: Strings.displayEmptyTitle, message: this.connectionHint(),
              actionTitle: Strings.reconnect, action: () => this.connect() })
            if (this.error !== 0) {
              Text(Strings.get('diagnosticCode', [this.error.toString()])).fontSize(DT.fontCaption).fontColor(DT.error(this.darkMode))
            }
            this.microphoneControl()
          }.width('100%').constraintSize({ maxWidth: DT.layoutPageMax }).padding(DT.layoutPagePadding)
        }.width('100%').height('100%').align(Alignment.Top).backgroundColor(DT.canvas(this.darkMode))
      }
      // Explicitly above the decoder SURFACE, including connection/error screens.
      this.floatingPanel()
    }.width('100%').height('100%').backgroundColor(DT.video(this.darkMode))
      .onAreaChange((_old: Area, current: Area) => {
        const width = Number(current.width); const height = Number(current.height);
        if (width <= 0 || height <= 0) return;
        this.viewportWidth = width; this.viewportHeight = height;
        this.clampPanel();
        this.displayWidth = Math.min(width, height * 1.5); this.displayHeight = this.displayWidth / 1.5;
      })

  }
}
