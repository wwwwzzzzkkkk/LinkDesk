import Foundation

struct KeyboardModifierChange: Equatable {
  let code: UInt16
  let down: Bool
  let mask: Int
}

/// A session owns only its injected modifiers. Missing releases expire without
/// requiring the tablet, HTTP connection or UI process to remain alive.
final class KeyboardModifierLease {
  private(set) var mask = 0
  private(set) var owner = ""
  private var deadline: TimeInterval = 0
  private let codes = [(1, UInt16(56)), (2, UInt16(59)), (4, UInt16(58)), (8, UInt16(55))]

  static func changes(from original: Int, to target: Int) -> [KeyboardModifierChange] {
    guard (0...15).contains(original), (0...15).contains(target) else { return [] }
    let state = KeyboardModifierLease()
    _ = state.set(original, owner: "momentary", now: 0)
    return state.set(target, owner: "momentary", now: 0)
  }

  func set(_ value: Int, owner session: String, now: TimeInterval) -> [KeyboardModifierChange] {
    guard (0...15).contains(value), !session.isEmpty else { return [] }
    if value == 0 && !owner.isEmpty && owner != session { return [] }
    var result: [KeyboardModifierChange] = []
    if !owner.isEmpty && owner != session { result += release() }
    for (bit, code) in codes.reversed() where mask & bit != 0 && value & bit == 0 {
      mask &= ~bit; result.append(.init(code: code, down: false, mask: mask))
    }
    for (bit, code) in codes where mask & bit == 0 && value & bit != 0 {
      mask |= bit; result.append(.init(code: code, down: true, mask: mask))
    }
    owner = mask == 0 ? "" : session; deadline = now + 1.5
    return result
  }
  func release(owner session: String? = nil) -> [KeyboardModifierChange] {
    guard session == nil || session == owner else { return [] }
    var result: [KeyboardModifierChange] = []
    for (bit, code) in codes.reversed() where mask & bit != 0 {
      mask &= ~bit; result.append(.init(code: code, down: false, mask: mask))
    }
    owner = ""; deadline = 0; return result
  }
  func expire(now: TimeInterval) -> [KeyboardModifierChange] { mask != 0 && now >= deadline ? release() : [] }
}
