import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { DisplayContext } from '../DisplayContext';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    try {
      const mainWindow = stage.getMainWindowSync();
      DisplayContext.windowId = mainWindow.getWindowProperties().id;
      Promise.all([
        mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE),
        mainWindow.setWindowLayoutFullScreen(true),
        mainWindow.setWindowSystemBarEnable([]),
        mainWindow.setWindowKeepScreenOn(true)
      ]).catch(() => {
        console.warn('LinkDesk: some window preferences could not be applied');
      }).finally(() => { stage.loadContent('pages/Index'); });
    } catch (_) {
      stage.loadContent('pages/Index');
    }
  }
}
