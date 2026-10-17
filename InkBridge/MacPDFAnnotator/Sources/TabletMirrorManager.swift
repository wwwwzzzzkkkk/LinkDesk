@preconcurrency import AVFoundation
import AppKit
import SwiftUI
@preconcurrency import CoreMedia
import Darwin
import Foundation

@MainActor
final class TabletMirrorManager: NSObject, ObservableObject, NSWindowDelegate {
  @Published private(set) var isReceiving = false
  @Published private(set) var isConnected = false
  @Published private(set) var status = "平板投屏未启动"

  private var receiver: TabletMirrorReceiver?
  private var mirrorWindow: NSWindow?
  private var mirrorView: TabletMirrorView?

  func arm() {
    prepareReceiver(showWindow: false)
  }

  func start() {
    prepareReceiver(showWindow: true)
  }

  private func prepareReceiver(showWindow: Bool) {
    guard receiver == nil else {
      if showWindow {
        isReceiving = true
        status = isConnected ? status : "等待平板开始投屏…"
        mirrorWindow?.makeKeyAndOrderFront(nil)
      }
      return
    }
    do {
      let view: TabletMirrorView
      let window: NSWindow
      if let existingView = mirrorView, let existingWindow = mirrorWindow {
        view = existingView
        window = existingWindow
      } else {
        view = TabletMirrorView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
          styleMask: [.titled, .closable, .miniaturizable, .resizable],
          backing: .buffered,
          defer: false
        )
        window.title = L10n.mirrorTitle
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 3, height: 2)
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()
        mirrorWindow = window
        mirrorView = view
      }
      if showWindow { window.makeKeyAndOrderFront(nil) }

      let receiver = try TabletMirrorReceiver(port: 3211, displayLayer: view.displayLayer)
      receiver.onConnectionChange = { [weak self] connected, message, width, height in
        Task { @MainActor in
          guard let self else { return }
          self.isConnected = connected
          self.isReceiving = connected
          self.status = connected ? message : "等待平板发起投屏…"
          if connected {
            if let width, let height { self.applyStreamAspectRatio(width: width, height: height) }
            self.mirrorWindow?.makeKeyAndOrderFront(nil)
          } else {
            self.mirrorWindow?.orderOut(nil)
          }
        }
      }
      receiver.start()
      self.receiver = receiver
      isReceiving = showWindow
      status = showWindow ? "等待平板开始投屏…" : "投屏接收已就绪"
    } catch {
      status = "无法建立投屏接收端：\(error.localizedDescription)"
      stop()
    }
  }

  func stop() {
    mirrorWindow?.orderOut(nil)
    isReceiving = false
    isConnected = false
    status = receiver == nil ? "平板投屏已停止" : "投屏接收已就绪"
  }

  func remoteStartWasAccepted() {
    isReceiving = true
    status = isConnected ? status : "平板正在启动投屏…"
    mirrorWindow?.makeKeyAndOrderFront(nil)
  }

  func remoteStartFailed(_ message: String) {
    isReceiving = false
    isConnected = false
    status = "投屏启动失败：\(message)"
    mirrorWindow?.orderOut(nil)
  }

  private func applyStreamAspectRatio(width: Int, height: Int) {
    guard width > 0, height > 0, let window = mirrorWindow else { return }
    let aspect = CGFloat(width) / CGFloat(height)
    window.contentAspectRatio = NSSize(width: CGFloat(width), height: CGFloat(height))
    let visibleHeight = NSScreen.main?.visibleFrame.height ?? DT.layout.mirrorWindowFallbackHeight
    let targetHeight = min(DT.layout.mirrorWindowMaxHeight, visibleHeight * DT.layout.mirrorWindowVisibleFraction)
    window.setContentSize(NSSize(width: targetHeight * aspect, height: targetHeight))
    window.center()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    stop()
    return false
  }
}

private enum TabletMirrorReceiverError: LocalizedError {
  case cannotListen

  var errorDescription: String? { "USB 媒体端口 3211 不可用" }
}

private final class TabletMirrorView: NSView {
  let displayLayer = AVSampleBufferDisplayLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(DT.video).cgColor
    layer?.masksToBounds = true
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor(DT.video).cgColor
    var timebase: CMTimebase?
    if CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    ) == noErr, let timebase {
      CMTimebaseSetTime(timebase, time: .zero)
      CMTimebaseSetRate(timebase, rate: 0)
      displayLayer.controlTimebase = timebase
    }
    layer?.addSublayer(displayLayer)
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }
}

private final class TabletMirrorReceiver: @unchecked Sendable {
  var onConnectionChange: (@Sendable (Bool, String, Int?, Int?) -> Void)?

  private let queue = DispatchQueue(label: "inkbridge.tablet-mirror.receiver", qos: .userInteractive)
  private let stateLock = NSLock()
  private let assembler: H264SampleAssembler
  private var listenerFD: Int32
  private var clientFD: Int32 = -1
  private var running = false

  init(port: UInt16, displayLayer: AVSampleBufferDisplayLayer) throws {
    assembler = H264SampleAssembler(displayLayer: displayLayer)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TabletMirrorReceiverError.cannotListen }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0, listen(fd, 1) == 0 else {
      close(fd)
      throw TabletMirrorReceiverError.cannotListen
    }
    listenerFD = fd
  }

  func start() {
    stateLock.lock()
    running = true
    stateLock.unlock()
    queue.async { [weak self] in self?.receiveLoop() }
  }

  func stop() {
    stateLock.lock()
    running = false
    let listener = listenerFD
    let client = clientFD
    listenerFD = -1
    clientFD = -1
    stateLock.unlock()
    if client >= 0 { shutdown(client, SHUT_RDWR); close(client) }
    if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
  }

  private func receiveLoop() {
    while shouldRun() {
      let fd = Darwin.accept(listenerFD, nil, nil)
      guard fd >= 0 else { return }
      var noDelay: Int32 = 1
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout.size(ofValue: noDelay)))
      stateLock.lock()
      clientFD = fd
      stateLock.unlock()
      assembler.reset()

      guard let streamHeader = readExactly(16, from: fd),
            String(decoding: streamHeader.prefix(4), as: UTF8.self) == "IBV1" else {
        closeClient(fd)
        continue
      }
      let width = Int(streamHeader.uint16BE(at: 4))
      let height = Int(streamHeader.uint16BE(at: 6))
      let fps = Int(streamHeader[9])
      onConnectionChange?(true, "USB 投屏中 · \(width)×\(height) · \(fps) fps", width, height)

      while shouldRun(), let header = readExactly(16, from: fd) {
        let length = Int(header.uint32BE(at: 0))
        let pts = header.uint64BE(at: 4)
        let flags = header.uint32BE(at: 12)
        guard length > 0, length <= 16 * 1024 * 1024,
              let payload = readExactly(length, from: fd) else { break }
        assembler.consume(payload, ptsMicroseconds: pts, flags: flags)
      }
      closeClient(fd)
      assembler.reset()
      if shouldRun() {
        onConnectionChange?(false, "投屏已断开，等待平板重连…", nil, nil)
      }
    }
  }

  private func shouldRun() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return running
  }

  private func closeClient(_ fd: Int32) {
    stateLock.lock()
    let ownsDescriptor = clientFD == fd
    if ownsDescriptor { clientFD = -1 }
    stateLock.unlock()
    guard ownsDescriptor else { return }
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }

  private func readExactly(_ count: Int, from fd: Int32) -> Data? {
    var data = Data(count: count)
    let success = data.withUnsafeMutableBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      var received = 0
      while received < count {
        let amount = Darwin.recv(fd, base.advanced(by: received), count - received, 0)
        if amount <= 0 { return false }
        received += amount
      }
      return true
    }
    return success ? data : nil
  }

  deinit { stop() }
}

private final class H264SampleAssembler: @unchecked Sendable {
  private let displayLayer: AVSampleBufferDisplayLayer
  private var formatDescription: CMVideoFormatDescription?
  private var sequenceParameterSet: Data?
  private var pictureParameterSet: Data?
  private var streamStartPTS: UInt64?

  init(displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer = displayLayer
  }

  func reset() {
    formatDescription = nil
    sequenceParameterSet = nil
    pictureParameterSet = nil
    streamStartPTS = nil
    DispatchQueue.main.async { [displayLayer] in
      displayLayer.flushAndRemoveImage()
      if let timebase = displayLayer.controlTimebase {
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: .zero)
      }
    }
  }

  func consume(_ data: Data, ptsMicroseconds: UInt64, flags: UInt32) {
    let units = Self.nalUnits(from: data)
    guard !units.isEmpty else { return }
    for unit in units where !unit.isEmpty {
      switch unit[unit.startIndex] & 0x1f {
      case 7: sequenceParameterSet = unit
      case 8: pictureParameterSet = unit
      default: break
      }
    }
    if formatDescription == nil,
       let sps = sequenceParameterSet,
       let pps = pictureParameterSet {
      var description: CMFormatDescription?
      let status = sps.withUnsafeBytes { spsBytes in
        pps.withUnsafeBytes { ppsBytes in
          let pointers = [
            spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
            ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
          ]
          let sizes = [sps.count, pps.count]
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &description
          )
        }
      }
      if status == noErr { formatDescription = description }
    }

    let isCodecData = flags & UInt32(AVCODEC_BUFFER_FLAGS_CODEC_DATA_VALUE) != 0
    guard !isCodecData, let formatDescription else { return }
    let frameUnits = units.filter {
      guard let first = $0.first else { return false }
      let type = first & 0x1f
      return type != 7 && type != 8 && type != 9
    }
    guard !frameUnits.isEmpty else { return }

    var avcc = Data()
    for unit in frameUnits {
      avcc.appendUInt32BE(UInt32(unit.count))
      avcc.append(unit)
    }
    var blockBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: avcc.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    ) == kCMBlockBufferNoErr, let blockBuffer else { return }
    let copyResult = avcc.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                                    dataLength: avcc.count)
    }
    guard copyResult == kCMBlockBufferNoErr else { return }

    if streamStartPTS == nil { streamStartPTS = ptsMicroseconds }
    let normalizedPTS = ptsMicroseconds >= (streamStartPTS ?? 0)
      ? ptsMicroseconds - (streamStartPTS ?? 0)
      : 0
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: CMTimeValue(normalizedPTS), timescale: 1_000_000),
      decodeTimeStamp: .invalid
    )
    var sampleSize = avcc.count
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else { return }
    DispatchQueue.main.async { [displayLayer] in
      if displayLayer.status == .failed { displayLayer.flush() }
      if let timebase = displayLayer.controlTimebase, CMTimebaseGetRate(timebase) == 0 {
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1)
      }
      displayLayer.enqueue(sampleBuffer)
    }
  }

  private static func nalUnits(from data: Data) -> [Data] {
    if data.count > 6, data[0] == 1 {
      return configurationRecordUnits(from: data)
    }
    let bytes = [UInt8](data)
    var starts: [(start: Int, prefix: Int)] = []
    var index = 0
    while index + 3 < bytes.count {
      if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
        starts.append((index, 3)); index += 3
      } else if index + 4 <= bytes.count && bytes[index] == 0 && bytes[index + 1] == 0 &&
                  bytes[index + 2] == 0 && bytes[index + 3] == 1 {
        starts.append((index, 4)); index += 4
      } else {
        index += 1
      }
    }
    if !starts.isEmpty {
      return starts.enumerated().compactMap { item in
        let begin = item.element.start + item.element.prefix
        let end = item.offset + 1 < starts.count ? starts[item.offset + 1].start : bytes.count
        return begin < end ? Data(bytes[begin..<end]) : nil
      }
    }
    var result: [Data] = []
    index = 0
    while index + 4 <= bytes.count {
      let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 |
        Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
      index += 4
      guard length > 0, index + length <= bytes.count else { return [] }
      result.append(Data(bytes[index..<(index + length)]))
      index += length
    }
    return result
  }

  private static func configurationRecordUnits(from data: Data) -> [Data] {
    let bytes = [UInt8](data)
    guard bytes.count >= 7 else { return [] }
    var index = 6
    var result: [Data] = []
    let spsCount = Int(bytes[5] & 0x1f)
    for _ in 0..<spsCount {
      guard index + 2 <= bytes.count else { return result }
      let length = Int(bytes[index]) << 8 | Int(bytes[index + 1]); index += 2
      guard index + length <= bytes.count else { return result }
      result.append(Data(bytes[index..<(index + length)])); index += length
    }
    guard index < bytes.count else { return result }
    let ppsCount = Int(bytes[index]); index += 1
    for _ in 0..<ppsCount {
      guard index + 2 <= bytes.count else { return result }
      let length = Int(bytes[index]) << 8 | Int(bytes[index + 1]); index += 2
      guard index + length <= bytes.count else { return result }
      result.append(Data(bytes[index..<(index + length)])); index += length
    }
    return result
  }
}

private let AVCODEC_BUFFER_FLAGS_CODEC_DATA_VALUE = 1 << 3

private extension Data {
  func uint16BE(at offset: Int) -> UInt16 {
    UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
  }

  func uint32BE(at offset: Int) -> UInt32 {
    UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
      UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
  }

  func uint64BE(at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in offset..<(offset + 8) { value = value << 8 | UInt64(self[index]) }
    return value
  }

  mutating func appendUInt32BE(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value >> 24))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value))
  }
}
