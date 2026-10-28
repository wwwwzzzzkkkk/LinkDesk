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
  @StorageLink('LinkDeskKeyboardCandidates') @Watch('candidatesChanged') candidatesJSON: string = '[]';
  @StorageLink('LinkDeskKeyboardCandidateFresh') candidateFresh: boolean = false;
  @State private candidates: string[] = [];
  private candidateHideTimer: number = -1;
  @StorageLink('LinkDeskKeyboardHapticAvailable') hapticAvailable: boolean = true;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @State private layout: string = 'dock';
  @State private profile: string = 'ANSI';
  @State private splitPage: string = 'letters';
  @State private keyWidth: number = 80;
  @State private keyHeight: number = 52;
  @State private showFunctions: boolean = false;
  @State private extendedFunctions: boolean = false;
  @State private floatX: number = 0;
  @State private floatY: number = 0;
  private dragX: number = 0;
  private dragY: number = 0;
  @State private panelHeight: number = 420;
  @State private showPad: boolean = false;
  @State private settingsOpen: boolean = false;
  @State private settingsHeight: number = 400;
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
  private keyRegistry: Map<string, KeyboardKeySpec> = new Map();
  private registrySignature: string = '';

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
    this.loadSizing(); this.candidatesChanged();
  }
  aboutToDisappear(): void { this.alive = false; if (this.candidateHideTimer >= 0) clearTimeout(this.candidateHideTimer); this.releaseAll(); this.draft = ''; KeyboardClient.cancelPending(); }
  private orientationKey(): string { return this.viewportWidth >= this.viewportHeight ? 'landscape' : 'portrait'; }
  private loadSizing(): void {
    this.orientation = this.orientationKey();
    const prefix = `${this.layout === 'split' ? 'thumb-mac-v5' : this.layout}-${this.orientation}`;
    this.keyWidth = this.store?.getSync(`${prefix}-width`, this.layout === 'split' ? 56 : this.layout === 'float' ? 48 : 110) as number;
    this.floatX = Number(this.store?.getSync(`float-${this.orientation}-x`, 0)) || 0;
    this.floatY = Number(this.store?.getSync(`position-${this.layout}-${this.orientation}-y`, 0)) || 0;
    this.keyHeight = this.store?.getSync(`${prefix}-height`, this.layout === 'full' ? 140 : this.layout === 'split' ? 56 : 52) as number;
    if (!Number.isFinite(this.keyWidth)) this.keyWidth = 56;
    if (!Number.isFinite(this.keyHeight)) this.keyHeight = 52;
    this.keyWidth = Math.max(40, Math.min(110, this.keyWidth)); this.keyHeight = Math.max(44, Math.min(this.layout === 'full' ? 160 : 88, this.keyHeight));
  }
  private saveSizing(): void {
    try {
      const prefix = `${this.layout === 'split' ? 'thumb-mac-v5' : this.layout}-${this.orientationKey()}`;
      this.store?.putSync(`${prefix}-width`, this.keyWidth); this.store?.putSync(`${prefix}-height`, this.keyHeight);
      this.store?.putSync('layout', this.layout); this.store?.putSync('profile', this.profile);
      this.store?.putSync('functions', this.showFunctions); this.store?.putSync('extendedFunctions', this.extendedFunctions);
      this.store?.putSync(`float-${this.orientationKey()}-x`, this.floatX); this.store?.putSync(`position-${this.layout}-${this.orientationKey()}-y`, this.floatY); this.store?.putSync('numberPad', this.showPad);
      this.store?.putSync('haptics', this.haptics); this.store?.flushSync();
    } catch (_) {}
  }
  private viewportChanged(): void {
    if (this.alive && this.orientation !== this.orientationKey()) { this.releaseAll(); this.loadSizing(); }
    this.clampFloating();
  }
  private clampFloating(): void {
    if (this.layout === 'full') { this.floatY = 0; return; }
    const limit = Math.max(0, (this.viewportWidth - Math.min(this.viewportWidth - 24, 860)) / 2 - 12);
    this.floatX = this.layout === 'float' ? Math.max(-limit, Math.min(limit, this.floatX)) : 0;
    this.floatY = Math.max(-Math.max(0, this.viewportHeight - this.panelHeight - 12), Math.min(0, this.floatY));
  }
  private changeLayout(value: string): void {
    this.releaseAll(); KeyboardClient.cancelPending(); this.saveSizing();
    this.layout = value; this.loadSizing(); this.saveSizing();
  }
  private releaseAll(): void {
    KeyboardClient.cancelRepeats();
    this.held.clear(); this.heldMask = this.armedMask = this.lockedMask = 0;
    this.lastTapMask = 0; KeyboardClient.setHeldModifiers(0);
  }
  private stateChanged(): void { if (this.state !== 'ready') this.releaseAll(); }
  private candidatesChanged(): void {
    if (this.candidateHideTimer >= 0) clearTimeout(this.candidateHideTimer);
    this.candidateHideTimer = -1;
    try {
      const next = JSON.parse(this.candidatesJSON) as string[];
      if (next.length) this.candidates = next;
      else if (this.candidates.length) this.candidateHideTimer = setTimeout(() => { if (this.candidatesJSON === '[]') this.candidates = []; this.candidateHideTimer = -1; }, 350);
    } catch (_) { this.candidates = []; }
  }
  private syncHeld(): void {
    let mask = 0; this.held.forEach((value: HeldModifier) => { mask |= value.mask; });
    this.heldMask = mask; KeyboardClient.setHeldModifiers(mask | this.lockedMask);
  }
  private find(id: string): KeyboardKeySpec | undefined {
    const signature = `${this.profile}-${this.splitPage}`;
    if (signature !== this.registrySignature) {
      const rows = [...KeyboardLayout.main(this.profile), ...KeyboardLayout.split('left', this.profile, this.splitPage), ...KeyboardLayout.split('right', this.profile, this.splitPage), KeyboardLayout.functions(), KeyboardLayout.functions(true), KeyboardLayout.navigation(this.profile), ...KeyboardLayout.numberPad()];
      this.keyRegistry.clear();
      rows.forEach((row: KeyboardRowSpec) => row.keys.forEach((key: KeyboardKeySpec) => { this.keyRegistry.set(key.id, key); }));
      this.registrySignature = signature;
    }
    return this.keyRegistry.get(id);
  }
  private down(id: string): number {
    const key = this.find(id); if (!key || this.state !== 'ready') return 0;
    if (!key.modifier) { this.held.forEach((value: HeldModifier) => { value.used = true; }); return this.heldMask | this.armedMask | this.lockedMask; }
    let shared = false;
    this.held.forEach((value: HeldModifier) => { if (value.mask === key.modifier) { value.used = true; shared = true; } });
    this.held.set(id, new HeldModifier(key.modifier, Date.now(), shared)); this.syncHeld();
    return this.heldMask | this.armedMask | this.lockedMask;
  }
  private up(id: string, cancelled: boolean): void {
    const key = this.find(id);
    if (key) KeyboardClient.cancelRepeats(key.code.startsWith('space-') ? 'space' : key.code);
    const held = this.held.get(id); if (!held) return;
    this.held.delete(id);
    if (!cancelled && !held.used && Date.now() - held.time < 350 && this.state === 'ready') {
      if ((this.lockedMask & held.mask) !== 0) { this.lockedMask &= ~held.mask; this.armedMask &= ~held.mask; }
      else if (this.lastTapMask === held.mask && Date.now() - this.lastTapTime < 350) { this.lockedMask |= held.mask; this.armedMask &= ~held.mask; this.lastTapMask = 0; }
      else { this.armedMask ^= held.mask; this.lastTapMask = held.mask; this.lastTapTime = Date.now(); }
    }
    this.syncHeld();
  }
  private fire(id: string, repeat: boolean, alternate: boolean = false, capturedMask: number = -1): void {
    if (id === 'capslockHold') { if (this.state === 'ready') KeyboardClient.key(id); return; }
    const key = this.find(id); if (!key || this.state !== 'ready') return;
    if (key.code.startsWith('page-')) { this.releaseAll(); KeyboardClient.cancelPending(); this.splitPage = key.code.substring(5); return; }
    if (key.code === 'fn') { this.releaseAll(); this.showFunctions = !this.showFunctions; this.saveSizing(); return; }
    if (key.code === 'inputsource') this.releaseAll();
    const mask = (capturedMask >= 0 ? capturedMask : this.heldMask | this.armedMask | this.lockedMask) | (alternate ? key.holdModifiers : key.sendModifiers);
    if (repeat && mask !== 0 && !['backspace', 'delete', 'left', 'right', 'up', 'down'].includes(key.code)) return;
    this.held.forEach((value: HeldModifier) => { value.used = true; });
    const requested = alternate ? key.holdCode : key.code;
    const code = requested.startsWith('space-') ? 'space' : requested;
    if (KeyboardClient.key(code, mask, repeat)) this.armedMask = 0;
  }
  private close(): void {
    this.releaseAll(); KeyboardClient.cancelPending(); this.draft = ''; this.visible = false; AppStorage.setOrCreate('LinkDeskKeyboardCandidates', '[]');
    try { void inputMethod.getController().hideTextInput(); } catch (_) {}
  }
  private toggleCompose(): void {
    this.releaseAll(); this.composing = !this.composing; this.previewing = false;
    if (!this.composing) { try { void inputMethod.getController().hideTextInput(); } catch (_) {} }
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
    if (this.layout === 'split') return Math.max(28, Math.min(110, (this.viewportWidth - 24 - Math.max(160, this.viewportWidth * 0.28) - 64) / (this.splitUnits() * 2)));
    const units = KeyboardLayout.units(this.rows());
    const available = this.contentWidth();
    return Math.max(28, Math.min(110, (available - 64) / (units + (this.padVisible() ? 4.5 : 0))));
  }
  private effectiveWidth(): number { return Math.min(this.keyWidth, this.maximumWidth()); }
  private effectiveHeight(): number {
    const overhead = (this.settingsOpen ? this.settingsHeight : 0) + 132 + (this.layout === 'split' && this.showFunctions ? KeyboardLayout.splitTools(this.profile, this.extendedFunctions, 14).length * 48 : 0);
    const rows = this.layout !== 'split' && this.showFunctions ? 7 : 5;
    return Math.max(40, Math.min(this.keyHeight, (this.viewportHeight - overhead) / rows));
  }
  private splitUnits(): number { return Math.max(KeyboardLayout.units(KeyboardLayout.split('left', this.profile, this.splitPage)), KeyboardLayout.units(KeyboardLayout.split('right', this.profile, this.splitPage))); }
  private thumbWidth(): number { return this.effectiveWidth() * this.splitUnits() + 36; }
  private thumbHeight(): number { return this.effectiveHeight() * 5 + 32; }
  private maximumLift(): number { return Math.max(0, this.viewportHeight - this.panelHeight - 12); }
  @Builder keyButton(key: KeyboardKeySpec, width: number, height: number) {
    KeyboardKey({ spec: key, keyWidth: width, keyHeight: height, dark: this.dark,
      selected: key.modifier !== 0 ? ((this.heldMask | this.armedMask | this.lockedMask) & key.modifier) !== 0 : key.code === 'capslock' ? this.caps : key.code === 'fn' && this.showFunctions,
      inputEnabled: this.state === 'ready', haptics: this.haptics && this.hapticAvailable,
      onDown: (id: string): number => this.down(id), onUp: (id: string, cancelled: boolean) => this.up(id, cancelled),
      onFire: (id: string, repeat: boolean, alternate: boolean, mask: number) => this.fire(id, repeat, alternate, mask) })
  }
  @Builder row(row: KeyboardRowSpec, align: FlexAlign = FlexAlign.Center, keyWidth: number = 0, keyHeight: number = 0) {
    Row({ space: DT.spacingS4 }) {
      ForEach(row.keys, (key: KeyboardKeySpec) => {
        if (row.id.endsWith('-bottom') && key.code === 'down') {
          Column({ space: DT.spacingS4 }) {
            this.keyButton(row.keys.find((spec: KeyboardKeySpec) => spec.code === 'up')!, keyWidth || this.effectiveWidth(), ((keyHeight || this.effectiveHeight()) - DT.spacingS4) / 2)
            this.keyButton(key, keyWidth || this.effectiveWidth(), ((keyHeight || this.effectiveHeight()) - DT.spacingS4) / 2)
          }.height(keyHeight || this.effectiveHeight())
        } else if (!(row.id.endsWith('-bottom') && key.code === 'up')) {
          this.keyButton(key, keyWidth || this.effectiveWidth(), keyHeight || this.effectiveHeight())
        }
      }, (key: KeyboardKeySpec) => key.id)
    }.width('100%').justifyContent(align)
  }
  private adjustValue(kind: string, value: number, mode: SliderChangeMode): void {
    this.releaseAll();
    if (kind === 'width') this.keyWidth = value;
    else if (kind === 'height') this.keyHeight = value;
    else { this.floatY = -value; this.clampFloating(); }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.saveSizing();
  }
  @Builder adjustSlider(title: string, value: number, minimum: number, maximum: number, kind: string) {
    Column({ space: DT.spacingS0 }) {
      Row() {
        Text(title).fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark)).layoutWeight(1)
        Text(value.toFixed(0)).fontSize(DT.fontBody).fontColor(DT.text(this.dark)).fontWeight(FontWeight.Medium)
      }.width('100%')
      Slider({ value: value, min: minimum, max: maximum, step: 1 })
        .id(`LinkDeskKeyboardSlider-${kind}`).width('100%').height(DT.spacingS32).accessibilityText(title)
        .trackThickness(DT.spacingS4).blockSize({ width: DT.spacingS16, height: DT.spacingS16 })
        .trackColor(DT.keyboardTrack(this.dark)).selectedColor(DT.secondary(this.dark)).blockColor(DT.text(this.dark))
        .onChange((next: number, mode: SliderChangeMode) => this.adjustValue(kind, next, mode))
    }.layoutWeight(1)
  }
  @Builder settings() {
    Row() {
      Scroll() {
      Column({ space: DT.spacingS12 }) {
        Row({ space: DT.spacingS12 }) {
          Text(Strings.keyboardSettingsTitle).fontSize(DT.fontBody).fontWeight(FontWeight.Medium).fontColor(DT.text(this.dark)).layoutWeight(1)
          Button('×').fontSize(DT.fontLabel).fontColor(DT.secondary(this.dark)).backgroundColor(DT.keyboardKey(this.dark)).width(DT.spacingS40).height(DT.spacingS40)
            .id('LinkDeskKeyboardSettingsClose').accessibilityText(Strings.close).onClick(() => { this.releaseAll(); this.settingsOpen = false; })
        }.width('100%')
        Row({ space: DT.spacingS24 }) {
          this.adjustSlider(Strings.keyboardWidthShort, this.effectiveWidth(), Math.min(40, this.maximumWidth()), this.maximumWidth(), 'width')
          this.adjustSlider(Strings.keyboardHeightShort, this.keyHeight, 44, this.layout === 'full' ? 160 : 88, 'height')
        }.width('100%')
        if (this.layout !== 'full') {
          Row() { this.adjustSlider(Strings.keyboardLift, -this.floatY, 0, Math.max(1, this.maximumLift()), 'lift') }.width('100%')
        }
        Divider().color(DT.keyboardRim(this.dark)).opacity(DT.spacingS4 / 8)
        Row({ space: DT.spacingS8 }) {
          Text(Strings.keyboardProfile).fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark)).layoutWeight(1)
          Button(`${this.profile} ⌄`).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.keyboardKey(this.dark)).height(DT.spacingS40)
            .bindMenu([{ value: 'ANSI', action: () => { this.releaseAll(); this.profile = 'ANSI'; this.saveSizing(); } }, { value: 'ISO', action: () => { this.releaseAll(); this.profile = 'ISO'; this.saveSizing(); } }, { value: 'JIS', action: () => { this.releaseAll(); this.profile = 'JIS'; this.saveSizing(); } }])
        }.width('100%')
        Row({ space: DT.spacingS8 }) {
          Text(Strings.keyboardHaptics).fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark)).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.haptics }).accessibilityText(Strings.keyboardHaptics).selectedColor(DT.accent(this.dark))
            .enabled(this.hapticAvailable).onChange((value: boolean) => { this.haptics = value; this.saveSizing(); })
        }.width('100%').height(DT.spacingS40)
        Row({ space: DT.spacingS8 }) {
          Button(`${Strings.keyboardFunctions} ⌄`).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.keyboardKey(this.dark)).height(DT.spacingS40).layoutWeight(1)
            .bindMenu([{ value: 'F1–F12', action: () => { this.releaseAll(); this.extendedFunctions = false; this.showFunctions = true; this.saveSizing(); } }, { value: 'F13–F20', action: () => { this.releaseAll(); this.extendedFunctions = true; this.showFunctions = true; this.saveSizing(); } }])
          Button(`${Strings.keyboardMore} ⌄`).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.keyboardKey(this.dark)).height(DT.spacingS40).layoutWeight(1)
            .bindMenu([{ value: this.status(), enabled: false, action: () => {} }, { value: Strings.keyboardUSBPriority, action: () => KeyboardClient.selectPriority('usb') }, { value: Strings.keyboardWiFiPriority, action: () => KeyboardClient.selectPriority('wifi') },
              { value: Strings.keyboardNumberPad, enabled: this.layout !== 'split' && this.layout !== 'float' && this.viewportWidth >= 1000, action: () => { this.releaseAll(); this.showPad = !this.showPad; this.saveSizing(); } },
              { value: this.notification ? Strings.keyboardDisableNotice : Strings.keyboardEnableNotice, action: () => { if (this.notification) void KeyboardNotification.disable(); else void KeyboardNotification.enable(); } }])
        }.width('100%')
        Text(!this.hapticAvailable ? Strings.keyboardVisualFeedback : this.layout === 'full' ? Strings.keyboardModifierHelp : Strings.keyboardPositionHint)
          .fontSize(DT.fontCaption).fontColor(DT.secondary(this.dark)).width('100%')
      }.padding(DT.spacingS20).width('100%')
      }.width(Math.min(392, this.viewportWidth - 32)).constraintSize({ maxHeight: Math.max(180, this.viewportHeight - 380) }).scrollBar(BarState.Off)
        .onAreaChange((_old: Area, area: Area) => { this.settingsHeight = Number(area.height); })
        .backgroundColor(DT.keyboardFloat(this.dark)).borderRadius(DT.radiusLarge)
        .linearGradient({ angle: 145, colors: [[DT.panelColor0(this.dark), 0], [DT.panelColor1(this.dark), 0.5], [DT.panelColor2(this.dark), 1]] })
        .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
        .border({ width: DT.spacingS4 / 4, color: DT.keyboardRim(this.dark), radius: DT.radiusLarge })
        .shadow({ radius: DT.spacingS24, color: DT.keyboardShade(this.dark), offsetY: DT.spacingS8 })
    }.width('100%').justifyContent(FlexAlign.Start)
  }
  @Builder thumbSide(side: string) {
    Column({ space: DT.spacingS4 }) {
      ForEach(KeyboardLayout.split(side, this.profile, this.splitPage), (row: KeyboardRowSpec) => {
        this.row(row, side === 'left' || row.id.endsWith('home') || row.id.endsWith('lower') ? FlexAlign.Start : FlexAlign.End)
      }, (row: KeyboardRowSpec) => row.id)
    }.padding(DT.spacingS8).width(this.thumbWidth()).backgroundColor(DT.keyboardGlass(this.dark)).borderRadius(DT.radiusMedium)
      .linearGradient({ angle: 145, colors: [[DT.panelColor0(this.dark), 0], [DT.panelColor1(this.dark), 0.5], [DT.panelColor2(this.dark), 1]] })
      .border({ width: DT.spacingS4 / 4, color: DT.keyboardRim(this.dark) })
      .shadow({ radius: DT.spacingS12, color: DT.keyboardShade(this.dark), offsetY: DT.spacingS4 })
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
  }
  @Builder keys() {
    if (this.layout === 'split') {
      if (this.showFunctions) {
        ForEach(KeyboardLayout.splitTools(this.profile, this.extendedFunctions, 14), (row: KeyboardRowSpec) => {
          this.row(row, FlexAlign.Start, Math.min(this.effectiveWidth(), (this.viewportWidth - 100) / 14), DT.spacingS40)
        }, (row: KeyboardRowSpec) => `${this.profile}-${this.extendedFunctions}-${row.id}`)
      }
      Row({ space: DT.spacingS8 }) {
        this.thumbSide('left')
        Blank().layoutWeight(1)
        this.thumbSide('right')
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
      if (this.settingsOpen) this.settings()
      if (!this.composing && this.candidates.length > 0 && this.state === 'ready') {
        Scroll() {
          Row({ space: DT.spacingS4 }) {
            ForEach(this.candidates, (candidate: string, index: number) => {
              Button(`${index + 1} ${candidate}`).height(DT.layoutTouchTarget).fontSize(DT.fontBody)
                .fontColor(DT.text(this.dark)).backgroundColor(DT.keyboardKey(this.dark)).borderRadius(DT.radiusSmall)
                .onClick(() => { if (this.candidateFresh && index < 9) KeyboardClient.key(`${index + 1}`); })
            }, (candidate: string, index: number) => `${index}-${candidate}`)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
          .backgroundColor(DT.keyboardGlass(this.dark)).borderRadius(DT.radiusLarge)
          .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      }
      Row() {
        Row({ space: DT.spacingS4 }) {
          if (this.layout !== 'full') {
            Text('⠿').fontSize(DT.fontBody).fontColor(DT.secondary(this.dark)).width(DT.layoutTouchTarget).height(DT.layoutTouchTarget)
              .id('LinkDeskKeyboardDrag').accessibilityText(this.layout === 'float' ? Strings.keyboardMove : Strings.keyboardMoveVertical)
              .gesture(PanGesture().onActionStart(() => { this.releaseAll(); KeyboardClient.cancelPending(); this.dragX = this.floatX; this.dragY = this.floatY; })
                .onActionUpdate((event: GestureEvent) => { this.floatX = this.layout === 'float' ? this.dragX + event.offsetX : 0; this.floatY = this.dragY + event.offsetY; this.clampFloating(); })
                .onActionEnd(() => this.saveSizing()).onActionCancel(() => this.saveSizing()))
          }
          Button(this.layoutTitle()).id('LinkDeskKeyboardLayout').fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(Color.Transparent).height(DT.layoutTouchTarget)
            .bindMenu([{ value: Strings.keyboardDock, action: () => this.changeLayout('dock') }, { value: Strings.keyboardSplit, action: () => this.changeLayout('split') }, { value: Strings.keyboardFull, action: () => this.changeLayout('full') }, { value: Strings.keyboardFloat, action: () => this.changeLayout('float') }])
          if (this.layout === 'split') {
            Button(`${Strings.keyboardSymbols} ⌄`).id('LinkDeskKeyboardPages')
              .fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(Color.Transparent).height(DT.layoutTouchTarget)
              .bindMenu([{ value: 'ABC', action: () => { this.releaseAll(); KeyboardClient.cancelPending(); this.splitPage = 'letters'; } }, { value: '123', action: () => { this.releaseAll(); KeyboardClient.cancelPending(); this.splitPage = 'numbers'; } }, { value: Strings.keyboardSymbols, action: () => { this.releaseAll(); KeyboardClient.cancelPending(); this.splitPage = 'symbols'; } }])
          }
          Button(Strings.keyboardLanguageMenu).id('LinkDeskKeyboardLanguage').fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(Color.Transparent).height(DT.layoutTouchTarget)
            .bindMenu([{ value: this.composing ? Strings.keyboardShort : Strings.keyboardCompose, action: () => this.toggleCompose() }, { value: this.inputSource || Strings.keyboardMacInput, action: () => { this.releaseAll(); KeyboardClient.key('inputsource'); } }])
          Button(Strings.keyboardAdjust).id('LinkDeskKeyboardAdjust').fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(Color.Transparent).height(DT.layoutTouchTarget)
            .onClick(() => { this.releaseAll(); this.settingsOpen = !this.settingsOpen; })
          Button(Strings.hide).id('LinkDeskKeyboardHide').fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(Color.Transparent).height(DT.layoutTouchTarget).onClick(() => this.close())
          if (this.lockedMask !== 0 || this.armedMask !== 0) {
            Button(this.lockedMask !== 0 ? Strings.keyboardUnlock : Strings.keyboardArmed).fontSize(DT.fontCaption).fontColor(DT.text(this.dark)).backgroundColor(DT.accentSoft(this.dark)).height(DT.layoutTouchTarget).onClick(() => this.releaseAll())
          }
        }.padding({ left: DT.spacingS4, right: DT.spacingS4 }).backgroundColor(DT.keyboardGlass(this.dark)).borderRadius(DT.radiusLarge)
          .border({ width: DT.spacingS4 / 4, color: DT.keyboardRim(this.dark) })
          .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      }.width('100%').justifyContent(FlexAlign.Start)
      if (!this.composing) this.keys()
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
      .justifyContent(FlexAlign.End).backgroundColor(this.layout === 'split' && !this.composing ? Color.Transparent : DT.keyboardGlass(this.dark)).borderRadius(this.layout === 'float' ? DT.radiusLarge : DT.radiusSmall)
      .translate({ x: this.layout === 'float' ? this.floatX : 0, y: this.layout === 'full' ? 0 : this.floatY })
      .onAreaChange((_old: Area, area: Area) => { this.panelHeight = Number(area.height); this.clampFloating(); })
      .backgroundBlurStyle(this.layout === 'split' && !this.composing ? BlurStyle.NONE : BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
  }
}
