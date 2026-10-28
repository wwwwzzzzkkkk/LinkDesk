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
    precondition(TouchTarget.fallback(delta: .zero, elapsed: 1) == nil)
    precondition(TouchTarget.fallback(delta: vertical, elapsed: 0.04) == nil)
    precondition(TouchTarget.fallback(delta: vertical, elapsed: 0.08) == .scroll)
    precondition(TouchTarget.fallback(delta: horizontal, elapsed: 0.08) == .drag)
    print("TOUCH_TARGET_PASS: vertical scrolling, unknown fallback, drag and selection modes")
  }
}
