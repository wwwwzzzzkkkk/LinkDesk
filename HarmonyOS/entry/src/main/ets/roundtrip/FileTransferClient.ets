import { common, Want, wantConstant } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { http, mdns } from '@kit.NetworkKit';
import { systemShare } from '@kit.ShareKit';
import { preferences, uniformTypeDescriptor } from '@kit.ArkData';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Strings } from '../design/GeneratedDesign';
import { SecureFilePeer } from './SecureFilePeer';
import { IncomingFileNotifications } from './IncomingFileNotifications';
import { RoundTripLiveViewController } from './RoundTripLiveViewController';

export interface IncomingFile {
  id: string;
  name: string;
  size: number;
  sha256: string;
  annotationID: string | null;
}

export interface SendResult {
  sent: number;
  message: string;
}

interface RelayConfiguration {
  urls: string[];
}

const LIMIT: number = 64 * 1024 * 1024;
const USB: string = 'http://127.0.0.1:3210';

export class FileTransferClient {
  private static context: common.UIAbilityContext | undefined;
  private static timer: number = -1;
  private static inForeground: boolean = false;
  private static checking: boolean = false;
  private static sending: boolean = false;
  private static receiving: boolean = false;
  private static relayPrefix: string = '';
  private static routesCheckedAt: number = 0;
  private static pending: string = '';
  private static lastDiscovery: number = 0;

  static start(context: common.UIAbilityContext): void {
    FileTransferClient.context = context;
    IncomingFileNotifications.setup(context, () => {
      if (!FileTransferClient.inForeground) FileTransferClient.updateBackgroundPolling();
    });
    FileTransferClient.pending = FileTransferClient.saved('fileTransferAnnotation');
    AppStorage.setOrCreate('LinkDeskFileAnnotationActive', FileTransferClient.hasAnnotation());
  }

  static foreground(): void {
    FileTransferClient.inForeground = true;
    IncomingFileNotifications.setForeground(true);
    FileTransferClient.clearPolling();
    const context = FileTransferClient.context;
    if (context) {
      try { preferences.removePreferencesFromCacheSync(context, 'ink_bridge_connection'); } catch (_) {}
      const pending = FileTransferClient.saved('fileTransferAnnotation');
      if (!pending && FileTransferClient.pending) void RoundTripLiveViewController.stop();
      FileTransferClient.pending = pending;
      AppStorage.setOrCreate('LinkDeskFileAnnotationActive', pending.length > 0);
    }
    void FileTransferClient.refresh();
    FileTransferClient.timer = setInterval(() => { void FileTransferClient.refresh(); }, 3500);
  }

  static background(): void {
    FileTransferClient.inForeground = false;
    IncomingFileNotifications.setForeground(false);
    FileTransferClient.updateBackgroundPolling();
  }

  private static updateBackgroundPolling(): void {
    FileTransferClient.clearPolling();
    if (IncomingFileNotifications.listening()) {
      FileTransferClient.timer = setInterval(() => { void FileTransferClient.refresh(); }, 5000);
    }
  }

  static destroy(): void {
    FileTransferClient.clearPolling();
    IncomingFileNotifications.destroy();
    FileTransferClient.context = undefined;
  }

  private static clearPolling(): void {
    clearInterval(FileTransferClient.timer);
    FileTransferClient.timer = -1;
  }

  static async setNotifications(enabled: boolean): Promise<void> {
    if (enabled) {
      const known = AppStorage.get<IncomingFile[]>('LinkDeskIncomingFiles') ?? [];
      await IncomingFileNotifications.enable(known.map((file: IncomingFile) => file.id));
      await FileTransferClient.refresh();
    } else {
      await IncomingFileNotifications.disable();
    }
  }

  private static store(context: common.Context | undefined = FileTransferClient.context): preferences.Preferences | undefined {
    if (!context) return undefined;
    return preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
  }

  private static saved(key: string, context?: common.Context): string {
    try { return (FileTransferClient.store(context)?.getSync(key, '') as string) || ''; } catch (_) { return ''; }
  }

  private static save(key: string, value: string, context?: common.Context): void {
    try {
      const store = FileTransferClient.store(context);
      store?.putSync(key, value);
      store?.flushSync();
    } catch (_) {}
  }

  private static room(context?: common.Context): string {
    const room = FileTransferClient.saved('room', context);
    if (!/^[A-Z0-9]{6}$/.test(room)) throw new Error('请先在 LinkDesk 配对 Mac');
    return room;
  }

  private static knownWireless(context?: common.Context): string[] {
    const host = FileTransferClient.saved('host', context).trim();
    const savedRoutes = FileTransferClient.saved('fileTransferWireless', context).split(',');
    const fromPairing = /^[a-zA-Z0-9.:-]+$/.test(host) && host !== '127.0.0.1' && host !== 'localhost'
      ? `http://${host.includes(':') ? '[' + host + ']' : host}:3210` : '';
    return Array.from(new Set([fromPairing, ...savedRoutes].filter((item: string) =>
      item !== USB && /^http:\/\/(?:[A-Za-z0-9.-]+|\[[A-Fa-f0-9:]+\]):3210$/.test(item))));
  }

  private static fetch(client: http.HttpRequest, origin: string, path: string, options: http.HttpRequestOptions,
    context?: common.Context, name?: string, annotationID?: string): Promise<http.HttpResponse> {
    if (origin === USB) return client.request(origin + path, options);
    if (!context) return Promise.reject(new Error('secure-pairing-required'));
    return SecureFilePeer.request(client, origin, path, path.split('/')[3], options, context, name, annotationID);
  }

  private static async tryOrigins(origins: string[], path: string, options: http.HttpRequestOptions,
    context?: common.Context, name?: string, annotationID?: string): Promise<http.HttpResponse | undefined> {
    let rejected: http.HttpResponse | undefined;
    for (const origin of origins) {
      const client = http.createHttp();
      try {
        if (options.method === http.RequestMethod.PUT) {
          const inbox = path.slice(0, path.indexOf('/mac/')) + '/tablet';
          const pair = await FileTransferClient.fetch(client, origin, inbox, {
            method: http.RequestMethod.GET, connectTimeout: 800, readTimeout: 1200
          }, context);
          if (pair.responseCode === 401) rejected = pair;
          if (pair.responseCode !== 200) continue;
        }
        let response = await FileTransferClient.fetch(client, origin, path, options, context, name, annotationID);
        if (response.responseCode === 409 && options.method === http.RequestMethod.PUT) {
          // A lost USB response can leave the same upload finishing on the Mac.
          await new Promise<void>((resolve) => { setTimeout(resolve, 200); });
          response = await FileTransferClient.fetch(client, origin, path, options, context, name, annotationID);
        }
        if (response.responseCode === 401) { rejected = response; continue; }
        if ([404, 409, 500, 502, 503].includes(response.responseCode)) continue;
        FileTransferClient.relayPrefix = origin;
        return response;
      } catch (_) {
        // The ID stays the same on Wi-Fi even if USB was disconnected during the upload.
      } finally { client.destroy(); }
    }
    return rejected;
  }

  private static async request(path: string, options: http.HttpRequestOptions,
    context: common.Context | undefined = FileTransferClient.context, name?: string, annotationID?: string):
    Promise<http.HttpResponse> {
    const room = path.split('/')[3];
    const hasPairing = context ? SecureFilePeer.hasPairing(context, room) : false;
    const wireless = FileTransferClient.knownWireless(context);
    const preferWiFi = FileTransferClient.saved('connectionPreference', context) === 'wifi';
    const tried = preferWiFi ? wireless : [USB, ...wireless];
    const response = await FileTransferClient.tryOrigins(tried, path, options, context, name, annotationID);
    if (response && response.responseCode !== 401) return response;
    if (context && hasPairing && Date.now() - FileTransferClient.lastDiscovery > 8000) {
      FileTransferClient.lastDiscovery = Date.now();
      const origin = await FileTransferClient.discoverWireless(context, room);
      if (origin && !tried.includes(origin)) {
        const found = await FileTransferClient.tryOrigins([origin], path, options, context, name, annotationID);
        if (found && found.responseCode !== 401) {
          FileTransferClient.save('fileTransferWireless', origin, context);
          return found;
        }
      }
    }
    if (!hasPairing || response?.responseCode === 401) {
      throw new Error(Strings.secureFilePairingRequired);
    }
    throw new Error('连不上 Mac，请检查 LinkDesk、USB 或同一 Wi-Fi');
  }

  private static async discoverWireless(context: common.Context, room: string): Promise<string> {
    try {
      const service = mdns.createDiscoveryService(context, '_inkbridge._tcp');
      return await new Promise<string>((resolve) => {
        let finished = false;
        const finish = (origin: string): void => {
          if (finished) return;
          finished = true;
          clearTimeout(timer);
          try { service.off('serviceFound', found); } catch (_) {}
          try { service.stopSearchingMDNS(); } catch (_) {}
          resolve(origin);
        };
        const found = (item: mdns.LocalServiceInfo): void => {
          if (item.serviceName !== 'InkBridge-' + room) return;
          void mdns.resolveLocalService(context, item).then((resolved: mdns.LocalServiceInfo) => {
            const host = resolved.host?.address?.trim() ?? '';
            if (resolved.port !== 3210 || !/^[a-zA-Z0-9.:-]+$/.test(host)) return;
            finish('http://' + (host.includes(':') ? '[' + host + ']' : host) + ':3210');
          }).catch(() => {});
        };
        const timer = setTimeout(() => finish(''), 1400);
        try {
          service.on('serviceFound', found);
          service.startSearchingMDNS();
        } catch (_) { finish(''); }
      });
    } catch (_) { return ''; }
  }

  private static async rememberWireless(): Promise<void> {
    if (!FileTransferClient.relayPrefix || Date.now() - FileTransferClient.routesCheckedAt < 30000) return;
    const client = http.createHttp();
    try {
      const response = await client.request(FileTransferClient.relayPrefix + '/config', {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 850, readTimeout: 1500
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') return;
      const config = JSON.parse(response.result) as RelayConfiguration;
      FileTransferClient.save('fileTransferWireless', config.urls.join(','));
      FileTransferClient.routesCheckedAt = Date.now();
    } catch (_) {} finally { client.destroy(); }
  }

  private static status(text: string): void {
    AppStorage.setOrCreate('LinkDeskFileStatus', text);
  }

  private static async readInbox(): Promise<IncomingFile[]> {
    const response = await FileTransferClient.request('/api/files/' + FileTransferClient.room() + '/tablet', {
      method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
      connectTimeout: 850, readTimeout: 2000
    });
    if (response.responseCode !== 200 || typeof response.result !== 'string') {
      throw new Error('暂时无法读取 Mac 的待接收文件');
    }
    return JSON.parse(response.result) as IncomingFile[];
  }

  static async refresh(): Promise<void> {
    if (FileTransferClient.checking) return;
    FileTransferClient.checking = true;
    try {
      const files = await FileTransferClient.readInbox();
      const known = AppStorage.get<IncomingFile[]>('LinkDeskIncomingFiles') ?? [];
      if (JSON.stringify(known) !== JSON.stringify(files)) {
        AppStorage.setOrCreate('LinkDeskIncomingFiles', files);
        if (FileTransferClient.inForeground && files.length > known.length &&
          AppStorage.get<boolean>('LinkDeskFileNoticeEnabled') !== true) {
          try { promptAction.showToast({ message: '收到文件，请在 LinkDesk 打开「文件传送」' }); } catch (_) {}
        }
      }
      await IncomingFileNotifications.update(files);
      await FileTransferClient.rememberWireless();
    } catch (_) { IncomingFileNotifications.connectionUnavailable(); }
    finally { FileTransferClient.checking = false; }
  }

  static async receiveFromNotification(id: string, action: string): Promise<void> {
    if (!id) return;
    try {
      const item = (await FileTransferClient.readInbox()).find((file: IncomingFile) => file.id === id);
      if (item) await FileTransferClient.receive(item, false, action === 'open');
      else FileTransferClient.status('此文件已保存或已从 Mac 移除');
    } catch (error) {
      FileTransferClient.status((error as Error).message || '暂时无法接收文件');
    }
  }

  static hasAnnotation(): boolean { return FileTransferClient.pending.length > 0; }

  static finishAnnotation(): void {
    FileTransferClient.setAnnotation('');
    void RoundTripLiveViewController.stop();
  }

  private static setAnnotation(id: string): void {
    FileTransferClient.pending = id;
    FileTransferClient.save('fileTransferAnnotation', id);
    AppStorage.setOrCreate('LinkDeskFileAnnotationActive', id.length > 0);
  }

  static hasLegacyAnnotation(context?: common.Context): boolean {
    return FileTransferClient.saved('roundTripId', context).length > 0;
  }

  static annotationFor(context: common.Context, uris: string[]): string {
    if (uris.length !== 1) return '';
    try {
      return /\.pdf$/i.test(new fileUri.FileUri(uris[0]).name) ?
        FileTransferClient.saved('fileTransferAnnotation', context) : '';
    } catch (_) { return ''; }
  }

  static validSources(uris: string[]): string[] {
    return Array.from(new Set(uris)).filter((uri: string) =>
      uri.startsWith('file://') || uri.startsWith('datashare://'));
  }

  static async sharedSources(want: Want): Promise<string[]> {
    const uris: string[] = [];
    try {
      const share = await systemShare.getSharedData(want);
      for (const item of share.getRecords()) {
        if (item.uri) uris.push(item.uri);
      }
    } catch (_) {}
    if (!uris.length) {
      const stream = want.parameters?.[wantConstant.Params.PARAMS_STREAM];
      if (typeof stream === 'string') uris.push(stream);
      else if (Array.isArray(stream)) {
        for (const uri of stream as string[]) if (typeof uri === 'string') uris.push(uri);
      }
      if (!uris.length && want.uri) uris.push(want.uri);
    }
    return FileTransferClient.validSources(uris);
  }


  static async selectFiles(): Promise<void> {
    const context = FileTransferClient.context;
    if (!context) return;
    try {
      const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 9 });
      await FileTransferClient.sendShared(uris);
    } catch (_) {}
  }

  static async sendShared(uris: string[]): Promise<void> {
    const context = FileTransferClient.context;
    if (!context) return;
    const local = FileTransferClient.validSources(uris);
    let annotationID = FileTransferClient.annotationFor(context, local);
    if (annotationID) {
      try {
        const selection = await promptAction.showDialog({
          title: '发送 PDF 到 Mac',
          message: '要把此文件作为当前批注任务的副本回传吗？',
          buttons: [{ text: '发送普通文件', color: '#4273BF' }, { text: '回传批注副本', color: '#4273BF' }]
        });
        if (selection.index !== 1) annotationID = '';
      } catch (_) { return; }
    }
    const result = await FileTransferClient.sendFiles(context, local, annotationID, FileTransferClient.status);
    if (annotationID && result.sent > 0) FileTransferClient.finishAnnotation();
    FileTransferClient.status(result.message);
    promptAction.showToast({ message: result.message });
  }

  static async sendFiles(context: common.Context, uris: string[], annotationID: string,
    progress: (message: string) => void): Promise<SendResult> {
    if (!uris.length) return { sent: 0, message: '共享内容中没有可发送的文件' };
    if (FileTransferClient.sending) return { sent: 0, message: '文件正在发送，请稍后再试' };
    FileTransferClient.sending = true;
    let sent = 0;
    let lastError = '';
    try {
      const room = FileTransferClient.room(context);
      for (let index = 0; index < uris.length; index++) {
        try {
          progress('正在发送 ' + (index + 1) + '/' + uris.length);
          await FileTransferClient.upload(room, uris[index], annotationID, context);
          sent += 1;
        } catch (error) { lastError = (error as Error).message || '发送失败'; }
      }
      if (annotationID && sent > 0 && FileTransferClient.saved('fileTransferAnnotation', context) === annotationID) {
        FileTransferClient.save('fileTransferAnnotation', '', context);
      }
    } catch (error) { lastError = (error as Error).message || '发送失败'; }
    finally { FileTransferClient.sending = false; }
    const transport = FileTransferClient.relayPrefix === USB ? 'USB' : 'Wi‑Fi';
    return { sent: sent, message: sent === uris.length ? '已发送到 Mac（' + transport + '）' :
      '已发送 ' + sent + '/' + uris.length + ' · ' + lastError };
  }

  private static async upload(room: string, uri: string, annotationID: string, context: common.Context): Promise<void> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer;
    try {
      const stat = await fileIo.stat(file.fd);
      if (!stat.isFile()) throw new Error('请选择普通文件');
      if (stat.size > LIMIT) throw new Error('单个文件最大 64 MB');
      buffer = new ArrayBuffer(stat.size);
      if (stat.size > 0 && await fileIo.read(file.fd, buffer) !== stat.size) throw new Error('文件读取不完整');
    } finally { await fileIo.close(file); }
    const id = util.generateRandomUUID().toLowerCase();
    const name = new fileUri.FileUri(uri).name;
    const response = await FileTransferClient.request(`/api/files/${room}/mac/${id}`, {
      method: http.RequestMethod.PUT,
      header: {
        'content-type': 'application/octet-stream',
        'x-file-name': encodeURIComponent(name),
        'x-annotation-id': annotationID
      },
      extraData: buffer,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 1000, readTimeout: 120000
    }, context, encodeURIComponent(name), annotationID);
    if (response.responseCode !== 200 && response.responseCode !== 201) {
      throw new Error(response.responseCode === 429 ? 'Mac 待接收文件太多' : `发送失败（${response.responseCode}）`);
    }
  }

  static async receive(item: IncomingFile, annotate: boolean, open: boolean = false): Promise<void> {
    const context = FileTransferClient.context;
    if (!context || FileTransferClient.receiving) return;
    if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(item.id)) {
      FileTransferClient.status('文件识别码无效');
      return;
    }
    if (annotate && FileTransferClient.pending && FileTransferClient.pending !== item.id) {
      promptAction.showToast({ message: '请先从系统分享菜单回传当前的批注任务，或选择「另存」' });
      return;
    }
    FileTransferClient.receiving = true;
    try {
      const room = FileTransferClient.room();
      const route = `/api/files/${room}/tablet/${item.id}`;
      const name = item.name.replace(/[\\/:*?"<>|]/g, '_');
      if (!name || name === '.' || name === '..') throw new Error('文件名无效');
      let uri: string;
      if (annotate || open) {
        const folder = (annotate ? context.filesDir + '/transfers/' :
          context.cacheDir + '/file-previews/') + item.id;
        if (!fileIo.accessSync(folder)) fileIo.mkdirSync(folder, true);
        uri = fileUri.getUriFromPath(`${folder}/${name}`);
      } else {
        const saved = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
        if (!saved.length) return;
        uri = saved[0];
      }
      FileTransferClient.status(`正在接收 · ${name}`);
      const response = await FileTransferClient.request(route, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 1000, readTimeout: 120000, maxLimit: LIMIT
      });
      if (response.responseCode !== 200) throw new Error(`下载失败（${response.responseCode}）`);
      const buffer = response.result as ArrayBuffer;
      if (!(buffer instanceof ArrayBuffer) || buffer.byteLength !== item.size) throw new Error('文件大小不一致');
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: new Uint8Array(buffer) });
      const digest = await md.digest();
      const hash = Array.from(digest.data).map((byte: number) => byte.toString(16).padStart(2, '0')).join('');
      if (hash !== item.sha256) throw new Error('文件校验失败');
      const file = await fileIo.open(uri, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        if (await fileIo.write(file.fd, buffer) !== buffer.byteLength) throw new Error('文件写入不完整');
      } finally { await fileIo.close(file); }
      if (open) {
        await FileTransferClient.openFile(context, uri, name);
        FileTransferClient.status('已打开 · ' + name + '，可继续另存');
        return;
      }
      if (annotate) {
        FileTransferClient.setAnnotation(item.id);
        try {
          await FileTransferClient.openNotes(context, uri);
        } catch (error) {
          FileTransferClient.finishAnnotation();
          throw new Error((error as Error).message || '无法打开华为笔记');
        }
      }
      const ack = await FileTransferClient.request(route, {
        method: http.RequestMethod.DELETE, connectTimeout: 1000, readTimeout: 3000
      });
      if (ack.responseCode !== 200) throw new Error('文件已保存，接收确认失败');
      FileTransferClient.status(annotate ? '批注后请从分享菜单选择 LinkDesk 回传' : `已保存 · ${name}`);
      void FileTransferClient.refresh();
    } catch (error) {
      FileTransferClient.status((error as Error).message || '接收失败');
    } finally { FileTransferClient.receiving = false; }
  }

  private static async openFile(context: common.UIAbilityContext, uri: string, name: string): Promise<void> {
    const extension = name.includes('.') ? name.slice(name.lastIndexOf('.')) : '';
    const type = extension ? uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(extension) : '';
    const mime = (type ? uniformTypeDescriptor.getTypeDescriptor(type).mimeTypes[0] : '') || 'application/octet-stream';
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData', uri: uri, type: mime,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      });
    } catch (_) {
      throw new Error('平板上没有可打开此文件的应用，可选择「另存」');
    }
  }

  private static async openNotes(context: common.UIAbilityContext, uri: string): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      bundleName: 'com.huawei.hmos.hinote',
      abilityName: 'HiNotePcMainAbility',
      type: 'com.adobe.pdf', uri: uri, flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    try {
      await context.startAbility(want);
    } catch (_) {
      await context.startAbility({
        action: 'ohos.want.action.viewData', type: 'application/pdf', uri: uri,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      });
    }
  }
}
