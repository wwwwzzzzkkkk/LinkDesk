import { accessibility } from '@kit.AccessibilityKit';
import { window } from '@kit.ArkUI';
import { DT } from './GeneratedDesign';
import { LinkDeskTheme } from '../LinkDeskTheme';

// Presentation only. No transport, decoder or theme persistence changes.
export class PlatformUI {
  private static main: window.Window | undefined = undefined;
  private static receiver: boolean = false;
  private static barQueue: Promise<void> = Promise.resolve();
  private static motionChanged(enabled: boolean): void { AppStorage.setOrCreate('LinkDeskReduceMotion', enabled); }
  static start(): void {
    PlatformUI.refreshMotion();
    try { accessibility.onAnimationReduceStateChange(PlatformUI.motionChanged); } catch (_) {}
  }
  static refreshMotion(): void {
    try { PlatformUI.motionChanged(accessibility.isAnimationReduceEnabledSync()); }
    catch (_) { PlatformUI.motionChanged(true); }
  }
  static stop(): void {
    try { accessibility.offAnimationReduceStateChange(PlatformUI.motionChanged); } catch (_) {}
  }
  static bind(main: window.Window): void { PlatformUI.main = main; }
  static setReceiver(active: boolean): void { PlatformUI.receiver = active; PlatformUI.applyBars(active); }
  static foreground(): void { PlatformUI.refreshMotion(); PlatformUI.applyBars(PlatformUI.receiver); }
  static background(): void { PlatformUI.applyBars(false); }
  private static applyBars(immersive: boolean): void {
    // Serialize transitions so an old enter completion cannot override a later exit.
    PlatformUI.barQueue = PlatformUI.barQueue.then(async () => {
      const main = PlatformUI.main;
      if (!main) return;
      try {
        await main.setWindowLayoutFullScreen(immersive);
        const bars: Array<'status' | 'navigation'> = immersive ? [] : ['status', 'navigation'];
        await main.setWindowSystemBarEnable(bars);
        await main.setSpecificSystemBarEnabled('navigationIndicator', !immersive, false);
      } catch (_) { /* Split/floating windows may retain system-owned bars. */ }
      if (!immersive) LinkDeskTheme.refreshWindowStyle();
    }).catch(() => {});
  }
}
