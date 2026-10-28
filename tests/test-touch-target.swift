import AppKit

@main
struct TouchTargetTests {
  static func main() {
    let vertical = CGPoint(x: 3, y: 30), horizontal = CGPoint(x: 30, y: 3)
    precondition(TouchTarget.shouldScroll(.scroll, force: false, delta: vertical))
    precondition(TouchTarget.shouldScroll(.unknown, force: false, delta: vertical))
    precondition(!TouchTarget.shouldScroll(.drag, force: false, delta: vertical))
    precondition(!TouchTarget.shouldScroll(.scroll, force: false, delta: horizontal))
    precondition(TouchTarget.shouldScroll(.scroll, force: true, delta: horizontal))
    precondition(!TouchTarget.shouldScroll(.drag, force: true, delta: horizontal))
    print("TOUCH_TARGET_PASS: vertical scrolling, unknown fallback, drag and selection modes")
  }
}
