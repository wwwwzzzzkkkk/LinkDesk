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
      Column({ space: 13 }) {
        Row() {
          Stack() { Image(mark).width(26).height(26).objectFit(ImageFit.Contain) }
            .width(46).height(46).backgroundColor((this.darkMode ? '#20314D' : '#F0F5FB')).borderRadius(14)
          Blank()
          Text('↗').fontSize(20).fontColor('#9CAABF')
        }.width('100%')
        Text(title).fontSize(21).fontWeight(FontWeight.Medium).fontColor((this.darkMode ? '#E8EEF8' : '#152441')).width('100%')
        Text(description).fontSize(13).fontColor((this.darkMode ? '#96A6BE' : '#728096')).lineHeight(20).width('100%')
      }.alignItems(HorizontalAlign.Start).padding(24).width('100%')
    }.width('100%').height(185).backgroundColor((this.darkMode ? '#182337' : '#FFFFFF')).borderRadius(22)
      .border({ width: 1, color: (this.darkMode ? '#2B3B55' : '#E5EBF3'), radius: 22 }).clip(true)
      .onClick(() => this.open(mode)).accessibilityText(title + '，' + description)
  }

  @Builder home() {
    Scroll() {
      Column({ space: 26 }) {
        Row({ space: 12 }) {
          Image($r('app.media.app_icon')).width(43).height(43).borderRadius(12)
          Column({ space: 3 }) {
            Text('LinkDesk').fontSize(24).fontWeight(FontWeight.Bold).fontColor((this.darkMode ? '#E8EEF8' : '#152441'))
            Text('你的跨屏工作空间').fontSize(12).fontColor((this.darkMode ? '#96A6BE' : '#728096'))
          }.alignItems(HorizontalAlign.Start)
          Blank()
          this.themeControl()
        }.width('100%')

        Column({ space: 14 }) {
          Text('让灵感，在屏幕间流动。').fontSize(this.compact ? 29 : 37)
            .fontWeight(FontWeight.Bold).fontColor((this.darkMode ? '#E8EEF8' : '#152441')).width('100%')
          Text('扩展桌面，随手批注，或一起构思。\n选择一个工作空间，开始你的跨屏协作。')
            .fontSize(15).fontColor((this.darkMode ? '#A5B4CA' : '#64758D')).lineHeight(25).width('100%')
          Row({ space: 8 }) {
            Text('USB 高清连接').fontSize(11).fontColor('#326FB7')
              .padding({ left: 11, right: 11, top: 6, bottom: 6 }).backgroundColor('#E3EFFC').borderRadius(12)
            Text('Wi-Fi 自由书写').fontSize(11).fontColor('#288C79')
              .padding({ left: 11, right: 11, top: 6, bottom: 6 }).backgroundColor('#DFF3ED').borderRadius(12)
          }.width('100%').margin({ top: 4 })
        }.padding(30).width('100%').alignItems(HorizontalAlign.Start).borderRadius(24)
          .linearGradient({ angle: 125, colors: [[(this.darkMode ? '#1B2D49' : '#E9F1FE'), 0], [(this.darkMode ? '#163C3A' : '#E6F4EF'), 1]] })

        GridRow({ columns: this.compact ? 1 : 2, gutter: 16 }) {
          GridCol() { this.workspaceCard('扩展屏幕', '把平板变成 Mac 的第二块屏幕，也能连接扬声器和麦克风。', $r('app.media.workspace_display'), 'display', '#4F8FF7') }
          GridCol() { this.workspaceCard('PDF 批注', '用手写笔阅读与批注，两端同步，也能发送到华为笔记。', $r('app.media.workspace_pdf'), 'pdf', '#4F8FF7') }
          GridCol() { this.workspaceCard('实时白板', '无限画布，压感书写。让每一个想法都有展开的空间。', $r('app.media.workspace_whiteboard'), 'whiteboard', '#2EAA8E') }
          GridCol() { this.workspaceCard('平板投屏', '把平板上的笔记与演示，通过 USB 带到 Mac。', $r('app.media.workspace_mirror'), 'mirror', '#2EAA8E') }
        }.width('100%')
        Text('扩展屏幕与投屏使用 USB；PDF 和白板也支持 Wi-Fi。')
          .fontSize(12).fontColor((this.darkMode ? '#96A6BE' : '#728096')).textAlign(TextAlign.Center).width('100%')
      }.width('100%').constraintSize({ maxWidth: 1000 }).padding(this.compact ? 22 : 36)
    }.width('100%').height('100%').backgroundColor((this.darkMode ? '#0E1523' : '#F4F6FA'))
  }

  @Builder themeControl() {
    Button(this.themePreference === 'automatic' ? '◐  跟随系统' : this.darkMode ? '☾  深色' : '☼  浅色')
      .fontSize(12).height(34).fontColor(this.darkMode ? '#C8D5E8' : '#526781')
      .backgroundColor(this.darkMode ? '#223149' : '#E8EDF5').borderRadius(17)
      .accessibilityText('切换外观，两端同步')
      .bindMenu([
        { value: '跟随 Mac 系统', action: () => LinkDeskTheme.select('automatic') },
        { value: '浅色', action: () => LinkDeskTheme.select('light') },
        { value: '深色', action: () => LinkDeskTheme.select('dark') }
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
    }.width('100%').height('100%').backgroundColor((this.darkMode ? '#0E1523' : '#F4F6FA'))
      .onAreaChange((_old: Area, current: Area) => { this.compact = Number(current.width) < 700; })
  }
}
