import AppKit

/// Creates mouse-compatible tablet-point events. Applications can inspect the
/// pressure and tilt; applications that do not support tablets still get clicks.
enum TabletPen {
  // A stable, nonzero ID associates point and proximity events within a stroke.
  static let deviceID: Int64 = 0x4c44
  // Public IOKit capability bits: device ID, X/Y, buttons, tilt X/Y, pressure.
  static let capabilities: Int64 = 0x05c7
  static func proximity(at point: CGPoint, entering: Bool, source: CGEventSource?) -> CGEvent? {
    guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return nil }
    event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
    event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
    event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: deviceID)
    event.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
    event.setIntegerValueField(.tabletProximityEventPointerType, value: 1)
    event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilities)
    event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
    return event
  }
  static func event(_ type: CGEventType, at point: CGPoint, pressure: Double, tiltX: Double, tiltY: Double, source: CGEventSource?) -> CGEvent? {
    guard pressure.isFinite, (0...1).contains(pressure), tiltX.isFinite, (-1...1).contains(tiltX), tiltY.isFinite, (-1...1).contains(tiltY),
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
    event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
    event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
    event.setIntegerValueField(.tabletEventPointButtons, value: type == .leftMouseUp ? 0 : 1)
    event.setDoubleValueField(.mouseEventPressure, value: pressure)
    event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
    event.setDoubleValueField(.tabletEventTiltX, value: tiltX)
    event.setDoubleValueField(.tabletEventTiltY, value: tiltY)
    return event
  }
}
