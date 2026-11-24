import { PlatformUI } from '../design/PlatformUI';
import { DT, Strings } from '../design/GeneratedDesign';
import { LinkDeskTheme } from '../LinkDeskTheme';
import linkdesk from 'liblinkdesk.so';
import screenMirror from 'libscreenmirror.so';
import { DisplayContext } from '../DisplayContext';
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { wantConstant } from '@kit.AbilityKit';
import { FileNoticeAction, IncomingFileNotifications } from '../roundtrip/IncomingFileNotifications';
import { FileTransferClient } from '../roundtrip/FileTransferClient';
import { WirelessMicrophone } from '../microphone/WirelessMicrophone';
import { RoundTripBridge } from '../roundtrip/RoundTripBridge';
import { KeyboardClient } from '../keyboard/KeyboardClient';
import { KeyboardNotification } from '../keyboard/KeyboardNotification';

export default class EntryAbility extends UIAbility {
  private pendingShare: Want | undefined;
  private pendingFileNotice: FileNoticeAction | undefined;
  private micAction: string = '';
  private isForeground: boolean = false;

  onForeground(): void {
    DisplayContext.foreground = true;
    this.isForeground = true;
    WirelessMicrophone.shared.onForeground();
    PlatformUI.foreground();
    LinkDeskTheme.refreshConnection();
    KeyboardClient.refresh();
    void KeyboardNotification.update();
    FileTransferClient.foreground();
    if (this.pendingFileNotice) {
      const notice = this.pendingFileNotice;
      this.pendingFileNotice = undefined;
      this.openFileNotice(notice);
    }
    if (this.micAction) {
      const action = this.micAction;
      this.micAction = '';
      if (action === 'start') void WirelessMicrophone.shared.start();
      else void WirelessMicrophone.shared.stop();
    }
    if (this.pendingShare) {
      const want = this.pendingShare;
      this.pendingShare = undefined;
      void this.handleSharedFiles(want);
    }
  }

  onBackground(): void {
    DisplayContext.foreground = false;
    this.isForeground = false;
    WirelessMicrophone.shared.onBackground();
    KeyboardClient.background();
    PlatformUI.background();
    FileTransferClient.background();
    DisplayContext.microphoneAllowed = false;
    linkdesk.setMicrophoneRequested(false);
    linkdesk.setMicrophoneEnabled(false);
  }
  onDestroy(): void {
    KeyboardClient.stop();
    PlatformUI.stop();
    WirelessMicrophone.shared.destroy();
    FileTransferClient.destroy();
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
    FileTransferClient.start(this.context);
    KeyboardClient.start(this.context);
    WirelessMicrophone.shared.setup(this.context);
    KeyboardNotification.start(this.context);
    this.handleIncomingWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleIncomingWant(want);
  }

  private handleIncomingWant(want: Want): void {
    const notice = IncomingFileNotifications.actionFor(want);
    if (notice) {
      if (this.isForeground) this.openFileNotice(notice);
      else this.pendingFileNotice = notice;
    }
    const mic = want.parameters?.wirelessMicrophone;
    const token = want.parameters?.wirelessMicrophoneToken;
    if ((mic === 'start' || mic === 'stop') && typeof token === 'string' &&
      WirelessMicrophone.shared.acceptsNotification(token)) {
      if (mic === 'stop') void WirelessMicrophone.shared.stop();
      else if (this.isForeground) void WirelessMicrophone.shared.start();
      else this.micAction = 'start';
    }
    if (want.parameters?.linkdeskKeyboard === true) {
      KeyboardClient.refresh();
      AppStorage.setOrCreate('LinkDeskKeyboardVisible', true);
    }
    const reviewOrientation = want.parameters?.linkdeskUIReviewOrientation;
    if (typeof reviewOrientation === 'string') PlatformUI.reviewOrientation(reviewOrientation);
    if (want.action === 'ohos.want.action.sendData' || want.action === 'ohos.want.action.sendMultipleData') {
      if (DisplayContext.foreground) void this.handleSharedFiles(want);
      else this.pendingShare = want;
    } else {
      this.handleSharedPDF(want);
    }
    const action = want.parameters?.liveViewAction;
    if (typeof action === 'string') {
      AppStorage.setOrCreate('LinkDeskDestination', 'ink');
      RoundTripBridge.submitLiveViewAction(action);
    }
  }

  private openFileNotice(notice: FileNoticeAction): void {
    AppStorage.setOrCreate('LinkDeskFilesVisible', true);
    void FileTransferClient.receiveFromNotification(notice.id, notice.action);
  }

  private async handleSharedFiles(want: Want): Promise<void> {
    const uris = await FileTransferClient.sharedSources(want);
    if (uris.length === 1 && !FileTransferClient.hasAnnotation() &&
      FileTransferClient.hasLegacyAnnotation() && (want.type === 'application/pdf' || /\.pdf$/i.test(uris[0]))) {
      AppStorage.setOrCreate('LinkDeskDestination', 'ink');
      RoundTripBridge.submit(uris[0]);
      return;
    }
    await FileTransferClient.sendShared(uris);
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
