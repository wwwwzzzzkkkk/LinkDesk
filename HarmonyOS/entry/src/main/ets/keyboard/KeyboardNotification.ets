import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';
import { Strings } from '../design/GeneratedDesign';
import notification from '@ohos.notification';
import { BusinessError } from '@kit.BasicServicesKit';

export class KeyboardNotification {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static enabled: boolean = false;
  private static lastState: string = '';
  static start(context: common.UIAbilityContext): void {
    KeyboardNotification.context = context;
    try { KeyboardNotification.enabled = preferences.getPreferencesSync(context, { name: 'linkdesk_keyboard' }).getSync('notification', false) as boolean; } catch (_) {}
    AppStorage.setOrCreate('LinkDeskKeyboardNotification', KeyboardNotification.enabled);
  }
  static async enable(): Promise<void> {
    const context = KeyboardNotification.context;
    if (!context) return;
    try {
      await notificationManager.requestEnableNotification(context);
      if (!await notificationManager.isNotificationEnabled()) return;
      KeyboardNotification.enabled = true;
      const store = preferences.getPreferencesSync(context, { name: 'linkdesk_keyboard' });
      store.putSync('notification', true); store.flushSync();
      AppStorage.setOrCreate('LinkDeskKeyboardNotification', true);
      KeyboardNotification.lastState = ''; await KeyboardNotification.update();
    } catch (_) { AppStorage.setOrCreate('LinkDeskKeyboardNoticeError', true); }
  }
  static async disable(): Promise<void> {
    KeyboardNotification.enabled = false;
    AppStorage.setOrCreate('LinkDeskKeyboardNotification', false);
    try {
      if (KeyboardNotification.context) {
        const store = preferences.getPreferencesSync(KeyboardNotification.context, { name: 'linkdesk_keyboard' });
        store.putSync('notification', false); store.flushSync();
      }
      await notificationManager.cancel(24837);
    } catch (_) {}
    KeyboardNotification.lastState = '';
  }
  static async update(): Promise<void> {
    if (!KeyboardNotification.enabled) return;
    const state = AppStorage.get<string>('LinkDeskKeyboardState') ?? 'disconnected';
    if (state === KeyboardNotification.lastState) return;
    KeyboardNotification.lastState = state;
    try {
      if (state !== 'ready') { await notificationManager.cancel(24837); return; }
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'com.zhekuan.linkdesk', abilityName: 'EntryAbility', parameters: { linkdeskKeyboard: true } }],
        actionType: wantAgent.OperationType.START_ABILITIES, requestCode: 24837,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await notificationManager.publish({ id: 24837,
        slotType: notification.SlotType.SERVICE_INFORMATION,
        content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: Strings.keyboardTitle, text: Strings.keyboardNotificationHint } },
        wantAgent: agent, isAlertOnce: true, tapDismissed: false
      });
      AppStorage.setOrCreate('LinkDeskKeyboardNoticeError', false);
    } catch (error) { console.error(`KEYBOARD_NOTICE code=${(error as BusinessError).code}`); KeyboardNotification.lastState = ''; AppStorage.setOrCreate('LinkDeskKeyboardNoticeError', true); }
  }
}
