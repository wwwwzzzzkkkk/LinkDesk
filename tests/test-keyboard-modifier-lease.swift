import Foundation

@main struct KeyboardModifierTests {
  static func main() {
    let state = KeyboardModifierLease()
    let both = state.set(9, owner: "tablet-a", now: 10)
    assert(both == [.init(code: 56, down: true, mask: 1), .init(code: 55, down: true, mask: 9)])
    assert(state.set(9, owner: "tablet-a", now: 11).isEmpty) // renewal never presses twice
    assert(state.expire(now: 12.4).isEmpty)
    assert(state.release(owner: "tablet-b").isEmpty) // another peer cannot release our chord
    assert(state.set(0, owner: "tablet-b", now: 12.4).isEmpty)
    assert(state.mask == 9)
    let expired = state.expire(now: 12.5)
    assert(expired == [.init(code: 55, down: false, mask: 1), .init(code: 56, down: false, mask: 0)])
    assert(state.mask == 0 && state.owner.isEmpty)
    _ = state.set(6, owner: "tablet-a", now: 20)
    let replacement = state.set(8, owner: "tablet-b", now: 20.2)
    assert(replacement.map(\.down) == [false, false, true])
    assert(state.mask == 8 && state.owner == "tablet-b")
    assert(state.set(32, owner: "tablet-b", now: 20.3).isEmpty && state.mask == 8)
    assert(state.release().count == 1 && state.mask == 0)
    assert(state.release().isEmpty)
    assert(KeyboardModifierLease.changes(from: 0, to: 9).map(\.down) == [true, true])
    assert(KeyboardModifierLease.changes(from: 9, to: 0).map(\.down) == [false, false])
    assert(KeyboardModifierLease.changes(from: 8, to: 9) == [.init(code: 56, down: true, mask: 9)])
    assert(KeyboardModifierLease.changes(from: 9, to: 8) == [.init(code: 56, down: false, mask: 8)])
    assert(KeyboardModifierLease.changes(from: 8, to: 8).isEmpty)
    print("KEYBOARD_MODIFIERS_PASS: chord order, lease renewal, expiry, peer ownership, reconnect replacement and shutdown release")
  }
}
