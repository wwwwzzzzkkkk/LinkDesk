import { DT, Strings } from '../design/GeneratedDesign';
import { KeyboardClient } from './KeyboardClient';
import { KeyboardNotification } from './KeyboardNotification';
import { KeyboardKey } from './KeyboardKey';
import { KeyboardLayout, KeyboardKeySpec, KeyboardRowSpec } from './KeyboardLayout';
import { preferences } from '@kit.ArkData';
import inputMethod from '@ohos.inputMethod';

class HeldModifier {
  mask: number; time: number; used: boolean;
  constructor(mask: number, time: number, used: boolean = false) { this.mask = mask; this.time = time; this.used = used; }
}

@Component
export struct KeyboardPanel {
  @Prop @Watch('viewportChanged') viewportWidth: number = 960;
  @Prop @Watch('viewportChanged') viewportHeight: number = 640;
  @StorageLink('LinkDeskDark') dark: boolean = false;
  @StorageLink('LinkDeskKeyboardVisible') visible: boolean = false;
  @StorageLink('LinkDeskKeyboardState') @Watch('stateChanged') state: string = 'disconnected';
  @StorageLink('LinkDeskKeyboardTransport') transport: string = 'usb';
  @StorageLink('LinkDeskKeyboardNotification') notification: boolean = false;
  @StorageLink('LinkDeskKeyboardNoticeError') noticeError: boolean = false;
  @StorageLink('LinkDeskKeyboardCaps') caps: boolean = false;
  @StorageLink('LinkDeskKeyboardInputSource') inputSource: string = '';
  @StorageLink('LinkDeskKeyboardHapticAvailable') hapticAvailable: boolean = true;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @State private layout: string = 'dock';
  @State private profile: string = 'ANSI';
  @State private keyWidth: number = 80;
  @State private keyHeight: number = 52;
  @State private showFunctions: boolean = false;
  @State private extendedFunctions: boolean = false;
  @State private floatX: number = 0;
  @State private floatY: number = 0;
  private dragX: number = 0;
  private dragY: number = 0;
  private panelHeight: number = 420;
  @State private showPad: boolean = false;
  @State private settingsOpen: boolean = false;
  @State private haptics: boolean = false;
  @State private heldMask: number = 0;
  @State private armedMask: number = 0;
  @State private lockedMask: number = 0;
  @State private draft: string = '';
  @State private composing: boolean = false;
  @State private previewing: boolean = false;
  private held: Map<string, HeldModifier> = new Map();
  private lastTapMask: number = 0;
  private lastTapTime: number = 0;
  private store: preferences.Preferences | undefined = undefined;
  private orientation: string = '';
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    try {
      this.store = preferences.getPreferencesSync(this.getUIContext().getHostContext()!, { name: 'linkdesk_keyboard_layout' });
      const layout = this.store.getSync('layout', 'dock') as string;
      if (['dock', 'split', 'full', 'float'].includes(layout)) this.layout = layout;
      const profile = this.store.getSync('profile', 'ANSI') as string;
      if (['ANSI', 'ISO', 'JIS'].includes(profile)) this.profile = profile;
      this.showFunctions = this.store.getSync('functions', false) as boolean;
      this.extendedFunctions = this.store.getSync('extendedFunctions', false) as boolean;
      this.showPad = this.store.getSync('numberPad', false) as boolean;
      this.haptics = this.store.getSync('haptics', false) as boolean;
    } catch (_) {}
    this.loadSizing();
  }
  aboutToDisappear(): void { this.alive = false; this.releaseAll(); this.draft = ''; KeyboardClient.cancelPending(); }
  private orientationKey(): string { return this.viewportWidth >= this.viewportHeight ? 'landscape' : 'portrait'; }
  private loadSizing(): void {
    this.orientation = this.orientationKey();
    const prefix = `${this.layout}-${this.orientation}`;
    this.keyWidth = this.store?.getSync(`${prefix}-width`, this.layout === 'split' ? 56 : this.layout === 'float' ? 48 : 110) as number;
    this.floatX = Number(this.store?.getSync(`float-${this.orientation}-x`, 0)) || 0;
    this.floatY = Number(this.store?.getSync(`float-${this.orientation}-y`, 0)) || 0;
    this.keyHeight = this.store?.getSync(`${prefix}-height`, this.layout === 'full' ? 140 : 52) as number;
    if (!Number.isFinite(this.keyWidth)) this.keyWidth = 56;
    if (!Number.isFinite(this.keyHeight)) this.keyHeight = 52;
    this.keyWidth = Math.max(40, Math.min(110, this.keyWidth)); this.keyHeight = Math.max(44, Math.min(this.layout === 'full' ? 160 : 88, this.keyHeight));
  }
  private saveSizing(): void {
    try {
      const prefix = `${this.layout}-${this.orientationKey()}`;
      this.store?.putSync(`${prefix}-width`, this.keyWidth); this.store?.putSync(`${prefix}-height`, this.keyHeight);
      this.store?.putSync('layout', this.layout); this.store?.putSync('profile', this.profile);
      this.store?.putSync('functions', this.showFunctions); this.store?.putSync('extendedFunctions', this.extendedFunctions);
      this.store?.putSync(`float-${this.orientationKey()}-x`, this.floatX); this.store?.putSync(`float-${this.orientationKey()}-y`, this.floatY); this.store?.putSync('numberPad', this.showPad);
      this.store?.putSync('haptics', this.haptics); this.store?.flushSync();
    } catch (_) {}
  }
  private viewportChanged(): void {
    if (this.alive && this.orientation !== this.orientationKey()) { this.releaseAll(); this.loadSizing(); }
    this.clampFloating();
  }
  private clampFloating(): void {
    if (this.layout !== 'float') return;
    const limit = Math.max(0, (this.viewportWidth - Math.min(this.viewportWidth - 24, 860)) / 2 - 12);
    this.floatX = Math.max(-limit, Math.min(limit, this.floatX));
    this.floatY = Math.max(-Math.max(0, this.viewportHeight - this.panelHeight - 12), Math.min(0, this.floatY));
  }
  private changeLayout(value: string): void {
    this.releaseAll(); KeyboardClient.cancelPending(); this.saveSizing();
    this.layout = value; this.loadSizing(); this.saveSizing();
  }
  private releaseAll(): void {
    this.held.clear(); this.heldMask = this.armedMask = this.lockedMask = 0;
    this.lastTapMask = 0; KeyboardClient.setHeldModifiers(0);
  }
  private stateChanged(): void { if (this.state !== 'ready') this.releaseAll(); }
  private syncHeld(): void {
    let mask = 0; this.held.forEach((value: HeldModifier) => { mask |= value.mask; });
    this.heldMask = mask; KeyboardClient.setHeldModifiers(mask | this.lockedMask);
  }
  private find(id: string): KeyboardKeySpec | undefined {
    const rows = [...KeyboardLayout.main(this.profile), ...KeyboardLayout.split('left'), ...KeyboardLayout.split('right'), KeyboardLayout.functions(), KeyboardLayout.functions(true), KeyboardLayout.navigation(this.profile), ...KeyboardLayout.numberPad()];
    for (const row of rows) { const key = row.keys.find((value: KeyboardKeySpec) => value.id === id); if (key) return key; }
    return undefined;
  }
  private down(id: string): void {
    const key = this.find(id); if (!key || !key.modifier || this.state !== 'ready') return;
    let shared = false;
    this.held.forEach((value: HeldModifier) => { if (value.mask === key.modifier) { value.used = true; shared = true; } });
    this.held.set(id, new HeldModifier(key.modifier, Date.now(), shared)); this.syncHeld();
  }
  private up(id: string, cancelled: boolean): void {
    const held = this.held.get(id); if (!held) return;
    this.held.delete(id);
    if (!cancelled && !held.used && Date.now() - held.time < 350 && this.state === 'ready') {
      if ((this.lockedMask & held.mask) !== 0) { this.lockedMask &= ~held.mask; this.armedMask &= ~held.mask; }
      else if (this.lastTapMask === held.mask && Date.now() - this.lastTapTime < 350) { this.lockedMask |= held.mask; this.armedMask &= ~held.mask; this.lastTapMask = 0; }
      else { this.armedMask ^= held.mask; this.lastTapMask = held.mask; this.lastTapTime = Date.now(); }
    }
    this.syncHeld();
  }
  private fire(id: string, repeat: boolean): void {
    if (id === 'capslockHold') { if (this.state === 'ready') KeyboardClient.key(id); return; }
    const key = this.find(id); if (!key || this.state !== 'ready') return;
    if (key.code === 'fn') { this.releaseAll(); this.showFunctions = !this.showFunctions; this.saveSizing(); return; }
    if (key.code === 'inputsource') this.releaseAll();
    const mask = this.heldMask | this.armedMask | this.lockedMask;
    if (repeat && mask !== 0 && !['backspace', 'delete', 'left', 'right', 'up', 'down'].includes(key.code)) return;
    this.held.forEach((value: HeldModifier) => { value.used = true; });
    const code = key.code.startsWith('space-') ? 'space' : key.code;
    if (KeyboardClient.key(code, mask, repeat)) this.armedMask = 0;
  }
  private close(): void {
    this.releaseAll(); KeyboardClient.cancelPending(); this.draft = ''; this.visible = false;
    try { void inputMethod.getController().hideTextInput(); } catch (_) {}
  }
  private sendDraft(): void {
    if (this.previewing) return;
    this.releaseAll();
    if (KeyboardClient.text(this.draft)) this.draft = '';
  }
  private status(): string {
    if (this.state === 'ready') return this.transport === 'usb' ? Strings.keyboardReadyUSB : Strings.keyboardReadyWiFi;
    if (this.state === 'permission') return Strings.keyboardPermissionHint;
    if (this.state === 'pairing') return Strings.keyboardPairingHint;
    if (this.state === 'secure-input') return Strings.keyboardSecureInput;
    if (this.state === 'update') return Strings.keyboardUpdateBoth;
    return Strings.keyboardDisconnected;
  }
  private layoutTitle(): string {
    if (this.layout === 'split') return Strings.keyboardSplit;
    if (this.layout === 'full') return Strings.keyboardFull;
    if (this.layout === 'float') return Strings.keyboardFloat;
    return Strings.keyboardDock;
  }
  private rows(): KeyboardRowSpec[] { return KeyboardLayout.main(this.profile); }
  private padVisible(): boolean { return this.showPad && this.viewportWidth >= 1000 && this.layout !== 'split' && this.layout !== 'float'; }
  private contentWidth(): number { return this.layout === 'float' ? Math.min(this.viewportWidth - 24, 860) : this.viewportWidth - 32; }
  private maximumWidth(): number {
    const units = this.layout === 'split' ? 7.4 : KeyboardLayout.units(this.rows());
    const available = this.layout === 'split' ? this.contentWidth() / 2 - 36 : this.contentWidth();
    return Math.max(28, Math.min(110, (available - 64) / (units + (this.padVisible() ? 4.5 : 0))));
  }
  private effectiveWidth(): number { return Math.min(this.keyWidth, this.maximumWidth()); }
  private effectiveHeight(): number {
    const overhead = (this.settingsOpen ? 300 : 150) + (this.showFunctions ? 8 : 0);
    return Math.max(40, Math.min(this.keyHeight, (this.viewportHeight - overhead) / (this.showFunctions ? 7 : 5)));
  }
  @Builder row(row: KeyboardRowSpec, align: FlexAlign = FlexAlign.Center) {
    Row({ space: DT.spacingS4 }) {
      ForEach(row.keys, (key: KeyboardKeySpec) => {
        KeyboardKey({ spec: key, keyWidth: this.effectiveWidth(), keyHeight: this.effectiveHeight(), dark: this.dark,
          selected: key.modifier !== 0 ? ((this.heldMask | this.armedMask | this.lockedMask) & key.modifier) !== 0 : key.code === 'capslock' ? this.caps : key.code === 'fn' && this.showFunctions,
          inputEnabled: this.state === 'ready', haptics: this.haptics && this.hapticAvailable,
          onDown: (id: string) => this.down(id), onUp: (id: string, cancelled: boolean) => this.up(id, cancelled),
          onFire: (id: string, repeat: boolean) => this.fire(id, repeat) })
      }, (key: KeyboardKeySpec) => key.id)
    }.width('100%').justifyContent(align)
  }
  @Builder settings() {
    Column({ space: DT.spacingS4 }) {
      Row({ space: DT.spacingS12 }) {
        Text(Strings.get('keyboardWidthValue', [this.effectiveWidth().toFixed(0)])).fontSize(DT.fontCaption).fontColor(DT.text(this.dark))
        Slider({ value: this.effectiveWidth(), min: Math.min(40, this.maximumWidth()), max: this.maximumWidth(), step: 1 }).layoutWeight(1).accessibilityText(Strings.keyboardKeyWidth)
          .onChange((value: number, mode: SliderChangeMode) => { this.releaseAll(); this.keyWidth = value; if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.saveSizing(); })
        Text(Strings.get('keyboardHeightValue', [this.effectiveHeight().toFixed(0)])).fontSize(DT.fontCaption).fontColor(DT.text(this.dark))
        Slider({ value: this.keyHeight, min: 44, max: this.layout === 'full' ? 160 : 88, step: 1 }).layoutWeight(1).accessibilityText(Strings.keyboardKeyHeight)
          .onChange((value: number, mode: SliderChangeMode) => { this.releaseAll(); this.keyHeight = value; if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.saveSizing(); })
      }.height(DT.layoutTouchTarget).width('100%')
      Row({ space: DT.spacingS12 }) {
        Button(this.profile).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .bindMenu([{ value: 'ANSI', action: () => { this.releaseAll(); this.profile = 'ANSI'; this.saveSizing(); } }, { value: 'ISO', action: () => { this.releaseAll(); this.profile = 'ISO'; this.saveSizing(); } }, { value: 'JIS', action: () => { this.releaseAll(); this.profile = 'JIS'; this.saveSizing(); } }])
        Button(this.extendedFunctions ? 'F13–F20' : 'F1–F12').fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .onClick(() => { this.releaseAll(); this.extendedFunctions = !this.extendedFunctions; this.showFunctions = true; this.saveSizing(); })
        Text(Strings.keyboardHaptics).fontSize(DT.fontCaption).fontColor(DT.text(this.dark))
        Toggle({ type: ToggleType.Switch, isOn: this.haptics }).accessibilityText(Strings.keyboardHaptics)
          .enabled(this.hapticAvailable).onChange((value: boolean) => { this.haptics = value; this.saveSizing(); })
        Text(Strings.keyboardNumberPad).fontSize(DT.fontCaption).fontColor(DT.text(this.dark))
        Toggle({ type: ToggleType.Switch, isOn: this.showPad }).accessibilityText(Strings.keyboardNumberPad)
          .enabled(this.layout !== 'split' && this.layout !== 'float' && this.viewportWidth >= 1000).onChange((value: boolean) => { this.releaseAll(); this.showPad = value; this.saveSizing(); })
        Blank()
        Button(this.notification ? Strings.keyboardDisableNotice : Strings.keyboardEnableNotice).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .onClick(() => { if (this.notification) void KeyboardNotification.disable(); else void KeyboardNotification.enable(); })
      }.width('100%')
      Text(!this.hapticAvailable ? Strings.keyboardVisualFeedback : Strings.keyboardModifierHelp).fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark)).width('100%')
    }.padding(DT.spacingS8).width('100%').backgroundColor(DT.control(this.dark)).borderRadius(DT.radiusSmall)
  }
  @Builder keys() {
    if (this.layout === 'split') {
      Row() {
        Column({ space: DT.spacingS4 }) {
          if (this.showFunctions) {
            this.row(new KeyboardRowSpec('left-fn', KeyboardLayout.functions(this.extendedFunctions).keys.slice(0, Math.ceil(KeyboardLayout.functions(this.extendedFunctions).keys.length / 2))), FlexAlign.Start)
            this.row(new KeyboardRowSpec('left-nav', KeyboardLayout.navigation(this.profile).keys.slice(0, Math.ceil(KeyboardLayout.navigation(this.profile).keys.length / 2))), FlexAlign.Start)
          }
          ForEach(KeyboardLayout.split('left'), (row: KeyboardRowSpec) => { this.row(row, FlexAlign.Start) }, (row: KeyboardRowSpec) => row.id)
        }.width(this.effectiveWidth() * 7.4 + 24)
        Blank()
        Column({ space: DT.spacingS4 }) {
          if (this.showFunctions) {
            this.row(new KeyboardRowSpec('right-fn', KeyboardLayout.functions(this.extendedFunctions).keys.slice(Math.ceil(KeyboardLayout.functions(this.extendedFunctions).keys.length / 2))), FlexAlign.End)
            this.row(new KeyboardRowSpec('right-nav', KeyboardLayout.navigation(this.profile).keys.slice(Math.ceil(KeyboardLayout.navigation(this.profile).keys.length / 2))), FlexAlign.End)
          }
          ForEach(KeyboardLayout.split('right'), (row: KeyboardRowSpec) => { this.row(row, FlexAlign.End) }, (row: KeyboardRowSpec) => row.id)
        }.width(this.effectiveWidth() * 7.4 + 24)
      }.width('100%')
    } else {
      if (this.showFunctions) { this.row(KeyboardLayout.functions(this.extendedFunctions)); this.row(KeyboardLayout.navigation(this.profile)); }
      Row({ space: DT.spacingS16 }) {
        Column({ space: DT.spacingS4 }) {
          ForEach(this.rows(), (row: KeyboardRowSpec) => { this.row(row) }, (row: KeyboardRowSpec) => `${this.profile}-${row.id}`)
        }.layoutWeight(1)
        if (this.padVisible()) {
          Column({ space: DT.spacingS4 }) {
            ForEach(KeyboardLayout.numberPad(), (row: KeyboardRowSpec) => { this.row(row) }, (row: KeyboardRowSpec) => row.id)
          }.width(this.effectiveWidth() * 4 + 12)
        }
      }.width('100%')
    }
  }
  build() {
    Column({ space: DT.spacingS8 }) {
      Row({ space: DT.spacingS8 }) {
        if (this.layout === 'float') {
          Text('⠿').fontSize(DT.fontBody).fontColor(DT.secondary(this.dark)).width(DT.layoutTouchTarget).height(DT.layoutTouchTarget)
            .id('LinkDeskKeyboardDrag').accessibilityText(Strings.keyboardMove)
            .gesture(PanGesture().onActionStart(() => { this.releaseAll(); this.dragX = this.floatX; this.dragY = this.floatY; })
              .onActionUpdate((event: GestureEvent) => { this.floatX = this.dragX + event.offsetX; this.floatY = this.dragY + event.offsetY; this.clampFloating(); })
              .onActionEnd(() => this.saveSizing()).onActionCancel(() => this.saveSizing()))
        }
        Button(this.layoutTitle()).fontSize(DT.fontBody).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .bindMenu([{ value: Strings.keyboardDock, action: () => this.changeLayout('dock') }, { value: Strings.keyboardSplit, action: () => this.changeLayout('split') }, { value: Strings.keyboardFull, action: () => this.changeLayout('full') }, { value: Strings.keyboardFloat, action: () => this.changeLayout('float') }])
        Button(this.status()).fontSize(DT.fontCaption).fontColor(this.state === 'ready' ? DT.success(this.dark) : DT.warning(this.dark)).backgroundColor(Color.Transparent).layoutWeight(1).height(DT.layoutTouchTarget)
          .bindMenu([{ value: Strings.keyboardUSBPriority, action: () => KeyboardClient.selectPriority('usb') }, { value: Strings.keyboardWiFiPriority, action: () => KeyboardClient.selectPriority('wifi') }])
        Button(Strings.keyboardAdjust).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .onClick(() => { this.releaseAll(); this.settingsOpen = !this.settingsOpen; })
        Button(Strings.hide).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget).onClick(() => this.close())
      }.width('100%')
      if (this.settingsOpen) this.settings()
      if (!this.composing) this.keys()
      Row({ space: DT.spacingS8 }) {
        Button(this.composing ? Strings.keyboardShort : Strings.keyboardCompose).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .onClick(() => { this.releaseAll(); this.composing = !this.composing; this.previewing = false; if (!this.composing) { try { void inputMethod.getController().hideTextInput(); } catch (_) {} } })
        Button(this.inputSource || Strings.keyboardMacInput).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.control(this.dark)).height(DT.layoutTouchTarget)
          .enabled(this.state === 'ready').accessibilityText(Strings.keyboardMacInput).onClick(() => { this.releaseAll(); KeyboardClient.key('inputsource'); })
        Blank()
        if (this.lockedMask !== 0 || this.armedMask !== 0) {
          Button(this.lockedMask !== 0 ? Strings.keyboardUnlock : Strings.keyboardArmed).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.accentSoft(this.dark)).height(DT.layoutTouchTarget).onClick(() => this.releaseAll())
        }
        Text(this.profile).fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark))
      }.width('100%')
      if (this.composing) {
        Row({ space: DT.spacingS8 }) {
          TextInput({ text: this.draft, placeholder: Strings.keyboardComposeHint }).id('LinkDeskKeyboardComposition')
            .layoutWeight(1).height(DT.layoutTouchTarget).fontSize(DT.fontBody).maxLength(1024).backgroundColor(DT.control(this.dark)).fontColor(DT.text(this.dark)).defaultFocus(true)
            .onChange((value: string, preview: PreviewText) => { this.draft = value; this.previewing = preview.value.length > 0; })
            .onSubmit(() => this.sendDraft())
          Button(Strings.keyboardSend).height(DT.layoutTouchTarget).fontSize(DT.fontCaption).fontColor(DT.onAccent(this.dark)).backgroundColor(DT.accent(this.dark))
            .enabled(this.state === 'ready' && this.draft.length > 0 && !this.previewing).onClick(() => this.sendDraft())
        }.width('100%')
      }
      if (this.noticeError) Text(Strings.keyboardNoticeError).fontSize(DT.fontCaption).fontColor(DT.warning(this.dark))
    }.padding(DT.spacingS12).width(this.layout === 'float' ? Math.min(this.viewportWidth - 24, 860) : '100%')
      .height(this.layout === 'full' && !this.composing ? this.viewportHeight : 'auto')
      .justifyContent(FlexAlign.End).backgroundColor(DT.glass(this.dark)).borderRadius(this.layout === 'float' ? DT.radiusLarge : DT.radiusSmall)
      .translate({ x: this.layout === 'float' ? this.floatX : 0, y: this.layout === 'float' ? this.floatY : 0 })
      .onAreaChange((_old: Area, area: Area) => { this.panelHeight = Number(area.height); this.clampFloating(); })
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
  }
}
