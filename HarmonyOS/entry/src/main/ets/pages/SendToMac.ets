import { UIExtensionContentSession, common, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { DT, Strings } from '../design/GeneratedDesign';
import { FileTransferClient } from '../roundtrip/FileTransferClient';

@Entry
@Component
struct SendToMac {
  @State private status: string = Strings.connectingToMac;
  @State private phase: string = 'sending';
  private session: UIExtensionContentSession | undefined;
  private context: common.UIExtensionContext | undefined;
  private uris: string[] = [];
  private annotationID: string = '';
  private legacy: boolean = false;
  private closeTimer: number = -1;

  aboutToAppear(): void {
    const storage = this.getUIContext().getSharedLocalStorage();
    this.session = storage?.get<UIExtensionContentSession>('shareSession');
    this.context = storage?.get<common.UIExtensionContext>('shareContext');
    this.uris = storage?.get<string[]>('shareURIs') ?? [];
    if (!this.context) { this.status = Strings.shareOpenFailed; this.phase = 'finished'; return; }
    this.annotationID = FileTransferClient.annotationFor(this.context, this.uris);
    if (!this.annotationID && this.uris.length === 1 && FileTransferClient.hasLegacyAnnotation(this.context)) {
      try { this.legacy = /\.pdf$/i.test(new fileUri.FileUri(this.uris[0]).name); } catch (_) {}
    }
    if (this.annotationID || this.legacy) {
      this.status = Strings.shareAnnotationChoice;
      this.phase = 'annotation';
    } else {
      void this.send(false);
    }
  }

  aboutToDisappear(): void { clearTimeout(this.closeTimer); }

  private async send(annotated: boolean): Promise<void> {
    if (!this.context) return;
    this.phase = 'sending';
    this.status = Strings.connectingToMac;
    if (annotated && this.legacy) {
      try {
        await this.context.startAbility({
          bundleName: 'com.zhekuan.linkdesk', abilityName: 'EntryAbility',
          action: 'ohos.want.action.viewData', type: 'application/pdf', uri: this.uris[0],
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
        });
        this.close();
      } catch (_) {
        this.status = Strings.shareAnnotationFailed;
        this.phase = 'finished';
      }
      return;
    }
    const result = await FileTransferClient.sendFiles(this.context, this.uris, annotated ? this.annotationID : '',
      (message: string): void => { this.status = message; });
    this.status = result.message;
    this.phase = 'finished';
    if (result.sent > 0 && result.sent === this.uris.length) {
      this.closeTimer = setTimeout(() => { this.close(); }, 850);
    }
  }

  private close(): void {
    void this.session?.terminateSelfWithResult({ resultCode: systemShare.ShareAbilityResultCode.CLOSE }).catch(() => {});
  }

  build() {
    Column({ space: 18 }) {
      Text(Strings.shareToMac).fontSize(DT.fontSection).fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      if (this.phase === 'sending') { LoadingProgress().width(DT.spacingS28).height(DT.spacingS28) }
      Text(this.status).fontSize(DT.fontBody).textAlign(TextAlign.Center)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      if (this.phase === 'annotation') {
        Button(Strings.shareAnnotatedCopy).width('100%').onClick(() => { void this.send(true); })
        Button(Strings.shareRegularFile, { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%')
          .onClick(() => { void this.send(false); })
      } else if (this.phase === 'finished') {
        Button(Strings.done, { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.close())
      }
    }.width('100%').height('100%').padding(DT.spacingS24).justifyContent(FlexAlign.Center)
      .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
