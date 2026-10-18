import AppKit

private struct WhiteboardStroke {
  var color: NSColor
  var opacity: CGFloat
  var width: CGFloat
  var tool: String
  var eraserSize: CGFloat
  var eraserRatio: CGFloat?
  var canvasAspect: CGFloat?
  var coordinateSpace: String?
  var points: [RelayPoint]
}

final class WhiteboardCanvasView: NSView {
  var onViewport: ((WhiteboardViewport) -> Void)?
  var onHistoryAvailability: ((Bool, Bool) -> Void)?

  private static let worldHeight: CGFloat = 1000
  private static let minimumZoom: CGFloat = 0.25
  private static let maximumZoom: CGFloat = 8
  private var events: [RelayMessage] = []
  private var historyCursor = 0
  private var historyRevision = 0
  private var lastStrokeSequence: [String: Int] = [:]
  private var hover: (
    point: RelayPoint,
    aspect: CGFloat?,
    tool: String,
    eraserSize: CGFloat,
    eraserRatio: CGFloat?,
    coordinateSpace: String?
  )?
  private var center = CGPoint.zero
  private var zoom: CGFloat = 1
  private var interactionId: String?
  private var committedInkLayer: CGLayer?
  private var committedInkCacheKey: CommittedInkCacheKey?
  private(set) var committedInkRenderCount = 0
  private var cachedHistoryOperations: [HistoryOperation] = []
  private var cachedHistoryOperationIndexes: [String: Int] = [:]
  private var isHistoryOperationsCacheValid = true

  private struct CommittedInkCacheKey: Equatable {
    let historyRevision: Int
    let historyCursor: Int
    let width: CGFloat
    let height: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
    let zoom: CGFloat
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect = .zero) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.white.cgColor
  }

  required init?(coder: NSCoder) { nil }

  func handle(_ message: RelayMessage) {
    if message.type.hasPrefix("stroke:"),
       let strokeId = message.strokeId,
       let sequence = message.strokeSequence {
      if sequence <= (lastStrokeSequence[strokeId] ?? -1) { return }
      lastStrokeSequence[strokeId] = sequence
    }
    switch message.type {
    case "stroke:start", "stroke:move", "stroke:replace", "stroke:end":
      recordHistory(message)
    case "cursor:move":
      if let point = message.point {
        hover = (
          point,
          message.canvasAspect.map { CGFloat($0) },
          message.tool == "eraser" ? "eraser" : "ink",
          CGFloat(message.eraserSize ?? 48),
          message.eraserRatio.map { CGFloat($0) },
          message.coordinateSpace
        )
      }
    case "cursor:hide":
      hover = nil
    case "clear":
      recordHistory(message)
      hover = nil
    default:
      return
    }
    needsDisplay = true
  }

  func clear() {
    events.removeAll()
    cachedHistoryOperations = []
    cachedHistoryOperationIndexes = [:]
    isHistoryOperationsCacheValid = true
    historyCursor = 0
    historyRevision = 0
    lastStrokeSequence = [:]
    hover = nil
    invalidateCommittedInkCache()
    needsDisplay = true
    publishHistoryAvailability()
  }

  func restore(_ messages: [RelayMessage], cursor: Int? = nil, revision: Int? = nil) {
    events = messages.filter { $0.type == "clear" || $0.type.hasPrefix("stroke:") }
    invalidateHistoryOperationsCache()
    let count = historyOperations().count
    historyCursor = min(count, max(0, cursor ?? count))
    historyRevision = max(0, revision ?? historyRevision)
    rebuildStrokeSequences()
    hover = nil
    invalidateCommittedInkCache()
    needsDisplay = true
    publishHistoryAvailability()
  }

  func applyHistory(_ message: RelayMessage) {
    let count = historyOperations().count
    if let cursor = message.historyCursor {
      historyCursor = min(count, max(0, cursor))
    } else if message.type == "history:undo" {
      historyCursor = max(0, historyCursor - 1)
    } else if message.type == "history:redo" {
      historyCursor = min(count, historyCursor + 1)
    }
    historyRevision = max(historyRevision, message.historyRevision ?? 0)
    rebuildStrokeSequences()
    hover = nil
    invalidateCommittedInkCache()
    needsDisplay = true
    publishHistoryAvailability()
  }

  func apply(_ viewport: WhiteboardViewport) {
    guard viewport.centerX.isFinite, viewport.centerY.isFinite, viewport.zoom.isFinite else { return }
    center = CGPoint(x: viewport.centerX, y: viewport.centerY)
    zoom = min(Self.maximumZoom, max(Self.minimumZoom, CGFloat(viewport.zoom)))
    invalidateCommittedInkCache()
    needsDisplay = true
  }

  func zoom(by multiplier: CGFloat) {
    beginViewportInteraction()
    zoom = min(Self.maximumZoom, max(Self.minimumZoom, zoom * multiplier))
    invalidateCommittedInkCache()
    needsDisplay = true
    sendViewport(phase: "update")
    endViewportInteraction()
  }

  func resetViewport() {
    beginViewportInteraction()
    center = .zero
    zoom = 1
    invalidateCommittedInkCache()
    needsDisplay = true
    sendViewport(phase: "update")
    endViewportInteraction()
  }

  override func scrollWheel(with event: NSEvent) {
    let isDiscrete = event.phase.isEmpty
    if event.phase == .began || interactionId == nil { beginViewportInteraction() }
    let scale = worldScale
    center.x += event.scrollingDeltaX / scale
    center.y += event.scrollingDeltaY / scale
    invalidateCommittedInkCache()
    needsDisplay = true
    sendViewport(phase: "update")
    if isDiscrete || event.phase == .ended || event.phase == .cancelled { endViewportInteraction() }
  }

  override func magnify(with event: NSEvent) {
    if event.phase == .began || interactionId == nil { beginViewportInteraction() }
    let focus = convert(event.locationInWindow, from: nil)
    let worldFocus = screenToWorld(focus)
    zoom = min(Self.maximumZoom, max(Self.minimumZoom, zoom * (1 + event.magnification)))
    let scale = worldScale
    center.x = worldFocus.x - (focus.x - bounds.midX) / scale
    center.y = worldFocus.y - (focus.y - bounds.midY) / scale
    invalidateCommittedInkCache()
    needsDisplay = true
    sendViewport(phase: "update")
    if event.phase == .ended || event.phase == .cancelled { endViewportInteraction() }
  }

  override func mouseDown(with event: NSEvent) {
    beginViewportInteraction()
    lastDragPoint = convert(event.locationInWindow, from: nil)
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let lastDragPoint else { return }
    center.x -= (point.x - lastDragPoint.x) / worldScale
    center.y -= (point.y - lastDragPoint.y) / worldScale
    self.lastDragPoint = point
    invalidateCommittedInkCache()
    needsDisplay = true
    sendViewport(phase: "update")
  }

  override func mouseUp(with event: NSEvent) {
    lastDragPoint = nil
    endViewportInteraction()
  }

  private var worldScale: CGFloat {
    max(0.0001, bounds.height / Self.worldHeight * zoom)
  }

  private var lastDragPoint: CGPoint?

  private func worldToScreen(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: bounds.midX + (point.x - center.x) * worldScale,
      y: bounds.midY + (point.y - center.y) * worldScale
    )
  }

  private func screenToWorld(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: center.x + (point.x - bounds.midX) / worldScale,
      y: center.y + (point.y - bounds.midY) / worldScale
    )
  }

  private func beginViewportInteraction() {
    interactionId = "mac-whiteboard-\(UUID().uuidString.lowercased())"
    sendViewport(phase: "begin")
  }

  private func endViewportInteraction() {
    sendViewport(phase: "end")
    interactionId = nil
  }

  private func sendViewport(phase: String) {
    guard let interactionId, bounds.width > 0, bounds.height > 0 else { return }
    onViewport?(WhiteboardViewport(
      centerX: Double(center.x),
      centerY: Double(center.y),
      zoom: Double(zoom),
      viewportWidth: Double(bounds.width),
      viewportHeight: Double(bounds.height),
      interactionId: interactionId,
      interactionPhase: phase
    ))
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.white.setFill()
    bounds.fill()
    drawGrid()
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    let history = historyOperations()
    let cursor = min(history.count, max(0, historyCursor))
    let committedOperations = history.prefix(cursor)
    let activeEvents = history.dropFirst(cursor)
      .filter { $0.messages.contains { $0.type.hasPrefix("stroke:") }
        && !$0.messages.contains { $0.type == "stroke:end" } }
      .flatMap(\.messages)
    drawCommittedInk(committedOperations, in: context)
    let active = renderInkEvents(activeEvents, in: context)
    context.endTransparencyLayer()
    context.restoreGState()
    if let eraser = active.values.first(where: { $0.tool == "eraser" }) {
      drawEraserPreview(eraser, context: context)
    }
    drawHover(context)
  }

  private func drawCommittedInk(
    _ operations: ArraySlice<HistoryOperation>,
    in context: CGContext
  ) {
    let key = CommittedInkCacheKey(
      historyRevision: historyRevision,
      historyCursor: historyCursor,
      width: bounds.width,
      height: bounds.height,
      centerX: center.x,
      centerY: center.y,
      zoom: zoom
    )
    if committedInkLayer == nil || committedInkCacheKey != key {
      if bounds.width > 0, bounds.height > 0,
         let layer = CGLayer(
           context,
           size: bounds.size,
           auxiliaryInfo: nil
         ), let layerContext = layer.context {
        layerContext.clear(bounds)
        _ = renderInkEvents(operations.flatMap(\.messages), in: layerContext)
        committedInkLayer = layer
        committedInkCacheKey = key
        committedInkRenderCount += 1
      } else {
        committedInkLayer = nil
        committedInkCacheKey = nil
      }
    }
    if let committedInkLayer { context.draw(committedInkLayer, at: .zero) }
  }

  private func invalidateCommittedInkCache() {
    committedInkLayer = nil
    committedInkCacheKey = nil
  }

  @discardableResult
  private func renderInkEvents(
    _ visibleEvents: [RelayMessage],
    in context: CGContext
  ) -> [String: WhiteboardStroke] {
    let eventsAfterLastClear: ArraySlice<RelayMessage>
    if let clearIndex = visibleEvents.lastIndex(where: { $0.type == "clear" }) {
      eventsAfterLastClear = visibleEvents[visibleEvents.index(after: clearIndex)...]
    } else {
      eventsAfterLastClear = visibleEvents[...]
    }
    var renderEvents: [RelayMessage] = []
    var firstIndexByStroke: [String: Int] = [:]
    for event in eventsAfterLastClear {
      if event.type == "stroke:replace", let strokeId = event.strokeId {
        if firstIndexByStroke[strokeId] != nil {
          renderEvents.removeAll { $0.strokeId == strokeId }
          firstIndexByStroke = [:]
          for (index, retained) in renderEvents.enumerated() {
            if let retainedId = retained.strokeId, firstIndexByStroke[retainedId] == nil {
              firstIndexByStroke[retainedId] = index
            }
          }
        }
        firstIndexByStroke[strokeId] = renderEvents.count
      } else if let strokeId = event.strokeId, firstIndexByStroke[strokeId] == nil {
        firstIndexByStroke[strokeId] = renderEvents.count
      }
      renderEvents.append(event)
    }
    var operations: [(strokeId: String, events: [RelayMessage])] = []
    var operationIndex: [String: Int] = [:]
    for event in renderEvents {
      guard let strokeId = event.strokeId else { continue }
      if let index = operationIndex[strokeId] {
        operations[index].events.append(event)
      } else {
        operationIndex[strokeId] = operations.count
        operations.append((strokeId, [event]))
      }
    }
    var active: [String: WhiteboardStroke] = [:]
    for operation in operations {
      guard let seed = operation.events.first else { continue }
      var stroke = WhiteboardStroke(
        color: NSColor(hex: seed.color) ?? NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.25, alpha: 1),
        opacity: CGFloat(seed.opacity ?? 1),
        width: CGFloat(seed.width ?? 4.5),
        tool: ["ink", "highlighter", "eraser"].contains(seed.tool ?? "") ? seed.tool! : "ink",
        eraserSize: CGFloat(seed.eraserSize ?? 48),
        eraserRatio: seed.eraserRatio.map { CGFloat($0) },
        canvasAspect: seed.canvasAspect.map { CGFloat($0) },
        coordinateSpace: seed.coordinateSpace,
        points: []
      )
      var ended = false
      for event in operation.events {
        if let color = NSColor(hex: event.color) { stroke.color = color }
        if let opacity = event.opacity { stroke.opacity = CGFloat(min(1, max(0.05, opacity))) }
        if let width = event.width { stroke.width = CGFloat(width) }
        if let tool = event.tool, ["ink", "highlighter", "eraser"].contains(tool) { stroke.tool = tool }
        if let size = event.eraserSize { stroke.eraserSize = CGFloat(size) }
        if let ratio = event.eraserRatio { stroke.eraserRatio = CGFloat(ratio) }
        if let aspect = event.canvasAspect { stroke.canvasAspect = CGFloat(aspect) }
        if event.coordinateSpace == "whiteboard-world-v1" { stroke.coordinateSpace = event.coordinateSpace }
        if event.type == "stroke:replace" { stroke.points = [] }
        let nextPoints = event.type == "stroke:move" || event.type == "stroke:replace"
          ? (event.points ?? [])
          : event.point.map { [$0] } ?? []
        stroke.points.append(contentsOf: nextPoints)
        if event.type == "stroke:end" { ended = true }
      }
      if stroke.tool == "highlighter" {
        drawHighlighter(stroke, context: context)
      } else {
        var previous: RelayPoint?
        for point in stroke.points {
          draw(point: point, after: previous, stroke: stroke, context: context)
          previous = point
        }
      }
      if !ended { active[operation.strokeId] = stroke }
    }
    return active
  }

  private struct HistoryOperation {
    let id: String
    var messages: [RelayMessage]
  }

  private func historyOperations() -> [HistoryOperation] {
    if isHistoryOperationsCacheValid { return cachedHistoryOperations }
    var operations: [HistoryOperation] = []
    var indexes: [String: Int] = [:]
    for (index, message) in events.enumerated() {
      guard message.type == "clear" || message.type.hasPrefix("stroke:") else { continue }
      let id = historyOperationID(for: message, eventIndex: index)
      if let existing = indexes[id] {
        operations[existing].messages.append(message)
      } else {
        indexes[id] = operations.count
        operations.append(HistoryOperation(id: id, messages: [message]))
      }
    }
    cachedHistoryOperations = operations
    cachedHistoryOperationIndexes = indexes
    isHistoryOperationsCacheValid = true
    return cachedHistoryOperations
  }

  private func historyOperationID(for message: RelayMessage, eventIndex: Int) -> String {
    if let operationId = message.operationId, !operationId.isEmpty {
      return operationId
    }
    if let strokeId = message.strokeId, message.type.hasPrefix("stroke:") {
      return "stroke:\(strokeId)"
    }
    return "clear:\(eventIndex)"
  }

  private func invalidateHistoryOperationsCache() {
    cachedHistoryOperations = []
    cachedHistoryOperationIndexes = [:]
    isHistoryOperationsCacheValid = false
  }

  private func replaceHistoryOperationsCache(with operations: [HistoryOperation]) {
    cachedHistoryOperations = operations
    cachedHistoryOperationIndexes = [:]
    for (index, operation) in operations.enumerated() {
      cachedHistoryOperationIndexes[operation.id] = index
    }
    isHistoryOperationsCacheValid = true
  }

  private func appendToHistoryOperationsCache(_ message: RelayMessage) {
    guard isHistoryOperationsCacheValid else {
      _ = historyOperations()
      return
    }
    let id = historyOperationID(for: message, eventIndex: events.count - 1)
    if let existing = cachedHistoryOperationIndexes[id] {
      cachedHistoryOperations[existing].messages.append(message)
    } else {
      cachedHistoryOperationIndexes[id] = cachedHistoryOperations.count
      cachedHistoryOperations.append(HistoryOperation(id: id, messages: [message]))
    }
  }

  private func recordHistory(_ message: RelayMessage) {
    if message.type == "clear" || message.type == "stroke:start" {
      let operations = historyOperations()
      if historyCursor < operations.count {
        let retainedOperations = Array(operations.prefix(historyCursor))
        events = retainedOperations.flatMap(\.messages)
        replaceHistoryOperationsCache(with: retainedOperations)
        rebuildStrokeSequences()
      }
    }
    events.append(message)
    appendToHistoryOperationsCache(message)
    if message.type == "clear" || message.type == "stroke:end" {
      invalidateCommittedInkCache()
      let count = historyOperations().count
      historyCursor = min(count, max(0, message.historyCursor ?? count))
      historyRevision = max(historyRevision, message.historyRevision ?? historyRevision)
      publishHistoryAvailability()
    }
  }

  private func rebuildStrokeSequences() {
    lastStrokeSequence = [:]
    for message in events where message.type.hasPrefix("stroke:") {
      guard let strokeId = message.strokeId, let sequence = message.strokeSequence else { continue }
      lastStrokeSequence[strokeId] = max(lastStrokeSequence[strokeId] ?? -1, sequence)
    }
  }

  private func publishHistoryAvailability() {
    let count = historyOperations().count
    onHistoryAvailability?(historyCursor > 0, historyCursor < count)
  }

  private func drawGrid() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.setFillColor(NSColor(calibratedWhite: 0.82, alpha: 0.46).cgColor)
    let candidates: [CGFloat] = [12, 24, 48, 96, 192, 384, 768, 1536, 3072, 6144]
    let spacing = candidates.first(where: { $0 * worldScale >= 18 }) ?? candidates.last!
    let left = center.x - bounds.width / (2 * worldScale)
    let top = center.y - bounds.height / (2 * worldScale)
    var worldY = floor(top / spacing) * spacing
    while worldY <= top + bounds.height / worldScale + spacing {
      var worldX = floor(left / spacing) * spacing
      while worldX <= left + bounds.width / worldScale + spacing {
        let point = worldToScreen(CGPoint(x: worldX, y: worldY))
        context.fillEllipse(in: CGRect(x: point.x - 0.8, y: point.y - 0.8, width: 1.6, height: 1.6))
        worldX += spacing
      }
      worldY += spacing
    }
    context.restoreGState()
  }

  private func viewport(for aspect: CGFloat?) -> CGRect {
    let target = max(0.2, aspect ?? 1.5)
    let current = max(0.2, bounds.width / max(1, bounds.height))
    if current > target {
      let width = bounds.height * target
      return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }
    let height = bounds.width / target
    return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
  }

  private func worldPoint(_ point: RelayPoint, stroke: WhiteboardStroke) -> CGPoint {
    if stroke.coordinateSpace == "whiteboard-world-v1" {
      return CGPoint(x: point.x, y: point.y)
    }
    let aspect = max(0.2, stroke.canvasAspect ?? 1.5)
    return CGPoint(
      x: (CGFloat(point.x) - 0.5) * Self.worldHeight * aspect,
      y: (CGFloat(point.y) - 0.5) * Self.worldHeight
    )
  }

  private func screenPoint(_ point: RelayPoint, stroke: WhiteboardStroke) -> CGPoint {
    worldToScreen(worldPoint(point, stroke: stroke))
  }

  private func draw(point: RelayPoint, after previous: RelayPoint?, stroke: WhiteboardStroke, context: CGContext) {
    let location = screenPoint(point, stroke: stroke)
    let pressure = CGFloat(point.p > 0 ? point.p : 0.52)
    let legacyViewport = viewport(for: stroke.canvasAspect)
    let eraserWidth = stroke.coordinateSpace == "whiteboard-world-v1"
      ? stroke.eraserSize
      : (stroke.eraserRatio.map { $0 * min(legacyViewport.width, legacyViewport.height) } ?? stroke.eraserSize)
    let width = stroke.tool == "eraser"
      ? eraserWidth
      : (stroke.tool == "highlighter" ? max(1.2, stroke.width) : max(1.1, stroke.width * (0.38 + pressure * 0.85)))
    let screenWidth = width * zoom
    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    if stroke.tool == "eraser" {
      context.setBlendMode(.clear)
      context.setStrokeColor(NSColor.clear.cgColor)
      context.setFillColor(NSColor.clear.cgColor)
    } else {
      context.setBlendMode(.normal)
      let color = stroke.color.withAlphaComponent(stroke.tool == "highlighter" ? stroke.opacity : 1)
      context.setStrokeColor(color.cgColor)
      context.setFillColor(color.cgColor)
    }
    if let previous {
      let before = screenPoint(previous, stroke: stroke)
      context.setLineWidth(screenWidth)
      context.beginPath()
      context.move(to: before)
      context.addLine(to: location)
      context.strokePath()
    } else {
      context.fillEllipse(in: CGRect(x: location.x - screenWidth / 2, y: location.y - screenWidth / 2, width: screenWidth, height: screenWidth))
    }
    context.restoreGState()
  }

  private func drawHighlighter(_ stroke: WhiteboardStroke, context: CGContext) {
    guard let first = stroke.points.first else { return }
    let width = max(1.2, stroke.width * zoom)
    func location(_ point: RelayPoint) -> CGPoint {
      screenPoint(point, stroke: stroke)
    }
    context.saveGState()
    let color = stroke.color.withAlphaComponent(stroke.opacity)
    context.setBlendMode(.normal)
    context.setStrokeColor(color.cgColor)
    context.setFillColor(color.cgColor)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(width)
    if stroke.points.count == 1 {
      let point = location(first)
      context.fillEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
    } else {
      context.beginPath()
      context.move(to: location(first))
      for point in stroke.points.dropFirst() { context.addLine(to: location(point)) }
      context.strokePath()
    }
    context.restoreGState()
  }

  private func drawHover(_ context: CGContext) {
    guard let hover else { return }
    let hoverStroke = WhiteboardStroke(
      color: .clear, opacity: 1, width: 1, tool: hover.tool,
      eraserSize: hover.eraserSize, eraserRatio: hover.eraserRatio,
      canvasAspect: hover.aspect, coordinateSpace: hover.coordinateSpace, points: []
    )
    let point = screenPoint(hover.point, stroke: hoverStroke)
    let legacyViewport = viewport(for: hover.aspect)
    let diameter = hover.tool == "eraser"
      ? ((hover.coordinateSpace == "whiteboard-world-v1"
          ? hover.eraserSize
          : (hover.eraserRatio.map { $0 * min(legacyViewport.width, legacyViewport.height) } ?? hover.eraserSize)) * zoom)
      : 14
    context.saveGState()
    let color = hover.tool == "eraser" ? NSColor.systemGray : NSColor.systemBlue
    context.setStrokeColor(color.cgColor)
    context.setFillColor(color.withAlphaComponent(hover.tool == "eraser" ? 0.13 : 0.07).cgColor)
    context.setLineWidth(1.5)
    let rect = CGRect(
      x: point.x - diameter / 2,
      y: point.y - diameter / 2,
      width: diameter,
      height: diameter
    )
    context.fillEllipse(in: rect)
    context.strokeEllipse(in: rect)
    context.restoreGState()
  }

  private func drawEraserPreview(_ stroke: WhiteboardStroke, context: CGContext) {
    guard let last = stroke.points.last else { return }
    let point = screenPoint(last, stroke: stroke)
    let legacyViewport = viewport(for: stroke.canvasAspect)
    let diameter = (stroke.coordinateSpace == "whiteboard-world-v1"
      ? stroke.eraserSize
      : (stroke.eraserRatio.map { $0 * min(legacyViewport.width, legacyViewport.height) } ?? stroke.eraserSize)) * zoom
    context.saveGState()
    context.setStrokeColor(NSColor.systemGray.cgColor)
    context.setFillColor(NSColor.systemGray.withAlphaComponent(0.13).cgColor)
    context.setLineWidth(1.5)
    let rect = CGRect(
      x: point.x - diameter / 2,
      y: point.y - diameter / 2,
      width: diameter,
      height: diameter
    )
    context.fillEllipse(in: rect)
    context.strokeEllipse(in: rect)
    context.restoreGState()
  }
}

private extension NSColor {
  convenience init?(hex: String?) {
    guard var value = hex, value.hasPrefix("#") else { return nil }
    value.removeFirst()
    guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
    self.init(
      calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
      green: CGFloat((rgb >> 8) & 0xff) / 255,
      blue: CGFloat(rgb & 0xff) / 255,
      alpha: 1
    )
  }
}
