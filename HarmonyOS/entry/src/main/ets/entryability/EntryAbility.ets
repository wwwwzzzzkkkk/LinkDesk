import { LinkDeskTheme } from '../LinkDeskTheme';
import linkdesk from 'liblinkdesk.so';
import screenMirror from 'libscreenmirror.so';
import { DisplayContext } from '../DisplayContext';
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { wantConstant } from '@kit.AbilityKit';
import { RoundTripBridge } from '../roundtrip/RoundTripBridge';

export default class EntryAbility extends UIAbility {
  onBackground(): void {
    DisplayContext.microphoneAllowed = false;
    linkdesk.setMicrophoneEnabled(false);
  }
  onDestroy(): void {
    LinkDeskTheme.stop();
    linkdesk.setMicrophoneEnabled(false);
    linkdesk.stop();
    screenMirror.stop();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LinkDeskTheme.start(this.context);
    this.handleIncomingWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleIncomingWant(want);
  }

  private handleIncomingWant(want: Want): void {
    this.handleSharedPDF(want);
    const action = want.parameters?.liveViewAction;
    if (typeof action === 'string') {
      AppStorage.setOrCreate('LinkDeskDestination', 'ink');
      RoundTripBridge.submitLiveViewAction(action);
    }
  }

  private handleSharedPDF(want: Want): void {
    let uri = want.uri ?? '';
    if (!uri && want.parameters) {
      const stream = want.parameters[wantConstant.Params.PARAMS_STREAM];
      if (typeof stream === 'string') {
        uri = stream;
      } else if (Array.isArray(stream) && stream.length > 0 && typeof stream[0] === 'string') {
        uri = stream[0] as string;
      }
    }
    if (uri && (want.type === 'application/pdf' || uri.toLowerCase().includes('.pdf'))) {
      AppStorage.setOrCreate('LinkDeskDestination', 'ink');
      RoundTripBridge.submit(uri);
    }
  }

  private loadMainPage(windowStage: window.WindowStage): void {
    try {
      windowStage.loadContent('pages/Index').then(() => LinkDeskTheme.refreshWindowStyle()).catch(() => {});
    } catch (_) {}
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      DisplayContext.windowId = mainWindow.getWindowProperties().id;
      Promise.all([
        mainWindow.setWindowLayoutFullScreen(true),
        mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE),
        mainWindow.setWindowKeepScreenOn(true),
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          isStatusBarLightIcon: false,
          isNavigationBarLightIcon: false,
          statusBarContentColor: '#1a2230',
          navigationBarContentColor: '#384252'
        })
      ]).finally(() => this.loadMainPage(windowStage));
    } catch (_) {
      this.loadMainPage(windowStage);
    }
  }
}
