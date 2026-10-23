import { PlatformUI } from '../design/PlatformUI';
import { DT, Strings } from '../design/GeneratedDesign';
import { LinkDeskTheme } from '../LinkDeskTheme';
import linkdesk from 'liblinkdesk.so';
import screenMirror from 'libscreenmirror.so';
import { DisplayContext } from '../DisplayContext';
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { wantConstant } from '@kit.AbilityKit';
import { RoundTripBridge } from '../roundtrip/RoundTripBridge';

export default class EntryAbility extends UIAbility {
  onForeground(): void { DisplayContext.foreground = true; PlatformUI.foreground(); }

  onBackground(): void {
    DisplayContext.foreground = false;
    PlatformUI.background();
    DisplayContext.microphoneAllowed = false;
    linkdesk.setMicrophoneRequested(false);
    linkdesk.setMicrophoneEnabled(false);
  }
  onDestroy(): void {
    PlatformUI.stop();
    LinkDeskTheme.stop();
    linkdesk.setMicrophoneRequested(false);
    linkdesk.setMicrophoneEnabled(false);
    linkdesk.stop();
    screenMirror.stop();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Strings.language = this.context.config.language ?? 'zh-Hans';
    PlatformUI.start();
    LinkDeskTheme.start(this.context);
    this.handleIncomingWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleIncomingWant(want);
  }

  private handleIncomingWant(want: Want): void {
    const reviewOrientation = want.parameters?.linkdeskUIReviewOrientation;
    if (typeof reviewOrientation === 'string') PlatformUI.reviewOrientation(reviewOrientation);
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
      PlatformUI.bind(mainWindow);
      Promise.all([
        mainWindow.setWindowLayoutFullScreen(false),
        mainWindow.setPreferredOrientation(PlatformUI.preferredOrientation()),
        mainWindow.setWindowKeepScreenOn(true),
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: DT.clear(false),
          navigationBarColor: DT.clear(false),
          isStatusBarLightIcon: false,
          isNavigationBarLightIcon: false,
          statusBarContentColor: DT.text(false),
          navigationBarContentColor: DT.secondary(false)
        })
      ]).finally(() => this.loadMainPage(windowStage));
    } catch (_) {
      this.loadMainPage(windowStage);
    }
  }
}
