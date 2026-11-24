import { DT, Strings, ConnectionState, ConnectionPresentation } from './GeneratedDesign';

export function isConnected(state: ConnectionState): boolean {
  return state === ConnectionState.usbConnected || state === ConnectionState.waitingForMode ||
    state === ConnectionState.working;
}

@Component
export struct ConnectionPill {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @Prop @Watch('stateChanged') state: ConnectionState = ConnectionState.disconnected;
  @Prop home: boolean = false;
  @State private glow: number = 0;
  private timer: number = -1;
  private mounted: boolean = false;

  aboutToAppear(): void { this.mounted = true; }
  aboutToDisappear(): void { this.mounted = false; clearTimeout(this.timer); }
  private stateChanged(): void {
    clearTimeout(this.timer);
    this.glow = 0;
    if (!this.mounted || this.reduceMotion || this.state === ConnectionState.disconnected) return;
    this.timer = setTimeout(() => {
      this.glow = DT.opacityWorkspacePulse;
      this.timer = setTimeout(() => { this.glow = 0; }, DT.durationWorkspacePulseIn);
    }, DT.durationWorkspaceExit);
  }

  private title(): string {
    return this.home && isConnected(this.state) ? Strings.stateConnected : ConnectionPresentation.title(this.state);
  }

  private color(): string {
    return this.home && isConnected(this.state) ? DT.connectionBlue(this.dark) :
      ConnectionPresentation.color(this.state, this.dark);
  }

  build() {
    Row({ space: DT.spacingS8 }) {
      Stack() {
        Circle().width(DT.spacingS16).height(DT.spacingS16)
          .fill(this.color()).opacity(this.reduceMotion ? 0 : this.glow)
          .animation({ duration: this.glow > 0 ? DT.durationWorkspacePulseIn : DT.durationWorkspacePulseOut, curve: DT.curveWorkspace() })
        Circle().width(DT.layoutStatusDot).height(DT.layoutStatusDot).fill(this.color())
      }.width(DT.spacingS16).height(DT.spacingS16)
      Text(this.title()).fontSize(DT.fontCaption).fontColor(DT.text(this.dark))
    }.padding({ left: DT.spacingS16, right: DT.spacingS16 })
      .constraintSize({ minHeight: DT.spacingS40 })
      .backgroundColor(DT.workspaceSurface(this.dark))
      .border({ width: DT.layoutStroke, color: DT.workspaceRim(this.dark), radius: DT.radiusLarge })
      .borderRadius(DT.radiusLarge).accessibilityText(Strings.connectionStatus + ': ' + this.title())
  }
}

@Component
export struct PageHeader {
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop state: ConnectionState = ConnectionState.disconnected;
  @Prop home: boolean = false;
  @State private narrow: boolean = false;
  @Builder titles() {
    Column({ space: DT.spacingS8 }) {
      Text(this.title).fontSize(DT.fontTitle).fontWeight(FontWeight.Bold).fontColor(DT.text(this.dark)).width('100%')
      Text(this.subtitle).fontSize(DT.fontBody).fontColor(DT.secondary(this.dark)).width('100%')
    }.alignItems(HorizontalAlign.Start).layoutWeight(this.narrow ? 0 : 1)
  }
  build() {
    Flex({ direction: this.narrow ? FlexDirection.Column : FlexDirection.Row, alignItems: this.narrow ? ItemAlign.Start : ItemAlign.Center }) {
      this.titles()
      ConnectionPill({ state: this.state, home: this.home }).margin({ top: this.narrow ? DT.spacingS16 : DT.spacingS0 })
    }.width('100%').constraintSize({ minHeight: DT.layoutHeaderMinHeight })
      .onAreaChange((_old: Area, current: Area) => { this.narrow = Number(current.width) < DT.layoutSingleColumnBreakpoint; })
  }
}

@Component
export struct WorkspaceRim {
  @StorageLink('LinkDeskDark') @Watch('refresh') dark: boolean = false;
  @StorageLink('LinkDeskReduceMotion') @Watch('refresh') reduceMotion: boolean = false;
  @StorageLink('LinkDeskForeground') @Watch('refresh') foreground: boolean = true;
  @Prop rimWidth: number = 0;
  @Prop rimHeight: number = 0;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private visible: boolean = false;
  private timer: number = -1;

  aboutToDisappear(): void {
    this.ready = false;
    clearInterval(this.timer);
  }

  private refresh(): void {
    clearInterval(this.timer);
    if (!this.ready || !this.visible) return;
    this.draw();
    if (this.foreground && !this.reduceMotion) this.timer = setInterval(() => this.draw(), 33);
  }

  private draw(): void {
    const context = this.context;
    const width = context.width;
    const height = context.height;
    const inset = 3;
    if (width <= inset * 2 || height <= inset * 2) return;
    const turn = this.reduceMotion ? 0 : (Date.now() % 5000) / 5000;
    const gradient = context.createConicGradient(turn * 2 * Math.PI, width / 2, height / 2);
    const blue = DT.connectionBlue(this.dark);
    const transparentBlue = DT.connectionBlueTrace(this.dark);
    gradient.addColorStop(0, transparentBlue);
    gradient.addColorStop(0.48, transparentBlue);
    gradient.addColorStop(0.66, blue);
    gradient.addColorStop(0.79, DT.connectionCyan(this.dark));
    gradient.addColorStop(0.88, DT.connectionViolet(this.dark));
    gradient.addColorStop(1, transparentBlue);

    context.clearRect(0, 0, width, height);
    context.beginPath();
    context.roundRect(inset, inset, width - 2 * inset, height - 2 * inset, DT.radiusLarge - inset);
    context.strokeStyle = gradient;
    context.globalAlpha = 0.36;
    context.lineWidth = DT.layoutConnectionRimGlow;
    context.shadowBlur = DT.layoutConnectionRimGlow;
    context.shadowColor = blue;
    context.stroke();
    context.shadowBlur = 0;
    context.globalAlpha = 1;
    context.lineWidth = DT.layoutConnectionRimStroke;
    context.stroke();
  }

  build() {
    Canvas(this.context).width(this.rimWidth).height(this.rimHeight)
      .onReady(() => { this.ready = true; this.refresh(); })
      .onAreaChange(() => { if (this.ready) this.draw(); })
      .onVisibleAreaChange([0, 0.01], (visible: boolean, ratio: number) => {
        this.visible = visible && ratio > 0;
        this.refresh();
      })
      .position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
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
        .backgroundColor(DT.workspaceAccent(this.dark)).fontColor(DT.workspaceOnAccent(this.dark))
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
