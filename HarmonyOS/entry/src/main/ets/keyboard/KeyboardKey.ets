import { DT } from '../design/GeneratedDesign';
import { KeyboardKeySpec } from './KeyboardLayout';
import vibrator from '@ohos.vibrator';

@Component
export struct KeyboardKey {
  @Prop spec: KeyboardKeySpec = new KeyboardKeySpec('a', 'a', 'A');
  @Prop keyWidth: number = 56;
  @Prop keyHeight: number = 52;
  @Prop dark: boolean = false;
  @Prop selected: boolean = false;
  @Prop @Watch('enabledChanged') inputEnabled: boolean = true;
  @Prop haptics: boolean = false;
  @StorageLink('LinkDeskReduceMotion') reduceMotion: boolean = false;
  @State private pressed: boolean = false;
  private pointer: number = -1;
  private repeatDelay: number = -1;
  private repeatTimer: number = -1;
  private maximumHold: number = -1;
  private feedbackTimer: number = -1;
  private lastTouch: number = 0;
  private deferred: boolean = false;
  @State private holdFired: boolean = false;
  private downMask: number = 0;
  onDown: (id: string) => number = () => 0;
  onUp: (id: string, cancelled: boolean) => void = () => {};
  onFire: (id: string, repeat: boolean, alternate: boolean, mask: number) => void = () => {};
  private enabledChanged(): void { if (!this.inputEnabled) this.release(true); }
  private timers(): void {
    if (this.repeatDelay >= 0) clearTimeout(this.repeatDelay);
    if (this.repeatTimer >= 0) clearInterval(this.repeatTimer);
    if (this.maximumHold >= 0) clearTimeout(this.maximumHold);
    this.repeatDelay = this.repeatTimer = this.maximumHold = -1;
  }
  private down(): void {
    if (!this.inputEnabled) return;
    this.lastTouch = Date.now(); this.pressed = true;
    if (this.feedbackTimer >= 0) clearTimeout(this.feedbackTimer);
    if (this.haptics) {
      try { void vibrator.startVibration({ type: 'time', duration: DT.durationKeyboardHaptic }, { usage: 'touch' }).catch(() => { AppStorage.setOrCreate('LinkDeskKeyboardHapticAvailable', false); }); } catch (_) { AppStorage.setOrCreate('LinkDeskKeyboardHapticAvailable', false); }
    }
    this.downMask = this.onDown(this.spec.id);
    this.deferred = (this.spec.holdCode.length > 0 && this.downMask === 0) || this.spec.code.startsWith('page-') || this.spec.code === 'fn' || this.spec.code === 'capslock'; this.holdFired = false;
    if (this.spec.modifier === 0) {
      if (this.deferred) {
        if (this.spec.holdCode.length > 0 || this.spec.code === 'capslock') this.repeatDelay = setTimeout(() => {
          if (this.pointer >= 0 && this.inputEnabled) {
            this.holdFired = true;
            this.onFire(this.spec.code === 'capslock' ? 'capslockHold' : this.spec.id, false, this.spec.code !== 'capslock', this.downMask);
          }
        }, 350);
      } else {
        this.onFire(this.spec.id, false, false, this.downMask);
        if (this.spec.repeatable || ['backspace', 'delete'].includes(this.spec.code)) this.repeatDelay = setTimeout(() => {
          if (this.pointer < 0 || !this.inputEnabled) return;
          this.onFire(this.spec.id, true, false, this.downMask);
          this.repeatTimer = setInterval(() => { if (this.pointer >= 0 && this.inputEnabled) this.onFire(this.spec.id, true, false, this.downMask); }, 70);
        }, 420);
      }
    }
    this.maximumHold = setTimeout(() => this.release(true), 30000);
  }
  private release(cancelled: boolean): void {
    this.timers();
    if (this.pointer >= 0) {
      this.lastTouch = Date.now();
      if (!cancelled && this.deferred && !this.holdFired && this.inputEnabled) this.onFire(this.spec.id, false, false, this.downMask);
      this.onUp(this.spec.id, cancelled);
    }
    this.deferred = false;
    this.pointer = -1;
    this.feedbackTimer = setTimeout(() => { this.pressed = false; this.holdFired = false; this.feedbackTimer = -1; }, 65);
  }
  aboutToDisappear(): void {
    this.release(true); if (this.feedbackTimer >= 0) clearTimeout(this.feedbackTimer); this.pressed = false;
  }
  build() {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.holdFired && this.spec.holdCode ? this.spec.alternate : this.spec.label).fontSize(this.spec.label.length === 1 ? DT.fontLabel : this.spec.label.length > 3 ? DT.fontCaption : DT.fontBody).fontWeight(FontWeight.Medium)
          .fontColor(this.pressed ? DT.onAccent(this.dark) : DT.text(this.dark)).maxLines(1)
        if (this.spec.alternate && !this.holdFired) {
          Text(this.spec.alternate).fontSize(DT.fontCaption).fontColor(this.pressed ? DT.onAccent(this.dark) : DT.secondary(this.dark))
            .position({ x: this.keyWidth * this.spec.weight - DT.spacingS28, y: DT.spacingS4 }).width(DT.spacingS20).textAlign(TextAlign.End)
        }
      }.width('100%').height('100%')
    }.id(`LinkDeskKey-${this.spec.id}`).width(this.keyWidth * this.spec.weight).height(this.keyHeight)
      .borderRadius(DT.radiusSmall).padding(DT.spacingS0)
      .backgroundColor(this.pressed ? DT.accent(this.dark) : this.selected ? DT.accentSoft(this.dark) : DT.keyboardKey(this.dark))
      .linearGradient({ angle: 145, colors: [[DT.panelColor0(this.dark), 0], [DT.panelColor1(this.dark), 0.5], [DT.panelColor2(this.dark), 1]] })
      .border({ width: DT.spacingS4 / 4, color: DT.keyboardRim(this.dark), radius: DT.radiusSmall }).clip(true)
      .shadow({ radius: DT.spacingS4, color: DT.keyboardShade(this.dark), offsetY: DT.spacingS4 / 2 })
      .scale({ x: this.pressed && !this.reduceMotion ? DT.transformKeyboardPressScale : 1, y: this.pressed && !this.reduceMotion ? DT.transformKeyboardPressScale : 1 })
      .translate({ y: this.pressed && !this.reduceMotion ? DT.layoutKeyboardPressOffset : 0 })
      .animation({ duration: this.reduceMotion ? 0 : DT.durationKeyboardPress })
      .enabled(this.inputEnabled).accessibilityText(this.spec.label)
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        if (event.type === TouchType.Down && this.pointer < 0 && event.changedTouches.length > 0) { this.pointer = event.changedTouches[0].id; this.down(); }
        else if (event.type === TouchType.Cancel) this.release(true);
        else if (event.type === TouchType.Up && event.changedTouches.some((touch: TouchObject) => touch.id === this.pointer)) this.release(false);
        else if (event.type === TouchType.Move && event.changedTouches.some((touch: TouchObject) => touch.id === this.pointer && (touch.x < -8 || touch.y < -8 || touch.x > this.keyWidth * this.spec.weight + 8 || touch.y > this.keyHeight + 8))) this.release(true);
      })
      .onClick(() => {
        // Accessibility activation has no pointer; ordinary touch already fired.
        if (this.pointer >= 0 || Date.now() - this.lastTouch < 600 || !this.inputEnabled) return;
        this.pressed = true;
        if (this.spec.modifier !== 0) { this.onDown(this.spec.id); this.onUp(this.spec.id, false); }
        else this.onFire(this.spec.id, false, false, -1);
        this.feedbackTimer = setTimeout(() => { this.pressed = false; }, 90);
      })
  }
}
