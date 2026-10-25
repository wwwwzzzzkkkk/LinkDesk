import { accessibility } from '@kit.AccessibilityKit';
import { window } from '@kit.ArkUI';
import { DT } from './GeneratedDesign';
import { LinkDeskTheme } from '../LinkDeskTheme';
import { hilog } from '@kit.PerformanceAnalysisKit';

// Presentation only. No transport, decoder or theme persistence changes.
export class PlatformUI {
  private static main: window.Window | undefined = undefined;
  private static orientation: window.Orientation = window.Orientation.AUTO_ROTATION;
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
  static preferredOrientation(): window.Orientation { return PlatformUI.orientation; }
  static reviewOrientation(value: string): void {
    if (value !== 'portrait' && value !== 'landscape' && value !== 'automatic') return;
    PlatformUI.orientation = value === 'portrait' ? window.Orientation.PORTRAIT : value === 'landscape' ? window.Orientation.LANDSCAPE : window.Orientation.AUTO_ROTATION;
    try { void PlatformUI.main?.setPreferredOrientation(PlatformUI.orientation).catch(() => {}); } catch (_) {}
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
      // Each operation is independent: unsupported navigation/status configuration
      // must not skip the gesture indicator request. Layout alone does not hide it.
      try { main.setImmersiveModeEnabledState(immersive); }
      catch (error) { hilog.warn(0x3301, 'LinkDesk', 'IMMERSIVE layout %{public}s', JSON.stringify(error)); }
      try { await main.setSpecificSystemBarEnabled('navigationIndicator', !immersive, false); }
      catch (error) { hilog.warn(0x3301, 'LinkDesk', 'IMMERSIVE indicator %{public}s', JSON.stringify(error)); }
      try {
        const bars: Array<'status' | 'navigation'> = immersive ? [] : ['status', 'navigation'];
        await main.setWindowSystemBarEnable(bars);
      } catch (error) { hilog.warn(0x3301, 'LinkDesk', 'IMMERSIVE bars %{public}s', JSON.stringify(error)); }
      hilog.info(0x3301, 'LinkDesk', 'IMMERSIVE applied=%{public}s layout=%{public}s', String(immersive), String(main.getImmersiveModeEnabledState()));
      if (!immersive) LinkDeskTheme.refreshWindowStyle();
    }).catch(() => {});
  }
}
