import AppKit
import ApplicationServices

/// Accessibility queries run away from the UI and video threads. Unknown
/// targets use the gesture direction as a fallback.
enum TouchTarget: Sendable {
  case scroll, drag, unknown
  nonisolated static func focusedEditable() -> Bool {
    let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.05)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
      let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
    let focused = unsafeDowncast(element, to: AXUIElement.self); AXUIElementSetMessagingTimeout(focused, 0.05)
    value = nil
    guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &value) == .success,
      let role = value as? String, ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else { return false }
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
  }
  // Only unambiguously blank containers qualify; never dismiss on text,
  // links, controls or unknown accessibility results.
  nonisolated static func clearlyBlank(at point: CGPoint) -> Bool {
    let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.05)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let element = hit else { return false }
    AXUIElementSetMessagingTimeout(element, 0.05); var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success, let role = value as? String else { return false }
    return ["AXWebArea", "AXScrollArea", "AXWindow", "AXGroup"].contains(role)
  }
  nonisolated static func shouldScroll(_ target: TouchTarget, force: Bool, delta: CGPoint) -> Bool {
    (target == .scroll || target == .unknown) && (force || abs(delta.y) > abs(delta.x) * 1.15)
  }
  // An early touch-down can wait without moving. Do not guess its purpose
  // until motion provides a direction; otherwise a pause breaks scrolling.
  nonisolated static func fallback(delta: CGPoint, elapsed: TimeInterval) -> TouchTarget? {
    guard elapsed >= 0.08, delta != .zero else { return nil }
    return abs(delta.y) > abs(delta.x) * 1.15 ? .scroll : .drag
  }
  nonisolated static func at(_ point: CGPoint) -> TouchTarget {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.025)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var current = hit else { return .unknown }
    var depth = 0
    while depth < 8 {
      AXUIElementSetMessagingTimeout(current, 0.025)
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &value) == .success,
        let role = value as? String else { return .unknown }
      if ["AXSlider", "AXScrollBar", "AXTextField", "AXTitleBar", "AXToolbar"].contains(role) { return .drag }
      if ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline"].contains(role) { return .scroll }
      if role == "AXWindow" { return depth == 0 ? .drag : .unknown }
      value = nil
      guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &value) == .success,
        let parent = value, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unknown }
      current = unsafeDowncast(parent, to: AXUIElement.self); depth += 1
    }
    return .unknown
  }
}
