import { DT, Strings, ConnectionState, ConnectionPresentation } from './GeneratedDesign';

@Component
export struct ConnectionPill {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @Prop state: ConnectionState = ConnectionState.disconnected;
  build() {
    Row({ space: DT.spacingS8 }) {
      Circle().width(DT.layoutStatusDot).height(DT.layoutStatusDot).fill(ConnectionPresentation.color(this.state, this.dark))
      Text(ConnectionPresentation.title(this.state)).fontSize(DT.fontCaption).fontColor(DT.text(this.dark))
    }.padding({ left: DT.spacingS12, right: DT.spacingS12 })
      .constraintSize({ minHeight: DT.layoutTouchTarget })
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .borderRadius(DT.radiusLarge).accessibilityText(Strings.connectionStatus + ': ' + ConnectionPresentation.title(this.state))
  }
}

@Component
export struct PageHeader {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop state: ConnectionState = ConnectionState.disconnected;
  @State private narrow: boolean = false;
  @Builder titles() {
    Column({ space: DT.spacingS8 }) {
      Text(this.title).fontSize(DT.fontTitle).fontWeight(FontWeight.Bold).fontColor(DT.text(this.dark)).width('100%')
      Text(this.subtitle).fontSize(DT.fontBody).fontColor(DT.secondary(this.dark)).width('100%')
    }.alignItems(HorizontalAlign.Start).layoutWeight(this.narrow ? 0 : 1)
  }
  build() {
    Flex({ direction: this.narrow ? FlexDirection.Column : FlexDirection.Row, alignItems: ItemAlign.Start }) {
      this.titles()
      ConnectionPill({ state: this.state }).margin({ top: this.narrow ? DT.spacingS12 : DT.spacingS0 })
    }.width('100%').constraintSize({ minHeight: DT.layoutHeaderMinHeight })
      .onAreaChange((_old: Area, current: Area) => { this.narrow = Number(current.width) < DT.layoutSingleColumnBreakpoint; })
  }
}

@Component
export struct EmptyState {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @Prop icon: Resource = DT.iconPdf(false);
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop actionTitle: string = '';
  @Prop disabled: boolean = false;
  action: () => void = () => {};
  build() {
    Column({ space: DT.spacingS16 }) {
      Stack() { Image(this.icon).width(DT.layoutIcon).height(DT.layoutIcon) }
        .width(DT.layoutIconTile).height(DT.layoutIconTile).backgroundColor(DT.accentSoft(this.dark)).borderRadius(DT.radiusSmall)
      Text(this.title).fontSize(DT.fontSection).fontWeight(FontWeight.Bold).fontColor(DT.text(this.dark)).textAlign(TextAlign.Center)
      Text(this.message).fontSize(DT.fontBody).fontColor(DT.secondary(this.dark)).textAlign(TextAlign.Center)
      Button(this.actionTitle).constraintSize({ minHeight: DT.layoutTouchTarget, minWidth: DT.layoutTouchTarget })
        .backgroundColor(DT.accent(this.dark)).fontColor(DT.onAccent(this.dark)).borderRadius(DT.radiusSmall)
        .enabled(!this.disabled).onClick(() => this.action())
    }.width('100%').padding(DT.spacingS24)
  }
}

@Builder function noControl() {}

@Component
export struct SettingRow {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @Prop title: string = '';
  @Prop detail: string = '';
  @BuilderParam control: () => void = noControl;
  @State private narrow: boolean = false;
  @Builder labels() {
    Column({ space: DT.spacingS4 }) {
      Text(this.title).fontSize(DT.fontBody).fontWeight(FontWeight.Medium).fontColor(DT.text(this.dark)).width('100%')
      Text(this.detail).fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark)).width('100%')
    }.alignItems(HorizontalAlign.Start)
  }
  build() {
    Column() {
      if (this.narrow) {
        Column({ space: DT.spacingS12 }) { this.labels(); this.control() }.alignItems(HorizontalAlign.Start).width('100%')
      } else {
        Row({ space: DT.spacingS16 }) {
          Column() { this.labels() }.layoutWeight(1)
          this.control()
        }.width('100%')
      }
    }.width('100%').constraintSize({ minHeight: DT.layoutSettingRowTablet })
      .onAreaChange((_old: Area, current: Area) => { this.narrow = Number(current.width) < DT.layoutSingleColumnBreakpoint; })
  }
}
