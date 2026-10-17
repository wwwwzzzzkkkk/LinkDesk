import { DT, Strings, ConnectionState, ConnectionPresentation } from '../design/GeneratedDesign';
import { LinkDeskTheme } from '../LinkDeskTheme';
import { InkWorkspace } from './InkWorkspace';
import { DesktopReceiver } from './DesktopReceiver';

@Entry
@Component
struct Index {
  @StorageLink('LinkDeskDark') darkMode: boolean = false;
  @StorageLink('LinkDeskThemePreference') themePreference: string = 'automatic';
  @StorageLink('LinkDeskDestination') destination: string = 'home';
  @State private requestedMode: string = 'pdf';
  @State private activation: number = 0;
  @State private compact: boolean = false;

  private open(mode: string): void {
    this.requestedMode = mode;
    this.activation += 1;
    this.destination = mode === 'display' ? 'display' : 'ink';
  }

  @Builder workspaceCard(title: string, description: string, mark: Resource, mode: string, accent: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: DT.spacingS12 }) {
        Row() {
          Stack() { Image(mark).width(DT.spacingS24).height(DT.spacingS24).objectFit(ImageFit.Contain) }
            .width(DT.spacingS48).height(DT.spacingS48).backgroundColor(DT.control(this.darkMode)).borderRadius(DT.radiusSmall)
          Blank()
          Text('↗').fontSize(DT.fontLabel).fontColor(DT.secondary(this.darkMode))
        }.width('100%')
        Text(title).fontSize(DT.fontLabel).fontWeight(FontWeight.Medium).fontColor(DT.text(this.darkMode)).width('100%')
        Text(description).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode)).lineHeight(DT.spacingS20).width('100%')
      }.alignItems(HorizontalAlign.Start).padding(DT.spacingS24).width('100%')
    }.width('100%').height(DT.dimensionsD184).backgroundColor(DT.surface(this.darkMode)).borderRadius(DT.radiusMedium)
      .border({ width: DT.layoutStroke, color: DT.border(this.darkMode), radius: DT.radiusSmall }).clip(true)
      .onClick(() => this.open(mode)).accessibilityText(title + '，' + description)
  }

  @Builder home() {
    Scroll() {
      Column({ space: DT.spacingS24 }) {
        Row({ space: DT.spacingS12 }) {
          Image($r('app.media.app_icon')).width(DT.spacingS44).height(DT.spacingS44).borderRadius(DT.radiusSmall)
          Column({ space: DT.spacingS4 }) {
            Text(Strings.productName).fontSize(DT.fontSection).fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode))
            Text(Strings.productSubtitle).fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
          }.alignItems(HorizontalAlign.Start)
          Blank()
          this.themeControl()
        }.width('100%')

        Column({ space: DT.spacingS16 }) {
          Text(Strings.heroTitle).fontSize(this.compact ? 29 : 37)
            .fontWeight(FontWeight.Bold).fontColor(DT.text(this.darkMode)).width('100%')
          Text('扩展桌面，随手批注，或一起构思。\n选择一个工作空间，开始你的跨屏协作。')
            .fontSize(DT.fontBody).fontColor(DT.secondary(this.darkMode)).lineHeight(DT.spacingS24).width('100%')
          Row({ space: DT.spacingS8 }) {
            Text('USB 高清连接').fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
              .padding({ left: DT.spacingS12, right: DT.spacingS12, top: DT.spacingS8, bottom: DT.spacingS8 }).backgroundColor(DT.secondary(this.darkMode)).borderRadius(DT.radiusSmall)
            Text('Wi-Fi 自由书写').fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode))
              .padding({ left: DT.spacingS12, right: DT.spacingS12, top: DT.spacingS8, bottom: DT.spacingS8 }).backgroundColor(DT.secondary(this.darkMode)).borderRadius(DT.radiusSmall)
          }.width('100%').margin({ top: DT.spacingS4 })
        }.padding(DT.spacingS32).width('100%').alignItems(HorizontalAlign.Start).borderRadius(DT.radiusLarge)
          

        GridRow({ columns: this.compact ? 1 : 2, gutter: DT.spacingS16 }) {
          GridCol() { this.workspaceCard(Strings.displayTitle, '把平板变成 Mac 的第二块屏幕，也能连接扬声器和麦克风。', $r('app.media.workspace_display'), 'display', DT.accent(this.darkMode)) }
          GridCol() { this.workspaceCard(Strings.pdfTitle, '用手写笔阅读与批注，两端同步，也能发送到华为笔记。', $r('app.media.workspace_pdf'), 'pdf', DT.accent(this.darkMode)) }
          GridCol() { this.workspaceCard(Strings.whiteboardTitle, '无限画布，压感书写。让每一个想法都有展开的空间。', $r('app.media.workspace_whiteboard'), 'whiteboard', DT.success(this.darkMode)) }
          GridCol() { this.workspaceCard(Strings.mirrorTitle, '把平板上的笔记与演示，通过 USB 带到 Mac。', $r('app.media.workspace_mirror'), 'mirror', DT.success(this.darkMode)) }
        }.width('100%')
        Text('扩展屏幕与投屏使用 USB；PDF 和白板也支持 Wi-Fi。')
          .fontSize(DT.fontCaption).fontColor(DT.secondary(this.darkMode)).textAlign(TextAlign.Center).width('100%')
      }.width('100%').constraintSize({ maxWidth: DT.dimensionsD1000 }).padding(this.compact ? 22 : 36)
    }.width('100%').height('100%').backgroundColor(DT.canvas(this.darkMode))
  }

  @Builder themeControl() {
    Button(this.themePreference === 'automatic' ? Strings.themeAutomatic : this.darkMode ? Strings.themeDark : Strings.themeLight)
      .fontSize(DT.fontCaption).height(DT.spacingS32).fontColor(DT.secondary(this.darkMode))
      .backgroundColor(DT.control(this.darkMode)).borderRadius(DT.radiusMedium)
      .accessibilityText(Strings.themeAccessibility)
      .bindMenu([
        { value: Strings.themeAutomatic, action: () => LinkDeskTheme.select('automatic') },
        { value: Strings.themeLight, action: () => LinkDeskTheme.select('light') },
        { value: Strings.themeDark, action: () => LinkDeskTheme.select('dark') }
      ])
  }

  build() {
    Stack() {
      if (this.destination !== 'display') {
        // Keep the PDF bridge alive on the home screen for Huawei Notes returns.
        InkWorkspace({ requestedMode: this.requestedMode, activation: this.activation, onExit: () => { this.destination = 'home'; } })
          .visibility(this.destination === 'home' ? Visibility.Hidden : Visibility.Visible)
      }
      if (this.destination === 'home') { this.home() }
      if (this.destination === 'display') {
        DesktopReceiver({ onExit: () => { this.destination = 'home'; } })
      }
    }.width('100%').height('100%').backgroundColor(DT.canvas(this.darkMode))
      .onAreaChange((_old: Area, current: Area) => { this.compact = Number(current.width) < 700; })
  }
}
