import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import notification from '@ohos.notification';
import { startIndependentTask } from '../BackgroundTask';

export interface FileNoticeItem {
  id: string;
  name: string;
}

export interface FileNoticeAction {
  id: string;
  action: string;
}

const STORE_NAME = 'linkdesk_incoming_file_notifications';
const SETUP_NOTICE_ID = 34101;
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

export class IncomingFileNotifications {
  private static context: common.UIAbilityContext | undefined;
  private static token = '';
  private static preference: preferences.Preferences | undefined;
  private static enabled = false;
  private static backgroundId = -1;
  private static starting = false;
  private static foreground = false;
  private static lastAttempt = 0;
  private static lastReachable = 0;
  private static offline = false;
  private static preferenceRevision = 0;
  private static announced: Set<string> = new Set();
  private static onLeaseChanged: () => void = () => {};

  private static readonly cancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (IncomingFileNotifications.backgroundId !== info.id) return;
    IncomingFileNotifications.backgroundId = -1;
    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
      info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION) {
      void IncomingFileNotifications.disable();
    } else {
      IncomingFileNotifications.showStatus('系统已暂停后台收件，回到 LinkDesk 后继续');
      IncomingFileNotifications.onLeaseChanged();
    }
  };

  static setup(context: common.UIAbilityContext, onLeaseChanged: () => void): void {
    IncomingFileNotifications.context = context;
    IncomingFileNotifications.lastReachable = Date.now();
    IncomingFileNotifications.onLeaseChanged = onLeaseChanged;
    try {
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      IncomingFileNotifications.preference = store;
      IncomingFileNotifications.enabled = store.getSync('enabled', false) as boolean;
      IncomingFileNotifications.token = store.getSync('actionToken', '') as string;
      if (!IncomingFileNotifications.token) {
        IncomingFileNotifications.token = util.generateRandomUUID();
        store.putSync('actionToken', IncomingFileNotifications.token);
        store.flushSync();
      }
      const seen = JSON.parse(store.getSync('announced', '[]') as string) as string[];
      IncomingFileNotifications.announced = new Set(seen.filter((id: string) => UUID.test(id)));
    } catch (_) {}
    IncomingFileNotifications.publishPreference();
    try { backgroundTaskManager.on('continuousTaskCancel', IncomingFileNotifications.cancelled); } catch (_) {}
  }

  static setForeground(foreground: boolean): void {
    IncomingFileNotifications.foreground = foreground;
    if (foreground) IncomingFileNotifications.lastAttempt = 0;
  }

  static listening(): boolean {
    return IncomingFileNotifications.enabled && IncomingFileNotifications.backgroundId >= 0;
  }

  static destroy(): void {
    try { backgroundTaskManager.off('continuousTaskCancel', IncomingFileNotifications.cancelled); } catch (_) {}
    IncomingFileNotifications.foreground = false;
    void IncomingFileNotifications.releaseLease();
    IncomingFileNotifications.context = undefined;
  }

  static async enable(existing: string[]): Promise<void> {
    const context = IncomingFileNotifications.context;
    if (!context || IncomingFileNotifications.enabled) return;
    const revision = ++IncomingFileNotifications.preferenceRevision;
    try {
      if (!await notificationManager.isNotificationEnabled()) await notificationManager.requestEnableNotification(context);
      const permission = await notificationManager.isNotificationEnabled();
      if (revision !== IncomingFileNotifications.preferenceRevision) return;
      if (!permission) {
        IncomingFileNotifications.showStatus('请在系统设置中允许 LinkDesk 通知');
        return;
      }
      // Files already listed when the switch is enabled remain in the inbox.
      IncomingFileNotifications.announced = new Set(existing.filter((id: string) => UUID.test(id)));
      IncomingFileNotifications.saveAnnounced();
      IncomingFileNotifications.enabled = true;
      IncomingFileNotifications.publishPreference();
      IncomingFileNotifications.showStatus('等待连接已配对的 Mac');
      IncomingFileNotifications.lastAttempt = 0;
    } catch (_) {
      IncomingFileNotifications.showStatus('无法开启收件通知，请检查系统通知设置');
    }
  }

  static async disable(): Promise<void> {
    ++IncomingFileNotifications.preferenceRevision;
    IncomingFileNotifications.enabled = false;
    IncomingFileNotifications.publishPreference();
    IncomingFileNotifications.showStatus('');
    const seen = Array.from(IncomingFileNotifications.announced);
    IncomingFileNotifications.announced.clear();
    IncomingFileNotifications.saveAnnounced();
    for (const id of seen) {
      await notificationManager.cancel(IncomingFileNotifications.idFor(id)).catch(() => {});
    }
    await IncomingFileNotifications.releaseLease();
  }

  private static publishPreference(): void {
    AppStorage.setOrCreate('LinkDeskFileNoticeEnabled', IncomingFileNotifications.enabled);
    try {
      IncomingFileNotifications.preference?.putSync('enabled', IncomingFileNotifications.enabled);
      IncomingFileNotifications.preference?.flushSync();
    } catch (_) {}
  }

  private static showStatus(message: string): void {
    AppStorage.setOrCreate('LinkDeskFileNoticeStatus', message);
  }

  private static saveAnnounced(): void {
    try {
      IncomingFileNotifications.preference?.putSync('announced', JSON.stringify(Array.from(IncomingFileNotifications.announced)));
      IncomingFileNotifications.preference?.flushSync();
    } catch (_) {}
  }

  private static async ensureLease(): Promise<void> {
    const context = IncomingFileNotifications.context;
    if (!context || !IncomingFileNotifications.enabled || !IncomingFileNotifications.foreground ||
      IncomingFileNotifications.listening() || IncomingFileNotifications.starting ||
      Date.now() - IncomingFileNotifications.lastAttempt < 15000) return;
    IncomingFileNotifications.lastAttempt = Date.now();
    IncomingFileNotifications.starting = true;
    try {
      const agent = await IncomingFileNotifications.agent('', 'inbox', SETUP_NOTICE_ID);
      if (!IncomingFileNotifications.enabled || !IncomingFileNotifications.foreground) return;
      const id = await startIndependentTask(context, backgroundTaskManager.BackgroundTaskMode.MODE_MULTI_DEVICE_CONNECTION, agent);
      if (!IncomingFileNotifications.enabled || IncomingFileNotifications.context !== context) {
        await backgroundTaskManager.stopBackgroundRunning(context, id);
        return;
      }
      IncomingFileNotifications.backgroundId = id;
      IncomingFileNotifications.onLeaseChanged();
      IncomingFileNotifications.showStatus('后台接收中 · USB 优先');
    } catch (_) {
      IncomingFileNotifications.showStatus('后台接收暂不可用，打开 LinkDesk 时会接收文件');
    } finally { IncomingFileNotifications.starting = false; }
  }

  static connectionUnavailable(): void {
    if (!IncomingFileNotifications.enabled) return;
    const elapsed = Date.now() - IncomingFileNotifications.lastReachable;
    if (elapsed >= 5000 || AppStorage.get<boolean>('LinkDeskMacUnavailable') === true) {
      IncomingFileNotifications.offline = true;
      IncomingFileNotifications.showStatus('Mac 已断开 · 正在等待重连');
    }
    if (IncomingFileNotifications.listening() && elapsed >= 90000) {
      IncomingFileNotifications.showStatus('Mac 已离线 · 返回 LinkDesk 后继续接收');
      void IncomingFileNotifications.releaseLease();
    }
  }

  private static async releaseLease(): Promise<void> {
    const id = IncomingFileNotifications.backgroundId;
    const context = IncomingFileNotifications.context;
    IncomingFileNotifications.backgroundId = -1;
    IncomingFileNotifications.onLeaseChanged();
    if (context && id >= 0) await backgroundTaskManager.stopBackgroundRunning(context, id).catch(() => {});
  }

  private static idFor(id: string): number {
    return 40000 + Number.parseInt(id.slice(0, 7), 16);
  }

  private static async agent(id: string, action: string, requestCode: number): Promise<WantAgent> {
    return wantAgent.getWantAgent({
      wants: [{
        bundleName: 'com.zhekuan.linkdesk', abilityName: 'EntryAbility',
        parameters: { linkdeskFileId: id, linkdeskFileAction: action,
          linkdeskFileToken: IncomingFileNotifications.token }
      }],
      actionType: wantAgent.OperationType.START_ABILITIES, requestCode: requestCode,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  static actionFor(want: Want): FileNoticeAction | undefined {
    const id = want.parameters?.linkdeskFileId;
    const action = want.parameters?.linkdeskFileAction;
    if (!IncomingFileNotifications.token || want.parameters?.linkdeskFileToken !== IncomingFileNotifications.token ||
      typeof id !== 'string' || typeof action !== 'string') return undefined;
    if (action === 'inbox' && !id) return { id: id, action: action };
    if (UUID.test(id) && (action === 'open' || action === 'save')) return { id: id, action: action };
    return undefined;
  }

  static async update(items: FileNoticeItem[]): Promise<void> {
    const macOnline = AppStorage.get<boolean>('LinkDeskMacUnavailable') !== true;
    if (macOnline) IncomingFileNotifications.lastReachable = Date.now();
    if (!IncomingFileNotifications.enabled || !IncomingFileNotifications.token) return;
    if (!await notificationManager.isNotificationEnabled().catch(() => false)) {
      IncomingFileNotifications.showStatus('请在系统设置中允许 LinkDesk 通知');
      await IncomingFileNotifications.releaseLease();
      return;
    }
    if (macOnline) await IncomingFileNotifications.ensureLease();
    if (macOnline && IncomingFileNotifications.offline) {
      IncomingFileNotifications.offline = false;
      if (IncomingFileNotifications.listening()) IncomingFileNotifications.showStatus('后台接收中 · USB 优先');
    }
    if (!macOnline) IncomingFileNotifications.connectionUnavailable();

    let changed = false;
    const active = new Set(items.map((item: FileNoticeItem) => item.id));
    for (const id of IncomingFileNotifications.announced) {
      if (!active.has(id)) {
        await notificationManager.cancel(IncomingFileNotifications.idFor(id)).catch(() => {});
        IncomingFileNotifications.announced.delete(id);
        changed = true;
      }
    }
    for (const item of items) {
      if (!IncomingFileNotifications.enabled || !UUID.test(item.id) ||
        IncomingFileNotifications.announced.has(item.id)) continue;
      const id = IncomingFileNotifications.idFor(item.id);
      try {
        const open = await IncomingFileNotifications.agent(item.id, 'open', id * 2);
        const save = await IncomingFileNotifications.agent(item.id, 'save', id * 2 + 1);
        if (!IncomingFileNotifications.enabled) break;
        await notificationManager.publish({
          id: id, slotType: notification.SlotType.SOCIAL_COMMUNICATION,
          content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: { title: 'LinkDesk · Mac 发来文件', text: item.name } },
          wantAgent: open, actionButtons: [{ title: '打开', wantAgent: open }, { title: '另存为', wantAgent: save }],
          isAlertOnce: true, tapDismissed: false
        });
        if (IncomingFileNotifications.enabled) {
          IncomingFileNotifications.announced.add(item.id);
          changed = true;
        } else {
          await notificationManager.cancel(id).catch(() => {});
        }
      } catch (_) {}
    }
    if (changed) IncomingFileNotifications.saveAnnounced();
  }
}
