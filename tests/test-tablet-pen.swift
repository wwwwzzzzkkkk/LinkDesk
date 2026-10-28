import AppKit

@main struct TabletPenTests {
  static func main() {
    for entering in [true, false] {
      let cg = TabletPen.proximity(at: .zero, entering: entering, source: nil)!
      let e = NSEvent(cgEvent: cg)!
      precondition(e.subtype == .tabletProximity && e.deviceID == Int(TabletPen.deviceID))
      precondition(e.isEnteringProximity == entering && e.pointingDeviceType == .pen)
      precondition(e.capabilityMask == Int(TabletPen.capabilities))
    }
    for p in [0.1, 0.5, 0.9] {
      let cg = TabletPen.event(.leftMouseDragged, at: CGPoint(x: 50, y: 70), pressure: p, tiltX: -0.25, tiltY: 0.5, source: nil)!
      let event = NSEvent(cgEvent: cg)!
      precondition(event.subtype == .tabletPoint && event.deviceID == Int(TabletPen.deviceID))
      precondition(abs(Double(event.pressure) - p) < 0.01)
      precondition(abs(Double(event.tilt.x) + 0.25) < 0.01 && abs(Double(event.tilt.y) - 0.5) < 0.01)
    }
    precondition(TabletPen.event(.leftMouseDown, at: .zero, pressure: 2, tiltX: 0, tiltY: 0, source: nil) == nil)
    print("TABLET_PEN_PASS: tablet subtype, pressure, tilt and invalid samples")
  }
}
