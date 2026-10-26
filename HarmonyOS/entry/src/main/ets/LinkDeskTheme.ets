import { DT } from './design/GeneratedDesign';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { window } from '@kit.ArkUI';
import { KeyboardClient } from './keyboard/KeyboardClient';

interface SharedTheme {
  preference: string;
  appearance: string;
  revision: number;
}
interface ThemeUpdate {
  preference: string;
  appearance: string;
  baseRevision: number;
}

export class LinkDeskTheme {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static host: string = '127.0.0.1';
  private static room: string = 'GLOBAL';
  private static timer: number = -1;
  private static busy: boolean = false;
  private static pending: string = '';
  private static generation: number = 0;

  static start(context: common.UIAbilityContext): void {
    LinkDeskTheme.context = context;
    let selected = 'automatic';
    let dark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try {
      const store = preferences.getPreferencesSync(context, { name: 'linkdesk_theme' });
      selected = store.getSync('preference', 'automatic') as string;
      LinkDeskTheme.pending = store.getSync('pending', '') as string;
      dark = store.getSync('dark', dark) as boolean;
    } catch (_) {}
    LinkDeskTheme.apply(selected, dark);
    if (LinkDeskTheme.timer >= 0) clearInterval(LinkDeskTheme.timer);
    LinkDeskTheme.timer = setInterval(() => { void LinkDeskTheme.synchronize(); }, 1000);
  }
  static configure(host: string, room: string): void {
    if (!host || !/^[A-Z0-9]{6}$/.test(room)) return;
    if (host === LinkDeskTheme.host && room === LinkDeskTheme.room) return;
    LinkDeskTheme.host = host;
    KeyboardClient.configure(host);
    LinkDeskTheme.room = room;
    LinkDeskTheme.generation += 1;
    void LinkDeskTheme.synchronize();
  }
  static stop(): void {
    if (LinkDeskTheme.timer >= 0) clearInterval(LinkDeskTheme.timer);
    LinkDeskTheme.timer = -1;
    LinkDeskTheme.generation += 1;
    LinkDeskTheme.context = undefined;
  }
  static select(value: string): void {
    if (value !== 'automatic' && value !== 'light' && value !== 'dark') return;
    const dark = value === 'automatic' ? (AppStorage.get<boolean>('LinkDeskDark') ?? false) : value === 'dark';
    LinkDeskTheme.pending = value;
    LinkDeskTheme.savePending();
    LinkDeskTheme.apply(value, dark);
    void LinkDeskTheme.synchronize();
  }
  private static apply(selected: string, dark: boolean): void {
    const changed = AppStorage.get<string>('LinkDeskThemePreference') !== selected || AppStorage.get<boolean>('LinkDeskDark') !== dark;
    AppStorage.setOrCreate('LinkDeskThemePreference', selected);
    AppStorage.setOrCreate('LinkDeskDark', dark);
    if (!changed || !LinkDeskTheme.context) return;
    try {
      LinkDeskTheme.context.getApplicationContext().setColorMode(dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      const store = preferences.getPreferencesSync(LinkDeskTheme.context, { name: 'linkdesk_theme' });
      store.putSync('preference', selected); store.putSync('dark', dark); store.flushSync();
      LinkDeskTheme.refreshWindowStyle();
    } catch (_) {}
  }
  private static savePending(): void {
    if (!LinkDeskTheme.context) return;
    try {
      const store = preferences.getPreferencesSync(LinkDeskTheme.context, { name: 'linkdesk_theme' });
      store.putSync('pending', LinkDeskTheme.pending); store.flushSync();
    } catch (_) {}
  }
  static refreshWindowStyle(): void {
    if (!LinkDeskTheme.context) return;
    const dark = AppStorage.get<boolean>('LinkDeskDark') ?? false;
      void window.getLastWindow(LinkDeskTheme.context).then((main: window.Window) => {
        return main.setWindowSystemBarProperties({
          statusBarColor: DT.canvas(dark), navigationBarColor: DT.canvas(dark),
          isStatusBarLightIcon: dark, isNavigationBarLightIcon: dark,
          statusBarContentColor: DT.text(dark),
          navigationBarContentColor: DT.text(dark)
        });
      }).catch(() => {});
  }
  private static async synchronize(): Promise<void> {
    if (LinkDeskTheme.busy || !LinkDeskTheme.host || !LinkDeskTheme.room) return;
    LinkDeskTheme.busy = true;
    const generation = LinkDeskTheme.generation;
    const address = LinkDeskTheme.host.includes(':') ? `[${LinkDeskTheme.host}]` : LinkDeskTheme.host;
    const url = `http://${address}:3210/api/appearance`;
    const request = http.createHttp();
    try {
      const response = await request.request(url, { method: http.RequestMethod.GET, connectTimeout: 1500, readTimeout: 1500 });
      if (response.responseCode !== 200 || generation !== LinkDeskTheme.generation) return;
      AppStorage.setOrCreate('LinkDeskRelayReachable', true);
      AppStorage.setOrCreate('LinkDeskTransport', LinkDeskTheme.host === '127.0.0.1' ? 'usb' : 'wifi');
      const shared = JSON.parse(response.result as string) as SharedTheme;
      if (!['automatic', 'light', 'dark'].includes(shared.preference) || !['light', 'dark'].includes(shared.appearance)) return;
      if (LinkDeskTheme.pending) {
        const selected = LinkDeskTheme.pending;
        const value: ThemeUpdate = {
          preference: selected,
          appearance: selected === 'automatic' ? shared.appearance : selected,
          baseRevision: shared.revision
        };
        const writer = http.createHttp();
        try {
          const result = await writer.request(url, {
            method: http.RequestMethod.PUT, header: { 'Content-Type': 'application/json' },
            extraData: JSON.stringify(value), connectTimeout: 1500, readTimeout: 1500
          });
          if (result.responseCode === 200 && generation === LinkDeskTheme.generation && LinkDeskTheme.pending === selected) {
            LinkDeskTheme.pending = '';
            LinkDeskTheme.savePending();
            const updated = JSON.parse(result.result as string) as SharedTheme;
            LinkDeskTheme.apply(updated.preference, updated.appearance === 'dark');
          }
        } finally { writer.destroy(); }
      } else if (shared.revision > 0) {
        LinkDeskTheme.apply(shared.preference, shared.appearance === 'dark');
      }
    } catch (_) { AppStorage.setOrCreate('LinkDeskRelayReachable', false); /* Keep the last appearance while reconnecting. */ }
    finally { request.destroy(); LinkDeskTheme.busy = false; }
  }
}
