import { abilityAccessCtrl, common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { audio } from '@kit.AudioKit';
import { http, webSocket } from '@kit.NetworkKit';
import { notificationManager } from '@kit.NotificationKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import notification from '@ohos.notification';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { startIndependentTask } from '../BackgroundTask';
import { DisplayContext } from '../DisplayContext';
import { KeyboardClient } from '../keyboard/KeyboardClient';

interface MicHandshake {
  challenge?: string;
  proof?: string;
}

const NOTICE_ID: number = 24838;
const PCM_FRAME_BYTES: number = 1920;
const USB_HOST: string = '127.0.0.1';
const MIC_SOURCE: audio.AudioCapturerInfo = { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 };
const MIC_INPUT_SOURCES: audio.SourceType[] = [
  audio.SourceType.SOURCE_TYPE_MIC, audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
  audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE,
  audio.SourceType.SOURCE_TYPE_CAMCORDER, audio.SourceType.SOURCE_TYPE_UNPROCESSED,
  audio.SourceType.SOURCE_TYPE_LIVE
];

export class WirelessMicrophone {
  static readonly shared: WirelessMicrophone = new WirelessMicrophone();
  private context: common.UIAbilityContext | undefined;
  private socket: webSocket.WebSocket | undefined;
  private capturer: audio.AudioCapturer | undefined;
  private streamManager: audio.AudioStreamManager | undefined;
  private ownStreamId: number = -1;
  private interruptionMuted: boolean = false;
  private otherRecording: boolean = false;
  private restartCapture: boolean = false;
  private restartingCapture: boolean = false;
  private audioEpoch: number = 0;
  private key: cryptoFramework.SymKey | undefined;
  private challenge: string = '';
  private sequence: number = 0;
  private generation: number = 0;
  private backgroundId: number = -1;
  private captureTimer: number = -1;
  private routeTimer: number = -1;
  private lastCapture: number = 0;
  private state: string = 'off';
  private queue: Uint8Array[] = [];
  private sending: boolean = false;
  private switching: boolean = false;
  private probing: boolean = false;
  private attachedHost: string = '';
  private hosts: string[] = [];
  private noticeRequested: boolean = false;
  private noticeUpdatedAt: number = 0;
  private noticeToken: string = '';
  private stopSubscriber: commonEventManager.CommonEventSubscriber | undefined;
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();

  private taskCancelled: (info: backgroundTaskManager.ContinuousTaskCancelInfo) => void =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (this.backgroundId >= 0 && info.id === this.backgroundId) void this.stop('系统已结束后台麦克风');
    };

  private readonly streamsChanged = (): void => {
    // Query a fresh snapshot: a delayed event can refer to a stream that already ended.
    this.refreshOtherRecordings();
  };

  setup(context: common.UIAbilityContext): void {
    this.context = context;
    try {
      const store = preferences.getPreferencesSync(context, { name: 'linkdesk_wireless_mic' });
      this.noticeToken = store.getSync('noticeToken', '') as string;
      if (!this.noticeToken) {
        this.noticeToken = util.generateRandomUUID();
        store.putSync('noticeToken', this.noticeToken);
        store.flushSync();
      }
    } catch (_) {}
    if (this.noticeToken) {
      try {
        this.stopSubscriber = commonEventManager.createSubscriberSync({ events: [this.stopEvent] });
        commonEventManager.subscribe(this.stopSubscriber, (error, event) => {
          if (!error && event.event === this.stopEvent) void this.stop();
        });
      } catch (_) { this.stopSubscriber = undefined; }
    }
    try { backgroundTaskManager.on('continuousTaskCancel', this.taskCancelled); } catch (_) {}
  }

  acceptsNotification(token: string): boolean {
    return this.noticeToken.length > 0 && this.noticeToken === token;
  }

  private get stopEvent(): string { return 'com.zhekuan.linkdesk.wirelessMic.stop.' + this.noticeToken; }

  destroy(): void {
    try { backgroundTaskManager.off('continuousTaskCancel', this.taskCancelled); } catch (_) {}
    if (this.stopSubscriber) {
      try { commonEventManager.unsubscribe(this.stopSubscriber, () => {}); } catch (_) {}
    }
    this.stopSubscriber = undefined;
    void this.stop();
  }

  private showState(value: string, detail: string): void {
    this.state = value;
    AppStorage.setOrCreate('LinkDeskWirelessMicState', value);
    AppStorage.setOrCreate('LinkDeskWirelessMicDetail', detail);
  }

  async enableNotification(): Promise<void> {
    const context = this.context;
    if (!context || !DisplayContext.foreground) return;
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        await notificationManager.requestEnableNotification(context);
      }
      this.noticeRequested = await notificationManager.isNotificationEnabled();
      await this.publishNotification();
    } catch (_) {
      AppStorage.setOrCreate('LinkDeskWirelessMicDetail', '请在系统设置中允许 LinkDesk 通知');
    }
  }

  private async agent(start: boolean): Promise<WantAgent> {
    return wantAgent.getWantAgent({
      wants: [{
        bundleName: 'com.zhekuan.linkdesk', abilityName: 'EntryAbility',
        parameters: { wirelessMicrophone: start ? 'start' : 'stop', wirelessMicrophoneToken: this.noticeToken }
      }],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: start ? NOTICE_ID * 2 : NOTICE_ID * 2 + 1,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  private async publishNotification(): Promise<void> {
    if (!this.noticeRequested) return;
    const state = this.state;
    const active = state !== 'off' && state !== 'stopping';
    const transport = this.transportLabel();
    try {
      const agent = await this.agent(!active);
      const button = active && this.stopSubscriber ? await wantAgent.getWantAgent({
        wants: [{ action: this.stopEvent, bundleName: 'com.zhekuan.linkdesk' }],
        actionType: wantAgent.OperationType.SEND_COMMON_EVENT, requestCode: NOTICE_ID * 2 + 2,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      }) : agent;
      if (state !== this.state || transport !== this.transportLabel()) return;
      await notificationManager.publish({
        id: NOTICE_ID,
        slotType: notification.SlotType.SERVICE_INFORMATION,
        content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: 'LinkDesk 无线麦克风',
            text: state === 'paused' ? '已暂停 · 麦克风空闲后自动恢复' :
              active ? `正在发送到 Mac · ${transport}` : '已关闭 · USB 或同一 Wi-Fi 下可开启' } },
        wantAgent: agent,
        actionButtons: [{ title: active ? '关闭麦克风' : '开启麦克风', wantAgent: button }],
        isAlertOnce: true, tapDismissed: false,
        autoDeletedTime: active ? Date.now() + 18000 : undefined
      });
      this.noticeUpdatedAt = Date.now();
    } catch (_) {}
  }

  toggle(): void {
    if (this.state === 'off') void this.start();
    else void this.stop();
  }

  async start(): Promise<void> {
    const context = this.context;
    if (!context || !DisplayContext.foreground || this.state !== 'off') return;
    if (AppStorage.get<boolean>('LinkDeskMirrorRunning') === true) {
      const message = '请先停止平板投屏，再使用无线麦克风';
      this.showState('off', message);
      try { promptAction.showToast({ message }); } catch (_) {}
      return;
    }
    const generation = ++this.generation;
    this.showState('starting', '正在连接已配对的 Mac…');
    try {
      const credentials = await KeyboardClient.wirelessMicrophoneCredentials();
      if (!credentials) throw new Error('请在 Mac 打开「连接与配对」，用平板扫描二维码');
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,
        ['ohos.permission.MICROPHONE']);
      if (!result.authResults.length || result.authResults[0] !== 0) throw new Error('请允许 LinkDesk 使用麦克风');
      if (generation !== this.generation) return;
      if (!DisplayContext.foreground) throw new Error('请回到 LinkDesk 开启麦克风');
      this.key = credentials.key;
      this.hosts = [USB_HOST, ...credentials.hosts];
      const connectionError = await this.tryRoutes(generation);
      if (generation !== this.generation) return;
      if (!this.attachedHost) throw new Error('连不上 Mac，请检查 USB、同一 Wi-Fi 和 LinkDesk。' + connectionError);
      if (!DisplayContext.foreground) throw new Error('请回到 LinkDesk 开启麦克风');
      const capture = await audio.createAudioCapturer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: MIC_SOURCE
      });
      if (generation !== this.generation) { await capture.release(); return; }
      this.capturer = capture;
      capture.on('readData', (samples: ArrayBuffer): void => this.acceptSamples(samples, generation));
      capture.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if (generation === this.generation) this.handleInterrupt(event.hintType, generation);
      });
      // System muting keeps the recording session alive so it can resume in the background.
      try {
        capture.setIndependentAudioSessionStrategy({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT },
          audio.AudioSessionBehaviorFlags.MUTE_WHEN_INTERRUPTED);
      } catch (_) {
        await capture.setWillMuteWhenInterrupted(true);
      }
      if (generation !== this.generation) return;
      this.ownStreamId = capture.getCurrentAudioCapturerChangeInfo().streamId;
      this.watchRecordingStreams();
      this.lastCapture = Date.now();
      await capture.start();
      if (generation !== this.generation) return;
      this.refreshOtherRecordings();
      const agent = await this.agent(false);
      if (generation !== this.generation) return;
      let id = -1;
      try {
        id = await startIndependentTask(context, backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_RECORDING, agent);
      } catch (_) {
        // A rejected background request should not prevent foreground microphone use.
        if (generation !== this.generation) return;
        if (!DisplayContext.foreground) throw new Error('系统未允许后台录音，请回到 LinkDesk 开启');
        try { promptAction.showToast({ message: '麦克风已开启，系统只允许本次在前台使用' }); } catch (_) {}
      }
      if (generation !== this.generation) {
        if (id >= 0) await backgroundTaskManager.stopBackgroundRunning(context, id);
        return;
      }
      this.backgroundId = id;
      this.updateTransport();
      this.captureTimer = setInterval(() => {
        if (this.state === 'paused') {
          // A zero-byte PCM frame keeps the existing Mac input selected without forwarding audio.
          const socket = this.socket;
          if (socket && !this.sending && !this.switching) void this.keepPausedConnection(socket, generation);
        } else if (Date.now() - this.lastCapture > 1800) {
          void this.stop('麦克风采集已停止');
        }
      }, 500);
      this.routeTimer = setInterval(() => {
        void this.probeUSB();
        if (this.noticeRequested && Date.now() - this.noticeUpdatedAt >= 10000) void this.publishNotification();
      }, 2500);
      this.noticeRequested = await notificationManager.isNotificationEnabled().catch(() => false);
      await this.publishNotification();
    } catch (error) {
      if (generation === this.generation) {
        const message = (error as Error).message || '无线麦克风启动失败';
        await this.stop(message);
        if (DisplayContext.foreground) {
          try { promptAction.showToast({ message }); } catch (_) {}
        }
      }
    }
  }

  onForeground(): void {
    this.refreshOtherRecordings();
    if (this.restartCapture && !this.interruptionMuted) void this.resumeCapture(this.generation);
  }

  private watchRecordingStreams(): void {
    try {
      this.streamManager = audio.getAudioManager().getStreamManager();
      this.streamManager.on('audioCapturerChange', this.streamsChanged);
      this.refreshOtherRecordings();
    } catch (_) {
      this.streamManager = undefined;
    }
  }

  private refreshOtherRecordings(): void {
    if (!this.streamManager || this.ownStreamId < 0) return;
    try {
      const streams = this.streamManager.getCurrentAudioCapturerInfoArraySync();
      // Ignore ourselves, system wake-word streams, and streams that only record playback.
      const busy = streams.some((stream) => stream.streamId !== this.ownStreamId && stream.muted !== true &&
        MIC_INPUT_SOURCES.includes(stream.capturerInfo.source));
      if (busy === this.otherRecording) return;
      this.otherRecording = busy;
      this.refreshPauseState();
      if (!busy && !this.interruptionMuted && this.restartCapture) void this.resumeCapture(this.generation);
    } catch (_) {}
  }

  private handleInterrupt(hint: audio.InterruptHint, generation: number): void {
    switch (hint) {
      case audio.InterruptHint.INTERRUPT_HINT_STOP:
        void this.stop('系统已停止麦克风，请重新开启');
        return;
      case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
        this.restartCapture = true;
        this.interruptionMuted = true;
        break;
      case audio.InterruptHint.INTERRUPT_HINT_MUTE:
        this.interruptionMuted = true;
        break;
      case audio.InterruptHint.INTERRUPT_HINT_RESUME:
      case audio.InterruptHint.INTERRUPT_HINT_UNMUTE:
        this.interruptionMuted = false;
        this.refreshOtherRecordings();
        if (this.restartCapture) void this.resumeCapture(generation);
        break;
      default:
        return;
    }
    this.refreshPauseState();
  }

  private async resumeCapture(generation: number): Promise<void> {
    const capture = this.capturer;
    if (!capture || this.restartingCapture || this.interruptionMuted || this.otherRecording) return;
    this.restartingCapture = true;
    try {
      if (capture.state !== audio.AudioState.STATE_RUNNING) await capture.start();
      if (generation !== this.generation) return;
      if (!this.interruptionMuted && !this.otherRecording) this.restartCapture = false;
    } catch (_) {
      // If HarmonyOS blocks a new background start, retry only when the app returns to the foreground.
      if (generation === this.generation && DisplayContext.foreground && !this.interruptionMuted && !this.otherRecording) {
        void this.stop('麦克风恢复失败，请重新开启');
      }
    } finally {
      if (generation === this.generation) {
        this.restartingCapture = false;
        this.refreshPauseState();
      }
    }
  }

  private get paused(): boolean {
    return this.interruptionMuted || this.otherRecording || this.restartCapture;
  }

  private refreshPauseState(): void {
    if (this.paused) {
      this.queue = [];
      ++this.audioEpoch;
    }
    if ((this.state === 'on' && this.paused) || (this.state === 'paused' && !this.paused)) {
      this.lastCapture = Date.now();
      this.updateTransport();
      void this.publishNotification();
    }
  }

  private async keepPausedConnection(socket: webSocket.WebSocket, generation: number): Promise<void> {
    this.sending = true;
    try {
      await this.send(socket, new Uint8Array(0));
    } catch (_) {
      if (generation === this.generation && this.socket === socket) void this.reconnect();
    } finally {
      if (generation === this.generation) {
        this.sending = false;
        if (!this.switching && !this.paused && this.queue.length) void this.flush(generation);
      }
    }
  }

  onBackground(): void {
    if (this.state === 'starting') void this.stop('请在前台开启后再切换应用');
    else if ((this.state === 'on' || this.state === 'paused') && this.backgroundId < 0) {
      void this.stop('本次麦克风仅在前台可用');
    }
  }

  async stop(detail: string = '已关闭'): Promise<void> {
    if (this.state === 'off' || this.state === 'stopping') return;
    ++this.generation;
    this.showState('stopping', detail);
    clearInterval(this.captureTimer);
    clearInterval(this.routeTimer);
    try { this.streamManager?.off('audioCapturerChange', this.streamsChanged); } catch (_) {}
    this.streamManager = undefined;
    this.ownStreamId = -1;
    this.interruptionMuted = false;
    this.otherRecording = false;
    this.restartCapture = false;
    this.restartingCapture = false;
    ++this.audioEpoch;
    this.closeSocket();
    this.key = undefined;
    this.queue = [];
    this.sending = false;
    this.switching = false;
    this.attachedHost = '';
    const capture = this.capturer;
    this.capturer = undefined;
    if (capture) {
      try { await capture.stop(); } catch (_) {}
      try { await capture.release(); } catch (_) {}
    }
    const context = this.context;
    const id = this.backgroundId;
    this.backgroundId = -1;
    if (context && id >= 0) {
      try { await backgroundTaskManager.stopBackgroundRunning(context, id); } catch (_) {}
    }
    this.showState('off', detail);
    await this.publishNotification();
  }

  private closeSocket(): void {
    const socket = this.socket;
    this.socket = undefined;
    this.challenge = '';
    if (socket) {
      void socket.close().catch(() => {});
    }
  }

  private transportLabel(): string {
    if (!this.attachedHost) return '正在连接';
    return this.attachedHost === USB_HOST ? 'USB 有线' : 'Wi-Fi';
  }

  private updateTransport(): void {
    if (this.paused) this.showState('paused', '麦克风已让出，空闲后自动恢复');
    else this.showState('on', `正在通过 ${this.transportLabel()} 将平板麦克风发送到 Mac`);
  }

  private async tryRoutes(generation: number): Promise<string> {
    let errorMessage = '';
    const deadline = Date.now() + 4000;
    this.attachedHost = '';
    for (const host of this.hosts) {
      if (generation !== this.generation || Date.now() >= deadline) return errorMessage;
      try {
        await this.connect(host, generation);
        if (generation === this.generation) this.attachedHost = host;
        return '';
      } catch (error) {
        if (generation !== this.generation) return errorMessage;
        errorMessage = (error as Error).message || '连接失败';
        this.closeSocket();
      }
    }
    return errorMessage;
  }

  private async probeUSB(): Promise<void> {
    if ((this.state !== 'on' && this.state !== 'paused') || this.switching || this.probing || this.attachedHost === USB_HOST) return;
    this.probing = true;
    const client = http.createHttp();
    try {
      const response = await client.request(`http://${USB_HOST}:3210/config`, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 500, readTimeout: 600, usingCache: false
      });
      if (response.responseCode === 200 && (this.state === 'on' || this.state === 'paused') && this.attachedHost !== USB_HOST) {
        await this.reconnect();
      }
    } catch (_) {} finally { client.destroy(); this.probing = false; }
  }

  private async reconnect(): Promise<void> {
    if ((this.state !== 'on' && this.state !== 'paused') || this.switching) return;
    const generation = this.generation;
    this.switching = true;
    this.closeSocket();
    this.attachedHost = '';
    if (!this.paused) this.showState('on', '正在切换麦克风连接…');
    await new Promise<void>((resolve) => { setTimeout(resolve, 250); });
    if (generation !== this.generation) return;
    await this.tryRoutes(generation);
    if (generation !== this.generation) return;
    this.switching = false;
    if (!this.attachedHost) { await this.stop('Mac 连接已断开，麦克风已关闭'); return; }
    this.updateTransport();
    void this.publishNotification();
    if (!this.sending && this.queue.length) void this.flush(generation);
  }

  private async connect(host: string, generation: number): Promise<void> {
    const address = host.includes(':') ? '[' + host + ']' : host;
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    this.challenge = '';
    this.sequence = 0;
    return new Promise<void>((resolve, reject) => {
      let proved = false;
      const timer = setTimeout(() => reject(new Error(this.challenge ? '音频认证超时' : '网络连接超时')),
        host === USB_HOST ? 1050 : 2000);
      const failed = (): void => {
        clearTimeout(timer);
        if (this.socket !== socket || generation !== this.generation) return;
        if (!proved) reject(new Error(this.challenge ? '音频认证未完成' : '网络连接失败'));
        else if (this.state === 'on' || this.state === 'paused') void this.reconnect();
        else void this.stop('Mac 连接已断开，麦克风已关闭');
      };
      socket.on('message', (_error, raw: string | ArrayBuffer) => {
        if (typeof raw !== 'string' || proved || this.socket !== socket || generation !== this.generation) return;
        void this.handshake(raw, socket).then((ready: boolean) => {
          if (!ready || this.socket !== socket || generation !== this.generation) return;
          proved = true;
          clearTimeout(timer);
          resolve();
        }).catch((error: Error) => {
          clearTimeout(timer);
          reject(error);
        });
      });
      socket.on('close', () => failed());
      socket.on('error', () => failed());
      void socket.connect(`ws://${address}:3210/wireless-mic`).then((ok: boolean) => {
        if (!ok) failed();
      }).catch(() => failed());
    });
  }

  private async handshake(value: string, socket: webSocket.WebSocket): Promise<boolean> {
    const envelope = JSON.parse(value) as MicHandshake;
    if (!this.challenge && envelope.challenge && /^[a-f0-9]{48}$/.test(envelope.challenge)) {
      this.challenge = envelope.challenge;
      await this.send(socket, new Uint8Array(0));
      return false;
    }
    const key = this.key;
    if (!key || !this.challenge || !envelope.proof) throw new Error('认证失败');
    const bytes = this.base64.decodeSync(envelope.proof);
    if (bytes.length !== 33) throw new Error('认证失败');
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv: { data: bytes.slice(0, 12) },
      aad: { data: this.encoder.encodeInto(`LDWM1:${this.challenge}:mac`) },
      authTag: { data: bytes.slice(-16) }
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    const proof = await cipher.doFinal({ data: bytes.slice(12, -16) });
    if (new util.TextDecoder().decodeWithStream(proof.data) !== 'ready') throw new Error('Mac 认证失败');
    return true;
  }

  private acceptSamples(samples: ArrayBuffer, generation: number): void {
    if (generation !== this.generation || !this.capturer) return;
    this.lastCapture = Date.now();
    if (this.paused) return;
    const input = new Uint8Array(samples);
    for (let offset = 0; offset < input.length; offset += PCM_FRAME_BYTES) {
      this.queue.push(input.slice(offset, offset + PCM_FRAME_BYTES));
    }
    if (this.queue.length > 5) this.queue.splice(0, this.queue.length - 5);
    if (!this.sending && !this.switching && this.socket) void this.flush(generation);
  }

  private async flush(generation: number): Promise<void> {
    const socket = this.socket;
    if (!socket) return;
    this.sending = true;
    try {
      while (generation === this.generation && this.socket === socket && this.queue.length) {
        const samples = this.queue.shift();
        if (samples) await this.send(socket, samples);
      }
    } catch (_) {
      if (generation === this.generation && this.socket === socket) {
        if (this.state === 'starting') void this.stop('音频发送中断');
        else void this.reconnect();
      }
    } finally {
      if (generation === this.generation) this.sending = false;
    }
  }

  private async send(socket: webSocket.WebSocket, samples: Uint8Array): Promise<void> {
    const key = this.key;
    const challenge = this.challenge;
    if (!key || !challenge) throw new Error('未连接');
    const payload = new Uint8Array(4 + samples.length);
    const epoch = this.audioEpoch;
    new DataView(payload.buffer).setUint32(0, this.sequence);
    payload.set(samples, 4);
    const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const parameters: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv: { data: nonce },
      aad: { data: this.encoder.encodeInto(`LDWM1:${challenge}:tablet`) },
      authTag: { data: new Uint8Array(16) }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, parameters);
    const encrypted = await cipher.doFinal({ data: payload });
    const packet = new Uint8Array(nonce.length + encrypted.data.length);
    packet.set(nonce);
    packet.set(encrypted.data, nonce.length);
    if (this.socket !== socket) throw new Error('连接已切换');
    if (samples.length && (epoch !== this.audioEpoch || this.paused)) return;
    ++this.sequence;
    if (!await socket.send(this.base64.encodeToStringSync(packet))) {
      throw new Error('发送失败');
    }
  }
}
