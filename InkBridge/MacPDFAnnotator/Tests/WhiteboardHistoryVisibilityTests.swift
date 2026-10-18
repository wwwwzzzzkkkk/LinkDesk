import AppKit

@main
enum WhiteboardHistoryVisibilityTests {
  static func main() {
    pendingStrokeAfterCursorRemainsVisible()
    completedRedoStrokeAfterCursorRemainsHidden()
    clearAfterCursorRemainsHidden()
    pendingStrokeRendersBeforeEnd()
    completedRedoStrokeDoesNotRender()
    activeStrokeUpdatesWithoutInvalidatingCommittedInkCache()
    committingStrokeInvalidatesCommittedInkCache()
    activeEraserClearsCommittedInk()
    startingAfterUndoDropsRedoOperations()
    print("WhiteboardHistoryVisibilityTests passed")
  }

  private static func pendingStrokeAfterCursorRemainsVisible() {
    let completedStroke = strokeEvents(id: "committed", ended: true)
    let pendingStroke = strokeEvents(id: "pending", ended: false)

    let visible = visibleWhiteboardHistoryOperationIndexes(
      in: [completedStroke, pendingStroke],
      historyCursor: 1
    )

    precondition(visible == [0, 1])
  }

  private static func completedRedoStrokeAfterCursorRemainsHidden() {
    let completedStroke = strokeEvents(id: "committed", ended: true)
    let redoStroke = strokeEvents(id: "redo", ended: true)

    let visible = visibleWhiteboardHistoryOperationIndexes(
      in: [completedStroke, redoStroke],
      historyCursor: 1
    )

    precondition(visible == [0])
  }

  private static func clearAfterCursorRemainsHidden() {
    let completedStroke = strokeEvents(id: "committed", ended: true)

    let visible = visibleWhiteboardHistoryOperationIndexes(
      in: [completedStroke, [RelayMessage(type: "clear")]],
      historyCursor: 1
    )

    precondition(visible == [0])
  }

  private static func pendingStrokeRendersBeforeEnd() {
    let view = makeView()
    for message in strokeEvents(id: "pending-render", ended: false) {
      view.handle(message)
    }

    precondition(isBlueInk(renderedCenterColor(of: view)))
  }

  private static func completedRedoStrokeDoesNotRender() {
    let view = makeView()
    view.restore(strokeEvents(id: "redo-render", ended: true), cursor: 0, revision: 0)

    precondition(!isBlueInk(renderedCenterColor(of: view)))
  }

  private static func activeStrokeUpdatesWithoutInvalidatingCommittedInkCache() {
    let view = makeView()
    view.restore(strokeEvents(id: "committed-cache", ended: true), cursor: 1, revision: 7)
    _ = renderedCenterColor(of: view)
    let firstRenderCount = view.committedInkRenderCount

    for message in strokeEvents(id: "pending-cache", ended: false) {
      view.handle(message)
    }
    _ = renderedCenterColor(of: view)
    precondition(view.committedInkRenderCount == firstRenderCount)
  }

  private static func committingStrokeInvalidatesCommittedInkCache() {
    let view = makeView()
    let events = strokeEvents(id: "commit-cache", ended: false)
    events.forEach(view.handle)
    _ = renderedCenterColor(of: view)
    let firstRenderCount = view.committedInkRenderCount

    view.handle(RelayMessage(type: "stroke:end", strokeId: "commit-cache", strokeSequence: 2))
    _ = renderedCenterColor(of: view)
    precondition(view.committedInkRenderCount == firstRenderCount + 1)
  }

  private static func activeEraserClearsCommittedInk() {
    let view = makeView()
    view.restore(strokeEvents(id: "eraser-base", ended: true), cursor: 1, revision: 1)
    precondition(isBlueInk(renderedCenterColor(of: view)))

    view.handle(RelayMessage(
      type: "stroke:start",
      strokeId: "active-eraser",
      strokeSequence: 0,
      tool: "eraser",
      eraserSize: 90,
      coordinateSpace: "whiteboard-world-v1",
      point: RelayPoint(x: 0, y: 0, p: 1)
    ))
    precondition(!isBlueInk(renderedCenterColor(of: view)))
  }

  private static func startingAfterUndoDropsRedoOperations() {
    let view = makeView()
    let committed = strokeEvents(id: "undo-kept", ended: true)
    let redo = offsetStrokeEvents(id: "undo-dropped", x: 250, ended: true)
    view.restore(committed + redo, cursor: 1, revision: 2)

    for message in offsetStrokeEvents(id: "undo-new", x: -250, ended: false) {
      view.handle(message)
    }
    view.handle(RelayMessage(type: "stroke:end", strokeId: "undo-new", strokeSequence: 2))

    precondition(!isBlueInk(renderedColor(of: view, x: 300, y: 200)))
    precondition(isBlueInk(renderedColor(of: view, x: 100, y: 200)))
  }

  private static func makeView() -> WhiteboardCanvasView {
    WhiteboardCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
  }

  private static func renderedCenterColor(of view: WhiteboardCanvasView) -> NSColor {
    renderedColor(of: view, x: 200, y: 200)
  }

  private static func renderedColor(of view: WhiteboardCanvasView, x: Int, y: Int) -> NSColor {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 400,
      pixelsHigh: 400,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
      preconditionFailure("Unable to create whiteboard test bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()

    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
      preconditionFailure("Unable to sample whiteboard test bitmap")
    }
    return color
  }

  private static func isBlueInk(_ color: NSColor) -> Bool {
    color.blueComponent > 0.6 && color.blueComponent - color.redComponent > 0.25
  }

  private static func strokeEvents(id: String, ended: Bool) -> [RelayMessage] {
    offsetStrokeEvents(id: id, x: 0, ended: ended)
  }

  private static func offsetStrokeEvents(id: String, x: Double, ended: Bool) -> [RelayMessage] {
    var messages = [
      RelayMessage(
        type: "stroke:start",
        strokeId: id,
        strokeSequence: 0,
        color: "#2255DD",
        width: 18,
        tool: "ink",
        coordinateSpace: "whiteboard-world-v1",
        point: RelayPoint(x: x - 100, y: 0, p: 1)
      ),
      RelayMessage(
        type: "stroke:move",
        strokeId: id,
        strokeSequence: 1,
        tool: "ink",
        coordinateSpace: "whiteboard-world-v1",
        points: [RelayPoint(x: x + 100, y: 0, p: 1)]
      ),
    ]
    if ended {
      messages.append(RelayMessage(type: "stroke:end", strokeId: id, strokeSequence: 2))
    }
    return messages
  }
}
