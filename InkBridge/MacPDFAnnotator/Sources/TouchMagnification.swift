import CoreGraphics
import Foundation
import Darwin

// The event envelope uses undocumented macOS fields. Based on the format
// documented by calftrail/Touch and macos-trackpad-companion (MIT/Apache-2.0).
// Keep this isolated: Apple can change it without notice.
enum TouchMagnification {
  static func post(_ delta: Double, phase: UInt32) {
    guard delta.isFinite, let event = CGEvent(source: nil), let kind = CGEventType(rawValue: 29) else { return }
    event.type = kind
    event.flags = CGEventFlags(rawValue: 0x100)
    let stamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    event.timestamp = stamp
    guard let original = event.data as Data?, original.count >= 24 else { return }
    var data = original.dropLast(24)
    func bytes<T>(_ value: T) -> Data { var value = value; return withUnsafeBytes(of: &value) { Data($0) } }
    func little<T: FixedWidthInteger>(_ value: T) -> Data { bytes(value.littleEndian) }
    func big<T: FixedWidthInteger>(_ value: T) -> Data { bytes(value.bigEndian) }
    // IOHID queue header (24), digitizer hand (96), vendor token (72).
    var queue = Data(); queue.append(little(stamp)); queue.append(little(UInt64(0))); queue.append(little(UInt32(2))); queue.append(little(UInt32(2)))
    var hand = Data(); hand.append(little(UInt32(96))); hand.append(little(UInt32(11))); hand.append(little(stamp)); hand.append(little(UInt32(2)))
    for value: UInt32 in [0, 0, 0, 0, 0x23, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0] { hand.append(little(value)) }
    var vendor = Data(); vendor.append(little(UInt32(72))); vendor.append(little(UInt32(1))); vendor.append(little(stamp)); vendor.append(little(UInt32(0)))
    vendor.append(little(UInt16(0xff00))); vendor.append(little(UInt16(0x1777))); vendor.append(little(UInt32(1))); vendor.append(little(UInt32(40))); vendor.append(Data(repeating: 0, count: 40))
    guard queue.count == 24, hand.count == 92, vendor.count == 72 else { return }
    // The digitizer struct is 92 bytes, rounded up to its 8-byte alignment.
    hand.replaceSubrange(0..<4, with: little(UInt32(96))); hand.append(Data(repeating: 0, count: 4))
    data.append(contentsOf: big(UInt16(queue.count + hand.count + vendor.count))); data.append(contentsOf: [0x10, 0x6d])
    data.append(contentsOf: queue); data.append(contentsOf: hand); data.append(contentsOf: vendor)
    func field(_ id: UInt8, _ value: UInt32, float: Bool = false) {
      data.append(contentsOf: [0, 1, float ? 0xc0 : 0x40, id]); data.append(contentsOf: big(value))
    }
    field(0x6e, 8); field(0x6f, 0); field(0x70, 0); field(0x84, phase); field(0x85, 0)
    field(0x71, Float(delta).bitPattern, float: true); field(0x8b, 0, float: true); field(0x8c, 0, float: true)
    guard let result = CGEvent(withDataAllocator: nil, data: Data(data) as CFData) else { return }
    result.post(tap: .cgSessionEventTap)
  }
}
