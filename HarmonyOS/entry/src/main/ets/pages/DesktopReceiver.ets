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
        linkdesk.setMicrophoneEnabled(true);this.microphoneAllowed=true;DisplayContext.microphoneAllowed=true;this.microphoneMessage='请在 Mac 连屏中开启平板麦克风';
      }else this.microphoneMessage=Strings.microphoneDenied;
    }catch(_error){this.microphoneMessage=Strings.microphoneError;}
  }
  @Builder microphoneControl(){
    Column({space:8}){
      Button(this.microphoneAllowed ? Strings.disableMicrophone : Strings.allowMicrophone)
        .onClick(()=>{this.toggleMicrophone();})
      Text(this.microphoneState===2 ? Strings.microphoneSending : this.microphoneState===-1 ? '麦克风启动失败，请检查权限' : this.microphoneMessage)
        .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
    }
  }
  aboutToDisappear(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    linkdesk.setMicrophoneEnabled(false);
    this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;
    linkdesk.stop();
  }

  @Builder homeControl() {
    Button(Strings.backHome).fontSize(DT.fontCaption).height(DT.spacingS40)
      .fontColor(DT.secondary(this.darkMode)).backgroundColor(DT.secondary(this.darkMode)).borderRadius(DT.radiusMedium)
      .margin({ left: DT.spacingS16, top: DT.spacingS16 }).onClick(() => this.onExit())
  }
  @Builder themeControl() {
    Button(this.themePreference === 'automatic' ? Strings.themeAutomatic : this.darkMode ? Strings.themeDark : Strings.themeLight)
      .fontSize(DT.fontCaption).height(DT.spacingS32).fontColor(DT.secondary(this.darkMode))
      .backgroundColor(DT.control(this.darkMode)).borderRadius(DT.radiusMedium).margin({ top: DT.spacingS16, right: DT.spacingS16 })
      .accessibilityText(Strings.themeAccessibility)
      .bindMenu([
        { value: Strings.themeAutomatic, action: () => LinkDeskTheme.select('automatic') },
        { value: Strings.themeLight, action: () => LinkDeskTheme.select('light') },
        { value: Strings.themeDark, action: () => LinkDeskTheme.select('dark') }
      ])
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'LinkDeskDisplay', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.displayWidth)
        .height(this.displayHeight)
        .onLoad(() => { this.connect(); })
        .onDestroy(() => { linkdesk.stop(); })
      if (this.state !== 3) {
        Column({ space: DT.spacingS20 }) {
          Text(Strings.displayTitle).fontSize(DT.fontTitle).fontWeight(FontWeight.Medium).fontColor(DT.text(this.darkMode))
          Text(this.state === 2 ? '正在显示 Mac 桌面' :
            this.hostRequestState === 3 ? Strings.capturePermissionHint :
            this.hostRequestState === 4 ? Strings.macNotResponding :
            this.hostRequestState === 5 ? Strings.usbChannelHint : '正在连接 Mac 连屏服务')
            .fontSize(DT.fontSection).fontColor(DT.secondary(this.darkMode))
          Text('保持数据线连接，打开平板应用即可请求副屏。')
            .fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).textAlign(TextAlign.Center)
          if (this.error !== 0) {
            Text('连接已中断，正在重试。诊断码：' + this.error.toString())
              .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
          }
          this.microphoneControl()
          Button(Strings.reconnect).onClick(() => { this.connect(); })
            .backgroundColor(DT.accent(this.darkMode)).fontColor(DT.onAccent(this.darkMode)).margin({ top: DT.spacingS12 })
        }.padding(DT.spacingS36).borderRadius(DT.radiusLarge).backgroundColor(DT.surface(this.darkMode))
      }
      if (this.state === 3 && this.controlsVisible) {
        Column({ space: DT.spacingS8 }) {
        Row({ space: DT.spacingS20 }) {
          Text('USB · ' + this.streamWidth.toString() + ' × ' + this.streamHeight.toString() + ' · 实时 ' + this.realtimeFPS.toFixed(0) + ' 帧/秒 · 目标 ' + this.targetFPS.toString() + ' 帧/秒')
            .fontSize(DT.fontCaption).fontColor(DT.text(this.darkMode))
          Button(Strings.reconnect).onClick(() => { this.connect(); })
          Button(Strings.hide).onClick(() => { this.controlsVisible = false; })
        }
        Row({ space: DT.spacingS16 }) {
          Button(this.latestMode && this.timedSupported ? Strings.lowLatencyOn : Strings.lowLatencyOff)
            .enabled(this.timedSupported)
            .onClick(() => {
              this.latestMode = !this.latestMode;
              linkdesk.setLatestMode(this.latestMode);
            })
          Text('最近一帧平板处理 ' + this.processMs.toFixed(1) + ' ms')
            .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
        }
        this.microphoneControl()
        Text(Strings.receiverStatistics).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
        Text(this.audioState === 2 ? Strings.audioPlaying : Strings.audioSelectHint)
          .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
        }.padding(DT.spacingS16).borderRadius(DT.radiusMedium).backgroundColor(DT.secondary(this.darkMode))
          .position({ x: 24, y: 24 })
      }
    }
    .overlay(this.homeControl, { align: Alignment.TopStart })
    .overlay(this.themeControl, { align: Alignment.TopEnd })
    .width('100%').height('100%').backgroundColor(DT.video(this.darkMode))
    .onAreaChange((_old: Area, current: Area) => {
      const width = Number(current.width);
      const height = Number(current.height);
      this.displayWidth = Math.min(width, height * 1.5);
      this.displayHeight = this.displayWidth / 1.5;
    })
    .onClick(() => { if (this.state === 3) this.controlsVisible = !this.controlsVisible; })
  }
}
