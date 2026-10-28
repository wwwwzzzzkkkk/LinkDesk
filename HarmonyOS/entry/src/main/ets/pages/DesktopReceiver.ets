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
import { TouchClient } from './TouchClient';
import { KeyboardClient } from '../keyboard/KeyboardClient';

interface TouchPoint { x: number; y: number; }

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
  private touchClient: TouchClient = new TouchClient();
  private touchPoints: Map<number, TouchPoint> = new Map();
  private touchMode: string = 'idle';
  private touchPrimary: number = -1;
  private touchStart: TouchPoint = { x: 0, y: 0 };
  private touchLast: TouchPoint = { x: 0, y: 0 };
  private scrollLast: TouchPoint = { x: 0, y: 0 };
  private holdTimer: number = -1;
  @State private touchInputMode: string = 'auto';
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
    this.cancelTouch();
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
      if (this.state === 3 && info.state !== 3) this.cancelTouch();
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
  aboutToAppear(): void { this.active = true; this.touchClient.start(); }

  aboutToDisappear(): void {
    this.active = false;
    this.cancelTouch(); this.touchClient.stop();
    PlatformUI.setReceiver(false);
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    this.disableMicrophone();
    linkdesk.stop();
    AppStorage.setOrCreate('LinkDeskReceiverWorking', false);
    AppStorage.setOrCreate('LinkDeskReceiverState', ConnectionState.disconnected);
  }

  private stopHold(): void { if (this.holdTimer >= 0) clearTimeout(this.holdTimer); this.holdTimer = -1; }
  private sendTouch(type: string, p: TouchPoint, dx: number = 0, dy: number = 0): void {
    if (this.displayWidth <= 0 || this.displayHeight <= 0) return;
    this.touchClient.send(type, p.x / this.displayWidth, p.y / this.displayHeight, dx, dy, this.touchInputMode, this.reduceMotion);
  }
  private cancelTouch(): void {
    this.stopHold(); this.touchClient.send('cancel', 0, 0); this.touchPoints.clear(); this.touchPrimary = -1; this.touchMode = 'idle';
  }
  private touchCenter(): TouchPoint {
    let x = 0; let y = 0; let count = 0;
    this.touchPoints.forEach((point: TouchPoint) => { x += point.x; y += point.y; count++; });
    return count ? { x: x / count, y: y / count } : this.touchLast;
  }
  private handleTouch(event: TouchEvent): void {
    if (this.state !== 3 || !DisplayContext.foreground) { this.cancelTouch(); return; }
    if (event.type === TouchType.Cancel) { this.cancelTouch(); return; }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      event.changedTouches.forEach((touch: TouchObject) => { this.touchPoints.set(touch.id, { x: touch.x, y: touch.y }); });
    }
    if (event.type === TouchType.Down && this.touchPoints.size === 1 && this.touchMode === 'idle') {
      const touch = event.changedTouches[0]; if (!touch) return;
      this.sendTouch('halt', { x: touch.x, y: touch.y });
      this.touchPrimary = touch.id; this.touchStart = { x: touch.x, y: touch.y }; this.touchLast = this.touchStart; this.touchMode = 'pending';
      this.stopHold(); this.holdTimer = setTimeout(() => {
        if (this.touchMode === 'pending' && this.touchPoints.size === 1) { this.sendTouch('right', this.touchLast); this.touchMode = 'handled'; }
        this.holdTimer = -1;
      }, 500);
    } else if (event.type === TouchType.Down && this.touchPoints.size >= 2) {
      this.stopHold(); if (this.touchMode === 'drag') this.sendTouch('up', this.touchLast);
      this.touchMode = 'scroll'; this.scrollLast = this.touchCenter();
    } else if (event.type === TouchType.Move && this.touchMode === 'scroll' && this.touchPoints.size >= 2) {
      const center = this.touchCenter();
      // Positive wheel delta follows the natural finger direction.
      const dx = Math.max(-200, Math.min(200, (center.x - this.scrollLast.x) * 2));
      const dy = Math.max(-200, Math.min(200, (center.y - this.scrollLast.y) * 2));
      if (Math.abs(dx) + Math.abs(dy) >= 0.5) { this.sendTouch('scroll', center, dx, dy); this.scrollLast = center; }
    } else if (event.type === TouchType.Move && (this.touchMode === 'pending' || this.touchMode === 'drag')) {
      const point = this.touchPoints.get(this.touchPrimary); if (!point) return;
      this.touchLast = point;
      if (this.touchMode === 'pending' && Math.hypot(point.x - this.touchStart.x, point.y - this.touchStart.y) >= 5) {
        this.stopHold(); this.sendTouch('down', this.touchStart); this.touchMode = 'drag';
      }
      if (this.touchMode === 'drag') this.sendTouch('move', point);
    }
    if (event.type === TouchType.Up) {
      if (this.touchMode === 'scroll') { this.sendTouch('scrollend', this.touchCenter()); this.touchMode = 'handled'; }
      event.changedTouches.forEach((touch: TouchObject) => {
        if (touch.id === this.touchPrimary) {
          const p: TouchPoint = { x: touch.x, y: touch.y };
          if (this.touchMode === 'pending') { this.sendTouch('down', p); this.sendTouch('up', p); }
          else if (this.touchMode === 'drag') this.sendTouch('up', p);
        }
        this.touchPoints.delete(touch.id);
      });
      if (this.touchPoints.size === 0) { this.stopHold(); this.touchPrimary = -1; this.touchMode = 'idle'; }
      else if (this.touchMode === 'scroll') this.scrollLast = this.touchCenter();
    }
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
      Button(this.touchInputMode === 'auto' ? Strings.touchAuto : this.touchInputMode === 'scroll' ? Strings.touchScroll : Strings.touchSelect)
        .height(DT.spacingS28).padding({ left: DT.spacingS8, right: DT.spacingS8 }).fontSize(DT.dimensionsPanelValue10)
        .borderRadius(DT.dimensionsPanelValue12).backgroundColor(DT.keyboardKey(this.darkMode)).fontColor(DT.text(this.darkMode))
        .accessibilityText(Strings.touchModeHint).onClick(() => {
          this.cancelTouch(); this.touchInputMode = this.touchInputMode === 'auto' ? 'scroll' : this.touchInputMode === 'scroll' ? 'select' : 'auto';
        })
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
          this.panelAction(Strings.keyboardShort, () => { KeyboardClient.refresh(); AppStorage.setOrCreate('LinkDeskKeyboardVisible', true); })
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
      Column() {}.width(this.displayWidth).height(this.displayHeight).backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => this.handleTouch(event)).zIndex(6)
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
