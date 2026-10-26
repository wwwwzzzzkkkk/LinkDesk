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
  onDown: (id: string) => void = () => {};
  onUp: (id: string, cancelled: boolean) => void = () => {};
  onFire: (id: string, repeat: boolean) => void = () => {};
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
    this.onDown(this.spec.id);
    if (this.spec.modifier === 0) {
      this.onFire(this.spec.id, false);
      if (this.spec.code === 'capslock') this.repeatDelay = setTimeout(() => { if (this.pointer >= 0 && this.inputEnabled) this.onFire('capslockHold', false); }, 350);
      else if (this.spec.repeatable) this.repeatDelay = setTimeout(() => {
        if (this.pointer < 0) return;
        this.repeatTimer = setInterval(() => { if (this.pointer >= 0 && this.inputEnabled) this.onFire(this.spec.id, true); }, 70);
      }, 420);
    }
    this.maximumHold = setTimeout(() => this.release(true), 30000);
  }
  private release(cancelled: boolean): void {
    this.timers();
    if (this.pointer >= 0) { this.lastTouch = Date.now(); this.onUp(this.spec.id, cancelled); }
    this.pointer = -1;
    this.feedbackTimer = setTimeout(() => { this.pressed = false; this.feedbackTimer = -1; }, 65);
  }
  aboutToDisappear(): void {
    this.release(true); if (this.feedbackTimer >= 0) clearTimeout(this.feedbackTimer); this.pressed = false;
  }
  build() {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.spec.label).fontSize(DT.fontBody).fontWeight(FontWeight.Medium)
          .fontColor(this.pressed ? DT.onAccent(this.dark) : DT.text(this.dark)).maxLines(1)
        if (this.spec.alternate) {
          Text(this.spec.alternate).fontSize(DT.fontCaption).fontColor(this.pressed ? DT.onAccent(this.dark) : DT.secondary(this.dark))
            .position({ x: this.keyWidth * this.spec.weight - DT.spacingS28, y: DT.spacingS4 }).width(DT.spacingS20).textAlign(TextAlign.End)
        }
      }.width('100%').height('100%')
    }.id(`LinkDeskKey-${this.spec.id}`).width(this.keyWidth * this.spec.weight).height(this.keyHeight)
      .borderRadius(DT.radiusSmall).padding(DT.spacingS0)
      .backgroundColor(this.pressed ? DT.accent(this.dark) : this.selected ? DT.accentSoft(this.dark) : DT.surface(this.dark))
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
        else this.onFire(this.spec.id, false);
        this.feedbackTimer = setTimeout(() => { this.pressed = false; }, 90);
      })
  }
}
