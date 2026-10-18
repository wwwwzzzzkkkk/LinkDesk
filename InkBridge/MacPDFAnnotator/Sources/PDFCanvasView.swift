import AppKit
import SwiftUI
import PDFKit

fileprivate struct ActiveInk {
  let page: PDFPage
  let color: NSColor
  let tool: String
  let pageWidth: CGFloat
  let usesPageCoordinates: Bool
  var pagePoints: [NSPoint]
  var pressures: [CGFloat]
}

fileprivate struct SavedInk {
  let id: String
  let pageIndex: Int
  let page: PDFPage
  let color: NSColor
  let tool: String
  let pageWidth: CGFloat
  let points: [NSPoint]
  let pressures: [CGFloat]
}

fileprivate struct OverlayStroke {
  let color: NSColor
  let widths: [CGFloat]
  let points: [NSPoint]
  let isHighlighter: Bool
}

fileprivate struct OverlayHover {
  let point: NSPoint
  let diameter: CGFloat
  let isEraser: Bool
}

fileprivate struct PDFViewAnchor {
  let page: PDFPage
  let point: NSPoint
  let viewportPosition: NSPoint
}

// Cap viewport synchronization at 120 Hz. ProMotion displays can consume the
// full stream; lower-refresh displays naturally coalesce to their render rate.
private let viewportSyncInterval: TimeInterval = 1.0 / 120.0
private let viewportInteriorOffsetMargin = 0.001
private let viewportInteractionIdleDelay: TimeInterval = 0.14
private let sharedMinimumZoom: CGFloat = 0.5
private let sharedMaximumZoom: CGFloat = 4

private func pageDisplayBounds(_ page: PDFPage) -> NSRect {
  page.bounds(for: .cropBox)
}

private func pagePointFromNormalized(_ point: RelayPoint, on page: PDFPage) -> NSPoint {
  pagePoint(
    from: PDFNormalizedPoint(x: point.x, y: point.y),
    bounds: pageDisplayBounds(page),
    rotation: page.rotation
  )
}

private func normalizedPointFromPage(_ point: NSPoint, on page: PDFPage) -> NSPoint {
  let normalized = normalizedPoint(
    from: point,
    bounds: pageDisplayBounds(page),
    rotation: page.rotation
  )
  return NSPoint(x: normalized.x, y: normalized.y)
}

private func pageVisualWidth(_ page: PDFPage) -> CGFloat {
  visualPageWidth(bounds: pageDisplayBounds(page), rotation: page.rotation)
}

private final class EventMonitorToken: @unchecked Sendable {
  let value: Any
  init(_ value: Any) { self.value = value }
}

/// Draw each sampled segment independently so the line can follow the pen's
/// pressure instead of flattening an entire stroke to one fixed width.
fileprivate func drawVariableStroke(_ stroke: OverlayStroke, in context: CGContext) {
  guard let first = stroke.points.first else { return }
  let renderPoints: [NSPoint]
  if stroke.points.count < 3 {
    renderPoints = stroke.points
  } else {
    renderPoints = stroke.points.indices.map { index in
      guard index > 0, index < stroke.points.count - 1 else { return stroke.points[index] }
      let previous = stroke.points[index - 1]
      let current = stroke.points[index]
      let next = stroke.points[index + 1]
      return NSPoint(
        x: previous.x * 0.125 + current.x * 0.75 + next.x * 0.125,
        y: previous.y * 0.125 + current.y * 0.75 + next.y * 0.125
      )
    }
  }
  let fallbackWidth = max(0.6, stroke.widths.last ?? 1)
  func width(at index: Int) -> CGFloat {
    max(0.6, stroke.widths.indices.contains(index) ? stroke.widths[index] : fallbackWidth)
  }

  context.setAllowsAntialiasing(true)
  context.setShouldAntialias(true)
  context.setStrokeColor(stroke.color.cgColor)
  context.setFillColor(stroke.color.cgColor)
  context.setLineCap(.round)
  context.setLineJoin(.round)

  if renderPoints.count == 1 {
    let diameter = width(at: 0)
    context.fillEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter))
    return
  }

  if stroke.isHighlighter {
    context.setLineWidth(fallbackWidth)
    context.beginPath()
    context.move(to: renderPoints[0])
    for point in renderPoints.dropFirst() { context.addLine(to: point) }
    context.strokePath()
    return
  }

  for index in 1..<renderPoints.count {
    context.setLineWidth((width(at: index - 1) + width(at: index)) / 2)
    context.beginPath()
    context.move(to: renderPoints[index - 1])
    context.addLine(to: renderPoints[index])
    context.strokePath()
  }
}

private final class PageInkAnnotation: PDFAnnotation {
  let strokes: [OverlayStroke]

  init(bounds: NSRect, strokes: [OverlayStroke]) {
    self.strokes = strokes
    super.init(bounds: bounds, forType: .square, withProperties: nil)
    color = .clear
    interiorColor = .clear
    userName = "LinkDesk"
    border = PDFBorder()
    border?.lineWidth = 0
  }

  required init?(coder: NSCoder) {
    strokes = []
    super.init(coder: coder)
  }

  override func draw(with box: PDFDisplayBox, in context: CGContext) {
    context.saveGState()
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    for stroke in strokes where !stroke.points.isEmpty {
      drawVariableStroke(stroke, in: context)
    }
    context.restoreGState()
  }
}

private final class TrackingPDFView: PDFView {
  var onViewportChanged: (() -> Void)?
  var onMagnify: ((NSEvent) -> Void)?

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    DispatchQueue.main.async { [weak self] in self?.onViewportChanged?() }
  }

  override func magnify(with event: NSEvent) {
    onMagnify?(event)
  }
}

final class LiveInkOverlay: NSView {
  fileprivate var strokes: [OverlayStroke] = [] { didSet { needsDisplay = true } }
  fileprivate var hover: OverlayHover? { didSet { needsDisplay = true } }

  override var wantsDefaultClipping: Bool { true }

  // This view only paints remote ink and the hover cursor. Let PDFKit receive
  // mouse clicks and drags so its native text selection and copy actions keep
  // working underneath the overlay.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: bounds)
    for stroke in strokes where !stroke.points.isEmpty {
      drawVariableStroke(stroke, in: context)
    }
    if let hover {
      let diameter = max(8, hover.diameter)
      let rect = CGRect(
        x: hover.point.x - diameter / 2,
        y: hover.point.y - diameter / 2,
        width: diameter,
        height: diameter
      )
      let color = hover.isEraser ? NSColor.systemGray : NSColor.systemBlue
      context.setStrokeColor(color.cgColor)
      context.setFillColor(color.withAlphaComponent(hover.isEraser ? 0.13 : 0.07).cgColor)
      context.setLineWidth(hover.isEraser ? 1.5 : 1.4)
      context.fillEllipse(in: rect)
      context.strokeEllipse(in: rect)
    }
  }
}

final class PDFCanvasView: NSView {
  private let pdfView = TrackingPDFView()
  private let overlay = LiveInkOverlay()
  private var activeInks: [String: ActiveInk] = [:]
  private var lastStrokeSequence: [String: Int] = [:]
  private var savedInks: [SavedInk] = []
  private var historyMessages: [RelayMessage] = []
  private var historyCursor = 0
  private var historyRevision = 0
  private var isReplayingHistory = false
  private var hoverSource: (page: PDFPage, point: NSPoint, eraserRatio: Double?)?
  private var activeErasers: Set<String> = []
  private var pageInkAnnotations: [ObjectIdentifier: PageInkAnnotation] = [:]
  private var previewWorkItem: DispatchWorkItem?
  private var viewportWorkItem: DispatchWorkItem?
  private var viewportFinalWorkItem: DispatchWorkItem?
  private var remoteViewportWorkItem: DispatchWorkItem?
  private var remoteViewportSettleWorkItem: DispatchWorkItem?
  private var pendingRemoteViewport: PDFViewport?
  private var isApplyingRemoteViewport = false
  private var isApplyingLocalZoom = false
  private var remoteViewportGeneration = 0
  private var remoteViewportScheduleGeneration = 0
  private var localViewportScheduleGeneration = 0
  private var localZoomGeneration = 0
  private var lastViewportPublishTime: TimeInterval = 0
  private var lastRemoteViewportApplyTime: TimeInterval = 0
  private var ignoreRemoteViewportUntil: TimeInterval = 0
  private var suppressPassiveViewportUntil: TimeInterval = 0
  private var localViewportInteractionId: String?
  private var inputEventMonitor: EventMonitorToken?
  private var observedClipViews: [NSClipView] = []
  private var searchSelections: [PDFSelection] = []
  private var currentSearchIndex: Int?
  private var searchWorkItem: DispatchWorkItem?
  var onPreview: ((String) -> Void)?
  var onViewport: ((PDFViewport) -> Void)?
  var onHistoryAvailability: ((Bool, Bool) -> Void)?
  var onSearchState: ((Int, Int) -> Void)?

  var document: PDFDocument? {
    didSet {
      clearSearch()
      cancelScheduledViewportUpdate()
      cancelLocalViewportInteraction()
      cancelRemoteViewportApplication()
      lastViewportPublishTime = 0
      lastRemoteViewportApplyTime = 0
      suppressPassiveViewportUntil = 0
      localZoomGeneration += 1
      isApplyingLocalZoom = false
      pdfView.document = document
      pdfView.autoScales = true
      if let firstPage = document?.page(at: 0) {
        pdfView.go(to: firstPage)
      }
      activeInks = [:]
      lastStrokeSequence = [:]
      savedInks = []
      historyMessages = []
      historyCursor = 0
      historyRevision = 0
      hoverSource = nil
      activeErasers = []
      clearPageInkAnnotations()
      refreshOverlay()
      publishHistoryAvailability()
      schedulePreviewUpdate(delay: 0.15)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pdfView.autoScales = true
        if let firstPage = self.document?.page(at: 0) {
          self.pdfView.go(to: firstPage)
          self.scrollToDocumentEdge(top: true)
        }
        self.observePDFScrollIfNeeded()
        self.refreshOverlay()
        self.scheduleViewportUpdate(delay: 0.12)
      }
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    layer?.backgroundColor = NSColor(DT.canvas).cgColor
    pdfView.backgroundColor = NSColor(DT.canvas)
  }

  override init(frame frameRect: NSRect = .zero) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(DT.canvas).cgColor
    layer?.masksToBounds = true
    overlay.wantsLayer = true
    overlay.layer?.masksToBounds = true
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displayBox = .cropBox
    pdfView.displaysPageBreaks = true
    pdfView.pageBreakMargins = NSEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
    pdfView.backgroundColor = NSColor(DT.canvas)
    pdfView.onViewportChanged = { [weak self] in self?.viewportDidChange(userInitiated: true) }
    pdfView.onMagnify = { [weak self] event in self?.captureLocalMagnify(event) }
    addSubview(pdfView)
    addSubview(overlay)
    // PDFKit's private document scroll view often consumes trackpad events
    // before TrackingPDFView receives them. Observe both gesture families at
    // the window boundary: scrolling stays native (including inertia and both
    // axes), while pinch is consumed and applied around its actual focus.
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.scrollWheel, .magnify],
      handler: { [weak self] event in
        guard let self else { return event }
        if event.type == .magnify, self.captureLocalMagnify(event) {
          return nil
        }
        if event.type == .scrollWheel {
          self.captureLocalScrollWheel(event)
        }
        return event
      }
    ) {
      inputEventMonitor = EventMonitorToken(monitor)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: .PDFViewPageChanged, object: pdfView)
    NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: .PDFViewScaleChanged, object: pdfView)
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    if let inputEventMonitor {
      NSEvent.removeMonitor(inputEventMonitor.value)
    }
    NotificationCenter.default.removeObserver(self)
  }

  override func layout() {
    super.layout()
    pdfView.frame = bounds
    overlay.frame = bounds
    observePDFScrollIfNeeded()
    refreshOverlay()
    schedulePreviewUpdate()
  }

  @objc private func viewChanged() {
    observePDFScrollIfNeeded()
    refreshOverlay()
    schedulePreviewUpdate()
  }

  func search(_ query: String) {
    searchWorkItem?.cancel()
    resetSearchPresentation()
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty, document != nil else { return }

    let workItem = DispatchWorkItem { [weak self] in
      self?.performSearch(normalizedQuery)
    }
    searchWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
  }

  func nextSearchResult() {
    guard !searchSelections.isEmpty else { return }
    let next = ((currentSearchIndex ?? -1) + 1) % searchSelections.count
    focusSearchResult(at: next)
  }

  func previousSearchResult() {
    guard !searchSelections.isEmpty else { return }
    let previous = ((currentSearchIndex ?? 0) - 1 + searchSelections.count) % searchSelections.count
    focusSearchResult(at: previous)
  }

  func clearSearch() {
    searchWorkItem?.cancel()
    searchWorkItem = nil
    resetSearchPresentation()
  }

  private func performSearch(_ query: String) {
    searchWorkItem = nil
    guard let document else { return }
    searchSelections = document.findString(
      query,
      withOptions: [.caseInsensitive, .diacriticInsensitive]
    )
    for selection in searchSelections {
      selection.color = NSColor.systemYellow.withAlphaComponent(0.42)
    }
    pdfView.highlightedSelections = searchSelections
    guard !searchSelections.isEmpty else {
      onSearchState?(0, 0)
      return
    }
    focusSearchResult(at: 0)
  }

  private func focusSearchResult(at index: Int) {
    guard searchSelections.indices.contains(index) else { return }
    if let currentSearchIndex, searchSelections.indices.contains(currentSearchIndex) {
      searchSelections[currentSearchIndex].color = NSColor.systemYellow.withAlphaComponent(0.42)
    }
    currentSearchIndex = index
    let selection = searchSelections[index]
    selection.color = NSColor.systemOrange.withAlphaComponent(0.72)
    pdfView.highlightedSelections = searchSelections
    pdfView.setCurrentSelection(selection, animate: true)
    pdfView.go(to: selection)
    onSearchState?(index + 1, searchSelections.count)

    // Search navigation changes the visible page just like manual scrolling;
    // keep the tablet viewport and remote ink preview aligned with it.
    refreshOverlay()
    schedulePreviewUpdate(delay: 0.04)
    scheduleViewportUpdate(delay: 0.04)
  }

  private func resetSearchPresentation() {
    searchSelections = []
    currentSearchIndex = nil
    pdfView.highlightedSelections = []
    pdfView.setCurrentSelection(nil, animate: false)
    onSearchState?(0, 0)
  }

  private func viewportDidChange(userInitiated: Bool = false) {
    // The overlay is a sibling of PDFView, so it must be converted again after
    // every two-finger scroll; otherwise it would remain pinned to the window.
    // A real trackpad event always takes ownership immediately, even if a
    // delayed PDFKit layout callback is still finishing a remote navigation.
    if userInitiated && isApplyingRemoteViewport {
      cancelRemoteViewportApplication()
    }
    refreshOverlay()
    schedulePreviewUpdate()
    if userInitiated {
      scheduleViewportUpdate()
    }
  }

  private func captureLocalScrollWheel(_ event: NSEvent) {
    guard contains(event) else { return }
    beginLocalViewportInteraction()
    scheduleLocalViewportInteractionEnd()
    ignoreRemoteViewportUntil = ProcessInfo.processInfo.systemUptime + viewportInteractionIdleDelay
    suppressPassiveViewportUntil = 0
    if isApplyingRemoteViewport {
      cancelRemoteViewportApplication()
    }
    DispatchQueue.main.async { [weak self] in
      self?.viewportDidChange(userInitiated: true)
    }
  }

  @discardableResult
  private func captureLocalMagnify(_ event: NSEvent) -> Bool {
    guard contains(event), document != nil else { return false }
    if isApplyingRemoteViewport {
      cancelRemoteViewportApplication()
    }
    ignoreRemoteViewportUntil = ProcessInfo.processInfo.systemUptime + viewportInteractionIdleDelay
    suppressPassiveViewportUntil = 0
    let focus = convert(event.locationInWindow, from: nil)
    magnify(with: event.magnification, around: focus)
    return true
  }

  private func contains(_ event: NSEvent) -> Bool {
    guard let window, event.window === window else { return false }
    return bounds.contains(convert(event.locationInWindow, from: nil))
  }

  private func observePDFScrollIfNeeded() {
    let clipViews = allClipViews(in: pdfView)
    let current = Set(observedClipViews.map(ObjectIdentifier.init))
    let next = Set(clipViews.map(ObjectIdentifier.init))
    guard current != next else { return }
    for clipView in observedClipViews {
      NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
    }
    observedClipViews = clipViews
    for clipView in observedClipViews {
      clipView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged), name: NSView.boundsDidChangeNotification, object: clipView)
    }
    if let scrollView = firstScrollView(in: pdfView) {
      scrollView.hasHorizontalScroller = true
      scrollView.autohidesScrollers = true
      scrollView.usesPredominantAxisScrolling = false
      scrollView.horizontalScrollElasticity = .automatic
      scrollView.verticalScrollElasticity = .automatic
      // Pinch is handled above so PDFKit cannot perform a second, center-based
      // scale after the focal-point-preserving update.
      scrollView.allowsMagnification = false
    }
  }

  @objc private func scrollBoundsChanged() {
    // Remote viewport application owns its overlay refresh. PDFKit can emit
    // several private clip-view notifications for one scroll position; doing
    // a full ink-coordinate rebuild for each notification makes the PDF lag
    // behind the incoming gesture stream.
    if isApplyingRemoteViewport { return }
    let mayPublish = !isApplyingRemoteViewport
      && ProcessInfo.processInfo.systemUptime >= suppressPassiveViewportUntil
    viewportDidChange(userInitiated: mayPublish)
  }

  private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for child in view.subviews {
      if let scrollView = firstScrollView(in: child) { return scrollView }
    }
    return nil
  }

  private func allClipViews(in view: NSView) -> [NSClipView] {
    var result: [NSClipView] = []
    if let clipView = view as? NSClipView {
      result.append(clipView)
    }
    for child in view.subviews {
      result.append(contentsOf: allClipViews(in: child))
    }
    return result
  }

  func handle(_ message: RelayMessage) {
    guard document != nil else { return }
    if message.type == "history:undo" || message.type == "history:redo" {
      applyHistory(message)
      return
    }
    if message.type == "clear" && message.phase == "document-switch" {
      resetRenderedInk()
      historyMessages = []
      historyCursor = 0
      historyRevision = max(historyRevision, message.historyRevision ?? 0)
      publishHistoryAvailability()
      return
    }
    if message.type.hasPrefix("stroke:"),
       let strokeId = message.strokeId,
       let sequence = message.strokeSequence {
      if sequence <= (lastStrokeSequence[strokeId] ?? -1) { return }
      lastStrokeSequence[strokeId] = sequence
    }
    if message.type == "clear" || message.type.hasPrefix("stroke:") {
      recordHistory(message)
    }
    processDrawing(message)
  }

  private func processDrawing(_ message: RelayMessage) {
    switch message.type {
    case "stroke:start": begin(message)
    case "stroke:move": append(message)
    case "stroke:replace": replace(message)
    case "stroke:end": end(message)
    case "cursor:move": updateHover(message)
    case "cursor:hide": clearHover()
    case "clear": clearCreatedAnnotations()
    default: break
    }
  }

  func zoomIn() { zoom(by: 1.25) }
  func zoomOut() { zoom(by: 0.8) }

  func zoomToFit() {
    beginLocalViewportInteraction()
    pdfView.autoScales = true
    refreshOverlay()
    schedulePreviewUpdate(delay: 0.05)
    scheduleLocalViewportInteractionEnd(delay: 0.12)
  }

  func clearCreatedAnnotations() {
    resetRenderedInk(schedulePreview: !isReplayingHistory)
  }

  func restoreHistory(_ messages: [RelayMessage], cursor: Int?, revision: Int?) {
    guard document != nil else { return }
    historyMessages = messages.filter {
      $0.type == "clear" || $0.type.hasPrefix("stroke:")
    }
    let count = historyOperations().count
    historyCursor = min(count, max(0, cursor ?? count))
    historyRevision = max(0, revision ?? historyRevision)
    rebuildFromHistory()
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
    rebuildFromHistory()
  }

  private func recordHistory(_ message: RelayMessage) {
    if message.type == "clear" || message.type == "stroke:start" {
      let operations = historyOperations()
      if historyCursor < operations.count {
        historyMessages = operations.prefix(historyCursor).flatMap(\.messages)
      }
    }
    historyMessages.append(message)
    if message.type == "clear" || message.type == "stroke:end" {
      let count = historyOperations().count
      historyCursor = min(count, max(0, message.historyCursor ?? count))
      historyRevision = max(historyRevision, message.historyRevision ?? historyRevision)
      publishHistoryAvailability()
    }
  }

  private struct HistoryOperation {
    let id: String
    var messages: [RelayMessage]
  }

  private func historyOperations() -> [HistoryOperation] {
    var operations: [HistoryOperation] = []
    var indexes: [String: Int] = [:]
    for (index, message) in historyMessages.enumerated() {
      guard message.type == "clear" || message.type.hasPrefix("stroke:") else { continue }
      let id: String
      if let operationId = message.operationId, !operationId.isEmpty {
        id = operationId
      } else if let strokeId = message.strokeId, message.type.hasPrefix("stroke:") {
        id = "stroke:\(strokeId)"
      } else {
        id = "clear:\(index)"
      }
      if let existing = indexes[id] {
        operations[existing].messages.append(message)
      } else {
        indexes[id] = operations.count
        operations.append(HistoryOperation(id: id, messages: [message]))
      }
    }
    return operations
  }

  private func rebuildFromHistory() {
    resetRenderedInk(schedulePreview: false)
    isReplayingHistory = true
    let operations = historyOperations()
    historyCursor = min(operations.count, max(0, historyCursor))
    for operation in operations.prefix(historyCursor) {
      for message in operation.messages {
        if message.type.hasPrefix("stroke:"),
           let strokeId = message.strokeId,
           let sequence = message.strokeSequence {
          if sequence <= (lastStrokeSequence[strokeId] ?? -1) { continue }
          lastStrokeSequence[strokeId] = sequence
        }
        processDrawing(message)
      }
    }
    isReplayingHistory = false
    activeInks = [:]
    activeErasers = []
    refreshOverlay()
    schedulePreviewUpdate(delay: 0.04)
    publishHistoryAvailability()
  }

  private func resetRenderedInk(schedulePreview: Bool = true) {
    savedInks = []
    activeInks = [:]
    activeErasers = []
    lastStrokeSequence = [:]
    clearPageInkAnnotations()
    refreshOverlay()
    if schedulePreview { schedulePreviewUpdate(delay: 0.05) }
  }

  private func publishHistoryAvailability() {
    let count = historyOperations().count
    onHistoryAvailability?(historyCursor > 0, historyCursor < count)
  }

  func export(to url: URL) -> Bool {
    guard let document,
          let sourceData = document.dataRepresentation(),
          let output = PDFDocument(data: sourceData) else { return false }
    for ink in savedInks {
      guard let page = output.page(at: ink.pageIndex) else { continue }
      addStandardInkAnnotations(for: ink, to: page)
    }
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard output.write(to: temporary) else { return false }
    do {
      let manager = FileManager.default
      if manager.fileExists(atPath: url.path) {
        _ = try manager.replaceItemAt(url, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: url)
      }
      return true
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      return false
    }
  }

  private func addStandardInkAnnotations(for ink: SavedInk, to page: PDFPage) {
    guard !ink.points.isEmpty else { return }
    let widths = ink.pressures.map { strokeWidth(base: ink.pageWidth, pressure: $0, tool: ink.tool) }
    var pathsByWidth: [CGFloat: [NSBezierPath]] = [:]
    if ink.points.count == 1 {
      let width = max(0.6, widths.first ?? ink.pageWidth)
      let path = NSBezierPath()
      path.move(to: ink.points[0])
      path.line(to: NSPoint(x: ink.points[0].x + 0.01, y: ink.points[0].y + 0.01))
      pathsByWidth[quantizedAnnotationWidth(width), default: []].append(path)
    } else if ink.tool == "highlighter" {
      let path = NSBezierPath()
      path.move(to: ink.points[0])
      for point in ink.points.dropFirst() { path.line(to: point) }
      pathsByWidth[quantizedAnnotationWidth(widths.first ?? ink.pageWidth), default: []].append(path)
    } else {
      for index in 1..<ink.points.count {
        let width = ((widths.indices.contains(index - 1) ? widths[index - 1] : ink.pageWidth)
          + (widths.indices.contains(index) ? widths[index] : ink.pageWidth)) / 2
        let path = NSBezierPath()
        path.move(to: ink.points[index - 1])
        path.line(to: ink.points[index])
        pathsByWidth[quantizedAnnotationWidth(width), default: []].append(path)
      }
    }
    let bounds = page.bounds(for: .cropBox)
    for (width, pagePaths) in pathsByWidth {
      let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
      annotation.color = ink.color
      annotation.userName = "LinkDesk"
      annotation.contents = "InkBridge \(ink.id)"
      annotation.shouldDisplay = true
      annotation.shouldPrint = true
      let border = PDFBorder()
      border.lineWidth = width
      annotation.border = border
      for pagePath in pagePaths {
        let annotationPath = NSBezierPath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for elementIndex in 0..<pagePath.elementCount {
          let element = pagePath.element(at: elementIndex, associatedPoints: &points)
          let point = NSPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY)
          if element == .moveTo { annotationPath.move(to: point) }
          else if element == .lineTo { annotationPath.line(to: point) }
        }
        annotation.add(annotationPath)
      }
      page.addAnnotation(annotation)
    }
  }

  private func quantizedAnnotationWidth(_ width: CGFloat) -> CGFloat {
    max(0.6, (width * 4).rounded() / 4)
  }

  private func zoom(by factor: CGFloat, around focusInCanvas: NSPoint? = nil) {
    guard document != nil else { return }
    let anchor = focusInCanvas.flatMap { currentViewAnchor(at: $0) } ?? currentViewAnchor()
    let fitted = max(0.1, pdfView.scaleFactorForSizeToFit)
    let minimumScale = max(pdfView.minScaleFactor, fitted * sharedMinimumZoom)
    let maximumScale = min(pdfView.maxScaleFactor, fitted * sharedMaximumZoom)
    let targetScale = max(minimumScale, min(maximumScale, pdfView.scaleFactor * factor))
    guard abs(targetScale - pdfView.scaleFactor) > 0.0001 else { return }

    beginLocalViewportInteraction()
    localZoomGeneration += 1
    let generation = localZoomGeneration
    isApplyingLocalZoom = true
    cancelScheduledViewportUpdate()
    pdfView.autoScales = false
    pdfView.scaleFactor = targetScale
    pdfView.layoutSubtreeIfNeeded()
    if let anchor { restoreViewAnchor(anchor) }
    refreshOverlay()
    schedulePreviewUpdate(delay: 0.05)
    // PDFKit lays out continuous pages asynchronously after scaleFactor
    // changes. Restore the same PDF point during its layout passes so the
    // internal scroll view cannot fall back to the document top.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.localZoomGeneration == generation else { return }
      if let anchor { self.restoreViewAnchor(anchor) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
      guard let self, self.localZoomGeneration == generation else { return }
      if let anchor { self.restoreViewAnchor(anchor) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
      guard let self, self.localZoomGeneration == generation else { return }
      if let anchor { self.restoreViewAnchor(anchor) }
      self.isApplyingLocalZoom = false
      self.refreshOverlay()
      self.schedulePreviewUpdate(delay: 0.02)
      self.finishLocalViewportInteraction()
    }
  }

  private func currentViewAnchor() -> PDFViewAnchor? {
    guard let scrollView = firstScrollView(in: pdfView) else { return nil }
    let clipView = scrollView.contentView
    let visible = clipView.bounds
    guard visible.width > 0, visible.height > 0 else { return nil }
    let centerInClip = NSPoint(x: visible.midX, y: visible.midY)
    let centerInPDFView = pdfView.convert(centerInClip, from: clipView)
    return viewAnchor(at: centerInPDFView, viewportPosition: NSPoint(x: 0.5, y: 0.5))
  }

  private func currentViewAnchor(at focusInCanvas: NSPoint) -> PDFViewAnchor? {
    guard let scrollView = firstScrollView(in: pdfView) else { return nil }
    let clipView = scrollView.contentView
    let visible = clipView.bounds
    guard visible.width > 0, visible.height > 0 else { return nil }
    let focusInPDFView = pdfView.convert(focusInCanvas, from: self)
    let focusInClip = clipView.convert(focusInPDFView, from: pdfView)
    let viewportPosition = NSPoint(
      x: min(1, max(0, (focusInClip.x - visible.minX) / visible.width)),
      y: min(1, max(0, (focusInClip.y - visible.minY) / visible.height))
    )
    return viewAnchor(at: focusInPDFView, viewportPosition: viewportPosition)
  }

  private func viewAnchor(at pointInPDFView: NSPoint, viewportPosition: NSPoint) -> PDFViewAnchor? {
    guard let page = pdfView.page(for: pointInPDFView, nearest: true) else { return nil }
    return PDFViewAnchor(
      page: page,
      point: pdfView.convert(pointInPDFView, to: page),
      viewportPosition: viewportPosition
    )
  }

  private func restoreViewAnchor(_ anchor: PDFViewAnchor, performLayout: Bool = true) {
    guard let scrollView = firstScrollView(in: pdfView), scrollView.documentView != nil else { return }
    if performLayout {
      pdfView.layoutSubtreeIfNeeded()
      scrollView.layoutSubtreeIfNeeded()
    }

    let clipView = scrollView.contentView
    let visible = clipView.bounds
    guard visible.width > 0, visible.height > 0 else { return }

    // Convert through the clip view after PDFKit has laid out the new scale.
    // In clip-view coordinates this is the point's absolute position in the
    // scrollable PDF document, so changing bounds.origin keeps it at exactly
    // the same place in the viewport without asking PDFKit to navigate pages.
    let pointInPDFView = pdfView.convert(anchor.point, from: anchor.page)
    let pointInClip = clipView.convert(pointInPDFView, from: pdfView)
    let targetOrigin = NSPoint(
      x: pointInClip.x - visible.width * anchor.viewportPosition.x,
      y: pointInClip.y - visible.height * anchor.viewportPosition.y
    )
    let constrained = clipView.constrainBoundsRect(NSRect(origin: targetOrigin, size: visible.size))
    clipView.scroll(to: constrained.origin)
    scrollView.reflectScrolledClipView(clipView)
  }

  private func magnify(with amount: CGFloat, around focus: NSPoint) {
    // Trackpad pinch events provide a small signed delta, not a multiplier.
    zoom(by: max(0.5, 1 + amount), around: focus)
  }

  private func begin(_ message: RelayMessage) {
    guard let strokeId = message.strokeId, let point = message.point, let page = page(for: message) else { return }
    let usesPageCoordinates = message.pageIndex != nil
    if message.tool == "eraser" {
      activeErasers.insert(strokeId)
      if !isReplayingHistory {
        updateEraserHover(
          point,
          page: page,
          usesPageCoordinates: usesPageCoordinates,
          ratio: message.eraserRatio ?? (message.eraserSize ?? 48) / 1_000
        )
      }
      erase(at: point, on: page, usesPageCoordinates: usesPageCoordinates, ratio: message.eraserRatio ?? (message.eraserSize ?? 48) / 1_000)
      return
    }
    activeInks[strokeId] = ActiveInk(
      page: page,
      color: color(from: message.color).withAlphaComponent(
        message.tool == "highlighter" ? CGFloat(min(1, max(0.05, message.opacity ?? 0.32))) : 1
      ),
      tool: message.tool == "highlighter" ? "highlighter" : "ink",
      pageWidth: pageLineWidth(from: message.width ?? 4.5, ratio: message.widthRatio, on: page),
      usesPageCoordinates: usesPageCoordinates,
      pagePoints: [pagePoint(from: point, on: page, usesPageCoordinates: usesPageCoordinates)],
      pressures: [pressure(from: point)]
    )
    if !isReplayingHistory { refreshOverlay() }
  }

  private func append(_ message: RelayMessage) {
    guard let strokeId = message.strokeId, let points = message.points else { return }
    if message.tool == "eraser" {
      let ratio = message.eraserRatio ?? (message.eraserSize ?? 48) / 1_000
      let usesPageCoordinates = message.pageIndex != nil
      if !isReplayingHistory,
         let point = points.last,
         let page = usesPageCoordinates ? page(for: message) : page(for: point) {
        updateEraserHover(point, page: page, usesPageCoordinates: usesPageCoordinates, ratio: ratio)
      }
      for point in points {
        guard let page = usesPageCoordinates ? page(for: message) : page(for: point) else { continue }
        erase(at: point, on: page, usesPageCoordinates: usesPageCoordinates, ratio: ratio)
      }
      return
    }
    guard var ink = activeInks[strokeId] else { return }
    for point in points {
      ink.pagePoints.append(pagePoint(from: point, on: ink.page, usesPageCoordinates: ink.usesPageCoordinates))
      ink.pressures.append(pressure(from: point))
    }
    activeInks[strokeId] = ink
    if !isReplayingHistory { refreshOverlay() }
  }

  private func replace(_ message: RelayMessage) {
    guard let strokeId = message.strokeId, var ink = activeInks[strokeId],
          let points = message.points, !points.isEmpty else { return }
    ink.pagePoints = points.map {
      pagePoint(from: $0, on: ink.page, usesPageCoordinates: ink.usesPageCoordinates)
    }
    ink.pressures = points.map { pressure(from: $0) }
    activeInks[strokeId] = ink
    if !isReplayingHistory { refreshOverlay() }
  }

  private func end(_ message: RelayMessage) {
    if let strokeId = message.strokeId, activeErasers.remove(strokeId) != nil {
      if !isReplayingHistory { clearHover() }
      return
    }
    guard let strokeId = message.strokeId, let ink = activeInks.removeValue(forKey: strokeId), !ink.pagePoints.isEmpty else { return }
    let pageIndex = document?.index(for: ink.page) ?? NSNotFound
    guard pageIndex != NSNotFound else { return }
    savedInks.append(SavedInk(
      id: strokeId,
      pageIndex: pageIndex,
      page: ink.page,
      color: ink.color,
      tool: ink.tool,
      pageWidth: ink.pageWidth,
      points: ink.pagePoints,
      pressures: ink.pressures
    ))
    if !isReplayingHistory {
      refreshOverlay()
      schedulePreviewUpdate(delay: 0.08)
    }
  }

  private func updateHover(_ message: RelayMessage) {
    guard let point = message.point, let page = page(for: message) else { return }
    let usesPageCoordinates = message.pageIndex != nil
    hoverSource = (
      page,
      pagePoint(from: point, on: page, usesPageCoordinates: usesPageCoordinates),
      message.tool == "eraser"
        ? (message.eraserRatio ?? (message.eraserSize ?? 48) / 1_000)
        : nil
    )
    refreshOverlay()
  }

  private func updateEraserHover(
    _ point: RelayPoint,
    page: PDFPage,
    usesPageCoordinates: Bool,
    ratio: Double
  ) {
    hoverSource = (
      page,
      pagePoint(from: point, on: page, usesPageCoordinates: usesPageCoordinates),
      ratio
    )
    refreshOverlay()
  }

  private func clearHover() {
    hoverSource = nil
    refreshOverlay()
  }

  private func erase(at point: RelayPoint, on page: PDFPage, usesPageCoordinates: Bool, ratio: Double) {
    let pointOnPage = pagePoint(from: point, on: page, usesPageCoordinates: usesPageCoordinates)
    let radius = pageVisualWidth(page) * ratio / 2
    savedInks.removeAll { ink in
      ink.page === page && ink.points.contains { $0.distance(to: pointOnPage) <= radius }
    }
    if !isReplayingHistory {
      refreshOverlay()
      schedulePreviewUpdate()
    }
  }

  private func refreshOverlay() {
    // Render retained ink in a high-resolution AppKit overlay. Its points are
    // recalculated from PDF coordinates on every scroll, so it remains locked
    // to the page while staying sharp at the current zoom level.
    let completed = savedInks.map { ink in
      let baseWidth = previewWidth(for: ink)
      return OverlayStroke(
        color: ink.color,
        widths: ink.pressures.map { strokeWidth(base: baseWidth, pressure: $0, tool: ink.tool) },
        points: ink.points.map { pdfView.convert($0, from: ink.page) },
        isHighlighter: ink.tool == "highlighter"
      )
    }
    let active = activeInks.values.map { ink in
      let baseWidth = previewWidth(pageWidth: ink.pageWidth, on: ink.page)
      return OverlayStroke(
        color: ink.color,
        widths: ink.pressures.map { strokeWidth(base: baseWidth, pressure: $0, tool: ink.tool) },
        points: ink.pagePoints.map { pdfView.convert($0, from: ink.page) },
        isHighlighter: ink.tool == "highlighter"
      )
    }
    overlay.strokes = completed + active
    overlay.hover = hoverSource.map { source in
      let pageFrame = pdfView.convert(pageDisplayBounds(source.page), from: source.page)
      let diameter = source.eraserRatio.map {
        max(12, abs(pageFrame.width) * CGFloat($0))
      } ?? 10
      return OverlayHover(
        point: pdfView.convert(source.point, from: source.page),
        diameter: diameter,
        isEraser: source.eraserRatio != nil
      )
    }
  }

  private func rebuildPageInkAnnotations() {
    clearPageInkAnnotations()
    var grouped: [ObjectIdentifier: (page: PDFPage, strokes: [OverlayStroke])] = [:]
    for ink in savedInks {
      let key = ObjectIdentifier(ink.page)
      var group = grouped[key] ?? (ink.page, [])
      group.strokes.append(OverlayStroke(
        color: ink.color,
        widths: ink.pressures.map { strokeWidth(base: ink.pageWidth, pressure: $0, tool: ink.tool) },
        points: ink.points,
        isHighlighter: ink.tool == "highlighter"
      ))
      grouped[key] = group
    }
    for (key, group) in grouped {
      let annotation = PageInkAnnotation(bounds: pageDisplayBounds(group.page), strokes: group.strokes)
      group.page.addAnnotation(annotation)
      pageInkAnnotations[key] = annotation
    }
    pdfView.needsDisplay = true
  }

  private func clearPageInkAnnotations() {
    for annotation in pageInkAnnotations.values { annotation.page?.removeAnnotation(annotation) }
    pageInkAnnotations = [:]
  }

  private func previewWidth(for ink: SavedInk) -> CGFloat { previewWidth(pageWidth: ink.pageWidth, on: ink.page) }

  private func previewWidth(pageWidth: CGFloat, on page: PDFPage) -> CGFloat {
    let bounds = pageDisplayBounds(page)
    let start = pdfView.convert(NSPoint(x: bounds.minX, y: bounds.minY), from: page)
    let end = pdfView.convert(NSPoint(x: bounds.minX + pageWidth, y: bounds.minY), from: page)
    return max(1.5, abs(end.x - start.x))
  }

  private func draw(_ ink: SavedInk, in context: CGContext) {
    drawVariableStroke(
      OverlayStroke(
        color: ink.color,
        widths: ink.pressures.map { strokeWidth(base: ink.pageWidth, pressure: $0, tool: ink.tool) },
        points: ink.points,
        isHighlighter: ink.tool == "highlighter"
      ),
      in: context
    )
  }

  private func page(for point: RelayPoint) -> PDFPage? {
    pdfView.page(for: viewPoint(from: point), nearest: true)
  }

  private func page(for message: RelayMessage) -> PDFPage? {
    if let index = message.pageIndex { return document?.page(at: index) }
    guard let point = message.point else { return nil }
    return page(for: point)
  }

  private func viewPoint(from point: RelayPoint) -> NSPoint {
    let bounds = pdfView.bounds
    return NSPoint(x: bounds.minX + point.x * bounds.width, y: bounds.maxY - point.y * bounds.height)
  }

  private func pagePoint(from point: RelayPoint, on page: PDFPage, usesPageCoordinates: Bool) -> NSPoint {
    if usesPageCoordinates {
      return pagePointFromNormalized(point, on: page)
    }
    return pdfView.convert(viewPoint(from: point), to: page)
  }

  func apply(_ viewport: PDFViewport) {
    guard !isApplyingLocalZoom,
          localViewportInteractionId == nil,
          ProcessInfo.processInfo.systemUptime >= ignoreRemoteViewportUntil,
          document?.page(at: viewport.pageIndex) != nil else { return }
    suppressPassiveViewportUntil = ProcessInfo.processInfo.systemUptime + 0.5
    remoteViewportGeneration += 1
    pendingRemoteViewport = viewport
    isApplyingRemoteViewport = true
    cancelScheduledViewportUpdate()
    scheduleRemoteViewportApplication()
  }

  private func scheduleRemoteViewportApplication() {
    guard remoteViewportWorkItem == nil, pendingRemoteViewport != nil else { return }
    let elapsed = ProcessInfo.processInfo.systemUptime - lastRemoteViewportApplyTime
    let delay = max(0, viewportSyncInterval - elapsed)
    remoteViewportScheduleGeneration += 1
    let generation = remoteViewportScheduleGeneration
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.remoteViewportScheduleGeneration == generation else { return }
      self.remoteViewportWorkItem = nil
      guard let viewport = self.pendingRemoteViewport else { return }
      self.pendingRemoteViewport = nil
      self.lastRemoteViewportApplyTime = ProcessInfo.processInfo.systemUptime
      self.applyRemoteViewportNow(viewport)
      if self.pendingRemoteViewport != nil {
        self.scheduleRemoteViewportApplication()
      }
    }
    remoteViewportWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func applyRemoteViewportNow(_ viewport: PDFViewport) {
    guard !isApplyingLocalZoom,
          let document,
          let page = document.page(at: viewport.pageIndex) else { return }
    let generation = remoteViewportGeneration
    pdfView.autoScales = false
    let fitted = max(0.1, pdfView.scaleFactorForSizeToFit)
    let requestedZoom = min(sharedMaximumZoom, max(sharedMinimumZoom, viewport.zoom))
    let targetScale = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, fitted * requestedZoom))
    let scaleChanged = abs(pdfView.scaleFactor - targetScale) > 0.0005
    let isLiveInteraction = viewport.interactionId != nil && viewport.interactionPhase != "end"
    if scaleChanged {
      pdfView.scaleFactor = targetScale
    }
    let atDocumentTop = viewport.pageIndex == 0 && viewport.offset <= 0.0001
    let atDocumentBottom = viewport.pageIndex == document.pageCount - 1 && viewport.offset >= 0.9999
    let normalized = RelayPoint(
      x: min(1, max(0, viewport.anchorX ?? 0.5)),
      y: min(1, max(0, viewport.anchorY ?? viewport.offset)),
      p: 0.5
    )
    let anchor = PDFViewAnchor(
      page: page,
      point: pagePointFromNormalized(normalized, on: page),
      viewportPosition: NSPoint(x: 0.5, y: 0.5)
    )
    restoreRemoteViewportAnchor(
      anchor,
      documentTop: atDocumentTop,
      documentBottom: atDocumentBottom,
      generation: generation,
      // During a live remote pinch, scaleFactor provides the visual preview.
      // Avoid forcing PDFKit's complete continuous-page layout 120 times per
      // second; the authoritative end frame performs the stable layout.
      performLayout: scaleChanged && !isLiveInteraction,
      refreshInk: true
    )
    // Only a scale change needs PDFKit's asynchronous layout stabilizers.
    // Pure scrolling now follows a single lightweight path every frame.
    if scaleChanged && !isLiveInteraction {
      DispatchQueue.main.async { [weak self] in
        self?.restoreRemoteViewportAnchor(
          anchor,
          documentTop: atDocumentTop,
          documentBottom: atDocumentBottom,
          generation: generation,
          performLayout: true,
          refreshInk: false
        )
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
        self?.restoreRemoteViewportAnchor(
          anchor,
          documentTop: atDocumentTop,
          documentBottom: atDocumentBottom,
          generation: generation,
          performLayout: true,
          refreshInk: false
        )
      }
    }
    remoteViewportSettleWorkItem?.cancel()
    let settleItem = DispatchWorkItem { [weak self] in
      guard let self,
            self.remoteViewportGeneration == generation,
            self.pendingRemoteViewport == nil else { return }
      self.restoreRemoteViewportAnchor(
        anchor,
        documentTop: atDocumentTop,
        documentBottom: atDocumentBottom,
        generation: generation,
        performLayout: scaleChanged && !isLiveInteraction,
        refreshInk: false
      )
      self.isApplyingRemoteViewport = false
      self.refreshOverlay()
    }
    remoteViewportSettleWorkItem = settleItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + (isLiveInteraction ? 0.22 : 0.08),
      execute: settleItem
    )
  }

  private func restoreRemoteViewportAnchor(
    _ anchor: PDFViewAnchor,
    documentTop: Bool,
    documentBottom: Bool,
    generation: Int,
    performLayout: Bool,
    refreshInk: Bool
  ) {
    guard remoteViewportGeneration == generation else { return }
    restoreViewAnchor(anchor, performLayout: performLayout)
    if documentTop || documentBottom {
      scrollToDocumentEdge(top: documentTop)
    }
    if refreshInk { refreshOverlay() }
  }

  private func cancelScheduledViewportUpdate() {
    localViewportScheduleGeneration += 1
    viewportWorkItem?.cancel()
    viewportWorkItem = nil
  }

  private func beginLocalViewportInteraction() {
    viewportFinalWorkItem?.cancel()
    viewportFinalWorkItem = nil
    guard localViewportInteractionId == nil else { return }
    localViewportInteractionId = UUID().uuidString.lowercased()
    publishViewport(interactionPhase: "begin")
    lastViewportPublishTime = ProcessInfo.processInfo.systemUptime
  }

  private func scheduleLocalViewportInteractionEnd(delay: TimeInterval = viewportInteractionIdleDelay) {
    viewportFinalWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.finishLocalViewportInteraction() }
    viewportFinalWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func finishLocalViewportInteraction() {
    guard localViewportInteractionId != nil else {
      scheduleViewportUpdate()
      return
    }
    viewportFinalWorkItem?.cancel()
    viewportFinalWorkItem = nil
    cancelScheduledViewportUpdate()
    publishViewport(interactionPhase: "end")
    localViewportInteractionId = nil
    ignoreRemoteViewportUntil = 0
  }

  private func cancelLocalViewportInteraction() {
    viewportFinalWorkItem?.cancel()
    viewportFinalWorkItem = nil
    localViewportInteractionId = nil
    ignoreRemoteViewportUntil = 0
  }

  private func cancelRemoteViewportApplication() {
    remoteViewportGeneration += 1
    remoteViewportScheduleGeneration += 1
    remoteViewportWorkItem?.cancel()
    remoteViewportWorkItem = nil
    remoteViewportSettleWorkItem?.cancel()
    remoteViewportSettleWorkItem = nil
    pendingRemoteViewport = nil
    isApplyingRemoteViewport = false
  }

  private func scheduleViewportUpdate(delay: TimeInterval = 0) {
    guard document != nil, !isApplyingRemoteViewport else { return }
    guard viewportWorkItem == nil else { return }
    let elapsed = ProcessInfo.processInfo.systemUptime - lastViewportPublishTime
    let wait = max(delay, max(0, viewportSyncInterval - elapsed))
    localViewportScheduleGeneration += 1
    let generation = localViewportScheduleGeneration
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.localViewportScheduleGeneration == generation else { return }
      self.viewportWorkItem = nil
      self.lastViewportPublishTime = ProcessInfo.processInfo.systemUptime
      self.publishViewport(interactionPhase: self.localViewportInteractionId == nil ? nil : "update")
    }
    viewportWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
  }

  private func publishViewport(interactionPhase: String? = nil) {
    guard !isApplyingRemoteViewport, let document else { return }
    let topOfViewport = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.maxY - 1)
    let centerOfViewport = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
    guard let page = pdfView.page(for: centerOfViewport, nearest: true) else { return }
    let index = document.index(for: page)
    guard index != NSNotFound else { return }
    let pagePoint = pdfView.convert(topOfViewport, to: page)
    let centerPoint = pdfView.convert(centerOfViewport, to: page)
    let edge = documentScrollEdge()
    let measuredOffset = normalizedPointFromPage(pagePoint, on: page).y
    // 0 and 1 are document-edge sentinels in the shared protocol. While
    // crossing a page boundary, the top of the viewport can still be above
    // the page selected at its center, which naturally clamps the page-local
    // offset to 0. Never let that interior geometry masquerade as the top of
    // the whole document.
    let atDocumentTop = index == 0 && edge.top
    let atDocumentBottom = index == document.pageCount - 1 && edge.bottom
    let interiorOffset = min(
      1 - viewportInteriorOffsetMargin,
      max(viewportInteriorOffsetMargin, measuredOffset)
    )
    let offset = atDocumentTop ? 0 : (atDocumentBottom ? 1 : interiorOffset)
    let normalizedCenter = normalizedPointFromPage(centerPoint, on: page)
    let fitted = max(0.1, pdfView.scaleFactorForSizeToFit)
    onViewport?(PDFViewport(
      pageIndex: index,
      zoom: min(sharedMaximumZoom, max(sharedMinimumZoom, pdfView.scaleFactor / fitted)),
      offset: offset,
      anchorX: normalizedCenter.x,
      anchorY: normalizedCenter.y,
      viewportWidth: pdfView.bounds.width,
      viewportHeight: pdfView.bounds.height,
      interactionId: localViewportInteractionId,
      interactionPhase: localViewportInteractionId == nil ? nil : interactionPhase
    ))
  }

  private func documentScrollEdge() -> (top: Bool, bottom: Bool) {
    guard let scrollView = firstScrollView(in: pdfView), let documentView = scrollView.documentView else {
      return (false, false)
    }
    let visible = scrollView.contentView.bounds
    let content = documentView.bounds
    let tolerance: CGFloat = 2
    if documentView.isFlipped {
      return (
        visible.minY <= content.minY + tolerance,
        visible.maxY >= content.maxY - tolerance
      )
    }
    return (
      visible.maxY >= content.maxY - tolerance,
      visible.minY <= content.minY + tolerance
    )
  }

  private func scrollToDocumentEdge(top: Bool) {
    guard let scrollView = firstScrollView(in: pdfView), let documentView = scrollView.documentView else { return }
    let clipView = scrollView.contentView
    let content = documentView.bounds
    var origin = clipView.bounds.origin
    if documentView.isFlipped {
      origin.y = top ? content.minY : max(content.minY, content.maxY - clipView.bounds.height)
    } else {
      origin.y = top ? max(content.minY, content.maxY - clipView.bounds.height) : content.minY
    }
    clipView.scroll(to: origin)
    scrollView.reflectScrolledClipView(clipView)
  }

  private func pageLineWidth(from padPixels: Double, ratio: Double?, on page: PDFPage) -> CGFloat {
    if let ratio, ratio.isFinite, ratio > 0 {
      return max(0.8, pageVisualWidth(page) * min(0.05, CGFloat(ratio)))
    }
    // Compatibility for strokes recorded before the tablet transmitted the
    // rendered-page width ratio.
    return max(0.8, pageVisualWidth(page) * padPixels / 1_000)
  }

  private func pressure(from point: RelayPoint) -> CGFloat {
    CGFloat(min(1, max(0.08, point.p)))
  }

  private func pressureWidth(base: CGFloat, pressure: CGFloat) -> CGFloat {
    // Same response curve as the tablet: light contact remains controllable,
    // while a firm press has a clearly broader, natural-looking mark.
    max(0.6, base * (0.4 + min(1, max(0.08, pressure)) * 0.9))
  }

  private func strokeWidth(base: CGFloat, pressure: CGFloat, tool: String) -> CGFloat {
    tool == "highlighter" ? max(0.8, base) : pressureWidth(base: base, pressure: pressure)
  }

  private func schedulePreviewUpdate(delay: TimeInterval = 0.16) {
    previewWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.publishViewportPreview() }
    previewWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func publishViewportPreview() {
    guard let representation = renderViewportPreview() else { return }
    guard let jpeg = compactJPEG(from: representation) else { return }
    onPreview?("data:image/jpeg;base64,\(jpeg.base64EncodedString())")
  }

  private func renderViewportPreview() -> NSBitmapImageRep? {
    let viewport = pdfView.bounds
    guard viewport.width > 2, viewport.height > 2,
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewport.width.rounded()),
            pixelsHigh: Int(viewport.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
          ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    bitmap.size = viewport.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor(DT.canvas).setFill()
    NSRect(origin: .zero, size: viewport.size).fill()
    let context = graphics.cgContext
    for page in pdfView.visiblePages {
      let pageBounds = pageDisplayBounds(page)
      let pageRect = pdfView.convert(pageBounds, from: page)
      context.saveGState()
      context.translateBy(x: pageRect.minX, y: pageRect.minY)
      context.scaleBy(x: pageRect.width / pageBounds.width, y: pageRect.height / pageBounds.height)
      context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    drawPreviewInk(in: context, inks: savedInks)
    for ink in activeInks.values {
      let baseWidth = previewWidth(pageWidth: ink.pageWidth, on: ink.page)
      drawPreviewStroke(color: ink.color, widths: ink.pressures.map { strokeWidth(base: baseWidth, pressure: $0, tool: ink.tool) }, points: ink.pagePoints.map { pdfView.convert($0, from: ink.page) }, isHighlighter: ink.tool == "highlighter", in: context)
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  private func drawPreviewInk(in context: CGContext, inks: [SavedInk]) {
    for ink in inks {
      let baseWidth = previewWidth(for: ink)
      drawPreviewStroke(color: ink.color, widths: ink.pressures.map { strokeWidth(base: baseWidth, pressure: $0, tool: ink.tool) }, points: ink.points.map { pdfView.convert($0, from: ink.page) }, isHighlighter: ink.tool == "highlighter", in: context)
    }
  }

  private func drawPreviewStroke(color: NSColor, widths: [CGFloat], points: [NSPoint], isHighlighter: Bool, in context: CGContext) {
    drawVariableStroke(OverlayStroke(color: color, widths: widths, points: points, isHighlighter: isHighlighter), in: context)
  }

  /// Keep each preview below the relay's payload limit.  Without this, a
  /// high-resolution PDF page can be silently rejected before it reaches the pad.
  private func compactJPEG(from representation: NSBitmapImageRep) -> Data? {
    let originalSize = NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    guard originalSize.width > 0, originalSize.height > 0 else { return nil }
    let original = NSImage(size: originalSize)
    original.addRepresentation(representation)
    var longestSide = min(max(originalSize.width, originalSize.height), 1_440)
    var quality: CGFloat = 0.65
    for _ in 0..<6 {
      let scale = longestSide / max(originalSize.width, originalSize.height)
      let size = NSSize(width: max(1, (originalSize.width * scale).rounded()), height: max(1, (originalSize.height * scale).rounded()))
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphics
      NSColor(DT.canvas).setFill()
      NSRect(origin: .zero, size: size).fill()
      original.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: originalSize), operation: .copy, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()
      if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= 305_000 {
        return jpeg
      }
      longestSide *= 0.72
      quality = max(0.32, quality - 0.06)
    }
    return nil
  }

  private func color(from hex: String?) -> NSColor {
    let value = (hex ?? "#152441").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = Int(value, radix: 16) else { return .controlTextColor }
    return NSColor(red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255, blue: CGFloat(number & 0xFF) / 255, alpha: 1)
  }
}

private extension NSPoint {
  func distance(to other: NSPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
