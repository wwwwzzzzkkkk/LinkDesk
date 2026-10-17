import { PlatformUI } from '../design/PlatformUI';
import { PageHeader, EmptyState, SettingRow } from '../design/Components';
import { DT, Strings, ConnectionState, ConnectionPresentation } from '../design/GeneratedDesign';
import { LinkDeskTheme } from '../LinkDeskTheme';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import linkdesk from 'liblinkdesk.so';
import systemDateTime from '@ohos.systemDateTime';
import { DisplayContext } from '../DisplayContext';

interface ReceiverStats {
  microphoneState: number;
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
  latestMode: boolean;
  timedSupported: boolean;
  timedSubmissions: number;
  receiveSubmitUs: number;
  decodeUs: number;
  submitUs: number;
}

interface FrameSample {
  timeMs: number;
  frames: number;
}

@Component
export struct DesktopReceiver {
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
  @State private controlsVisible: boolean = false;
  @State private latestMode: boolean = true;
  @State private timedSupported: boolean = true;
  @State private audioState: number = 0;
  @State private processMs: number = 0;
  @State private displayWidth: number = 960;
  @State private displayHeight: number = 640;

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
    this.frameSamples = [];
    this.realtimeFPS = 0;
    linkdesk.setLatestMode(this.latestMode);
    linkdesk.start(this.surface.getXComponentSurfaceId(), DisplayContext.windowId);
    if(this.microphoneAllowed) linkdesk.setMicrophoneEnabled(true);
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = setInterval(() => {
      const info = JSON.parse(linkdesk.stats()) as ReceiverStats;
      this.state = info.state;
      AppStorage.setOrCreate('LinkDeskReceiverWorking', info.state === 3);
      this.hostRequestState = info.hostRequestState;
      this.audioState = info.audioState;
      this.microphoneState = info.microphoneState;
      if(this.microphoneAllowed&&!DisplayContext.microphoneAllowed){this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;this.microphoneMessage=Strings.microphoneForeground;}
      this.updateFPS(info);
      this.error = info.error;
      this.streamWidth = info.width;
      this.streamHeight = info.height;
      this.targetFPS = info.targetFPS;
      this.latestMode = info.latestMode;
      this.timedSupported = info.timedSupported;
      this.processMs = info.receiveSubmitUs / 1000;
    }, 500);
  }

  private async toggleMicrophone(): Promise<void> {
    if(this.microphoneAllowed){linkdesk.setMicrophoneEnabled(false);this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;this.microphoneMessage=Strings.microphoneOff;return;}
    try {
      const manager=abilityAccessCtrl.createAtManager();
      const result=await manager.requestPermissionsFromUser(getContext(this) as common.UIAbilityContext,['ohos.permission.MICROPHONE']);
      if(result.authResults.length>0 && result.authResults[0]===0){
        linkdesk.setMicrophoneEnabled(true);this.microphoneAllowed=true;DisplayContext.microphoneAllowed=true;this.microphoneMessage=Strings.microphoneMacHint;
      }else this.microphoneMessage=Strings.microphoneDenied;
    }catch(_error){this.microphoneMessage=Strings.microphoneError;}
  }
  @Builder microphoneAction() {
    Button(this.microphoneAllowed ? Strings.disableMicrophone : Strings.allowMicrophone)
      .constraintSize({ minHeight: DT.layoutTouchTarget, minWidth: DT.layoutTouchTarget })
      .onClick(() => { void this.toggleMicrophone(); })
  }
  @Builder microphoneControl() {
    SettingRow({ title: Strings.tabletMicrophone,
      detail: this.microphoneState === 2 ? Strings.microphoneSending : this.microphoneState === -1 ? Strings.microphoneError : this.microphoneMessage,
      control: this.microphoneAction })
  }
  aboutToAppear(): void { PlatformUI.setReceiver(true); }

  aboutToDisappear(): void {
    PlatformUI.setReceiver(false);
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    linkdesk.setMicrophoneEnabled(false);
    this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;
    linkdesk.stop();
    AppStorage.setOrCreate('LinkDeskReceiverWorking', false);
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
  @Builder exitControl() {
    Button(Strings.backHome)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).fontSize(DT.fontBody)
      .backgroundColor(DT.control(this.darkMode)).fontColor(DT.text(this.darkMode)).borderRadius(DT.radiusSmall)
      .onClick(() => this.onExit())
  }
  @Builder latencyControl() {
    Toggle({ type: ToggleType.Switch, isOn: this.latestMode }).enabled(this.timedSupported)
      .height(DT.layoutTouchTarget).onChange((value: boolean) => { this.latestMode = value; linkdesk.setLatestMode(value); })
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'LinkDeskDisplay', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.displayWidth).height(this.displayHeight)
        .onLoad(() => this.connect()).onDestroy(() => linkdesk.stop())
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
      if (this.state === 3 && this.controlsVisible) {
        Column({ space: DT.spacingS16 }) {
          PageHeader({ title: Strings.displayTitle, subtitle: Strings.displaySubtitle, state: this.connectionState() })
          Text(Strings.get('receiverMetrics', [this.streamWidth.toString(), this.streamHeight.toString(), this.realtimeFPS.toFixed(0), this.targetFPS.toString()]))
            .fontSize(DT.fontCaption).fontColor(DT.text(this.darkMode))
          SettingRow({ title: Strings.lowLatency, detail: Strings.get('receiverProcessing', [this.processMs.toFixed(1)]), control: this.latencyControl })
          this.microphoneControl()
          Row({ space: DT.spacingS12 }) {
            this.exitControl()
            Button(Strings.reconnect)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).onClick(() => this.connect())
            Button(Strings.hide)
      .constraintSize({ minWidth: DT.layoutTouchTarget, minHeight: DT.layoutTouchTarget }).height(DT.layoutTouchTarget).onClick(() => { this.controlsVisible = false; })
          }
        }.width('100%').constraintSize({ maxWidth: DT.layoutPageMax }).padding(DT.spacingS24).borderRadius(DT.radiusMedium)
          .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      }
    }.width('100%').height('100%').backgroundColor(DT.video(this.darkMode))
      .onAreaChange((_old: Area, current: Area) => {
        const width = Number(current.width); const height = Number(current.height);
        this.displayWidth = Math.min(width, height * 1.5); this.displayHeight = this.displayWidth / 1.5;
      })
      .onClick(() => { if (this.state === 3) this.controlsVisible = !this.controlsVisible; })
  }
}
