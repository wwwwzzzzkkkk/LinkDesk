import linkdesk from 'liblinkdesk.so';

interface CursorSnapshot {
  visible: boolean;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  hotX?: number;
  hotY?: number;
  image?: string;
}

// Isolated from the receiver's status/panel component. Position updates do not
// rebuild the panel or wait for the video decoder. The system shape is cached.
@Component
export struct CursorOverlay {
  @Prop displayWidth: number = 0;
  @Prop displayHeight: number = 0;
  @State private visible: boolean = false;
  @State private x: number = 0;
  @State private y: number = 0;
  @State private cursorWidth: number = 0;
  @State private cursorHeight: number = 0;
  @State private image: string = '';
  private timer: number = -1;
  aboutToAppear(): void {
    this.timer = setInterval(() => {
      const raw = linkdesk.cursor();
      if (!raw) return;
      const snapshot = JSON.parse(raw) as CursorSnapshot;
      this.visible = snapshot.visible;
      if (snapshot.image) this.image = snapshot.image;
      if (snapshot.x !== undefined) {
        this.x = snapshot.x - (snapshot.hotX ?? 0);
        this.y = (snapshot.y ?? 0) - (snapshot.hotY ?? 0);
        this.cursorWidth = snapshot.width ?? 0;
        this.cursorHeight = snapshot.height ?? 0;
      }
    }, 4);
  }
  aboutToDisappear(): void { if (this.timer >= 0) clearInterval(this.timer); this.timer = -1; }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.visible && this.image) {
        Image(this.image).width(this.cursorWidth * this.displayWidth).height(this.cursorHeight * this.displayHeight)
          .objectFit(ImageFit.Fill).syncLoad(true)
          .position({ x: this.x * this.displayWidth, y: this.y * this.displayHeight })
      }
    }.width(this.displayWidth).height(this.displayHeight).clip(true).hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants')
  }
}
