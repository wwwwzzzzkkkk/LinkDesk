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

@Entry
@Component
struct Index {
  @State private microphoneAllowed: boolean = false;
  @State private microphoneState: number = 0;
  @State private microphoneMessage: string = '平板麦克风：关闭';
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
      if(this.microphoneAllowed&&!DisplayContext.microphoneAllowed){this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;this.microphoneMessage='返回应用后请重新允许麦克风';}
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
    if(this.microphoneAllowed){linkdesk.setMicrophoneEnabled(false);this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;this.microphoneMessage='平板麦克风：关闭';return;}
    try {
      const manager=abilityAccessCtrl.createAtManager();
      const result=await manager.requestPermissionsFromUser(getContext(this) as common.UIAbilityContext,['ohos.permission.MICROPHONE']);
      if(result.authResults.length>0 && result.authResults[0]===0){
        linkdesk.setMicrophoneEnabled(true);this.microphoneAllowed=true;DisplayContext.microphoneAllowed=true;this.microphoneMessage='请在 Mac 连屏中开启平板麦克风';
      }else this.microphoneMessage='未允许麦克风，可在设置中重新授权';
    }catch(_error){this.microphoneMessage='无法开启麦克风，请检查权限';}
  }
  @Builder microphoneControl(){
    Column({space:8}){
      Button(this.microphoneAllowed ? '关闭平板麦克风' : '允许 Mac 使用平板麦克风')
        .onClick(()=>{this.toggleMicrophone();})
      Text(this.microphoneState===2 ? '麦克风正在通过 USB 发送到 Mac' : this.microphoneState===-1 ? '麦克风启动失败，请检查权限' : this.microphoneMessage)
        .fontSize(12).fontColor('#C6CEE0')
    }
  }
  aboutToDisappear(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    linkdesk.setMicrophoneEnabled(false);
    this.microphoneAllowed=false;DisplayContext.microphoneAllowed=false;
    linkdesk.stop();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'LinkDeskDisplay', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.displayWidth)
        .height(this.displayHeight)
        .onLoad(() => { this.connect(); })
        .onDestroy(() => { linkdesk.stop(); })
      if (this.state !== 3) {
        Column({ space: 20 }) {
          Text('连屏 LinkDesk').fontSize(36).fontWeight(FontWeight.Medium).fontColor('#F3F5FB')
          Text(this.state === 2 ? '正在显示 Mac 桌面' :
            this.hostRequestState === 3 ? '请先在 Mac 上允许录屏' :
            this.hostRequestState === 4 ? 'Mac 未响应，请确认电脑仍在运行' :
            this.hostRequestState === 5 ? '等待 Mac USB 通道，请检查数据线与授权' : '正在连接 Mac 连屏服务')
            .fontSize(23).fontColor('#E0E7FF')
          Text('保持数据线连接，打开平板应用即可请求副屏。')
            .fontSize(17).fontColor('#A4ACC1').textAlign(TextAlign.Center)
          if (this.error !== 0) {
            Text('连接已中断，正在重试。诊断码：' + this.error.toString())
              .fontSize(14).fontColor('#A4ACC1')
          }
          this.microphoneControl()
          Button('重新连接').onClick(() => { this.connect(); })
            .backgroundColor('#5978F4').fontColor(Color.White).margin({ top: 12 })
        }.padding(40).borderRadius(28).backgroundColor('#EE111622')
      }
      if (this.state === 3 && this.controlsVisible) {
        Column({ space: 10 }) {
        Row({ space: 20 }) {
          Text('USB · ' + this.streamWidth.toString() + ' × ' + this.streamHeight.toString() + ' · 实时 ' + this.realtimeFPS.toFixed(0) + ' 帧/秒 · 目标 ' + this.targetFPS.toString() + ' 帧/秒')
            .fontSize(14).fontColor('#F3F5FB')
          Button('重新连接').onClick(() => { this.connect(); })
          Button('隐藏').onClick(() => { this.controlsVisible = false; })
        }
        Row({ space: 16 }) {
          Button(this.latestMode && this.timedSupported ? '低延迟显示：开' : '低延迟显示：关')
            .enabled(this.timedSupported)
            .onClick(() => {
              this.latestMode = !this.latestMode;
              linkdesk.setLatestMode(this.latestMode);
            })
          Text('最近一帧平板处理 ' + this.processMs.toFixed(1) + ' ms')
            .fontSize(12).fontColor('#C6CEE0')
        }
        this.microphoneControl()
        Text('近 1 秒统计，静止画面会减少出帧').fontSize(12).fontColor('#C6CEE0')
        Text(this.audioState === 2 ? '正在播放 Mac 声音' : '在 Mac 声音输出中选择 MatePad 扬声器')
          .fontSize(12).fontColor('#C6CEE0')
        }.padding(16).borderRadius(20).backgroundColor('#DD111622')
          .position({ x: 24, y: 24 })
      }
    }
    .width('100%').height('100%').backgroundColor(Color.Black)
    .onAreaChange((_old: Area, current: Area) => {
      const width = Number(current.width);
      const height = Number(current.height);
      this.displayWidth = Math.min(width, height * 1.5);
      this.displayHeight = this.displayWidth / 1.5;
    })
    .onClick(() => { if (this.state === 3) this.controlsVisible = !this.controlsVisible; })
  }
}
