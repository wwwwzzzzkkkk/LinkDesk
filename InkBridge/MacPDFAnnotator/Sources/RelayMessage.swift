import Foundation

let inkBridgeAppVersion = "1.6.10"
let inkBridgeProtocolVersion = 2

struct RelayPoint: Codable, Sendable {
  let x: Double
  let y: Double
  let p: Double
  var tiltX: Double?
  var tiltY: Double?
  var rollAngle: Double?
  var timestamp: Double?
  var sampleIndex: Int?
}

struct PDFDocumentDescriptor: Codable, Sendable, Equatable {
  let name: String
  let documentId: String
  let documentVersion: Int
  let documentHash: String
  let documentSize: Int?
  let transactionId: String?
  let restoreAvailable: Bool?
}

struct PDFViewport: Codable, Sendable {
  let pageIndex: Int
  let zoom: Double
  let offset: Double
  let anchorX: Double?
  let anchorY: Double?
  var viewportWidth: Double?
  var viewportHeight: Double?
  var interactionId: String?
  var interactionPhase: String?
  var documentId: String?
  var documentVersion: Int?
  var documentHash: String?
  var revision: Int?
  var sourceId: String?
}

struct WhiteboardViewport: Codable, Sendable {
  let centerX: Double
  let centerY: Double
  let zoom: Double
  let viewportWidth: Double
  let viewportHeight: Double
  var interactionId: String?
  var interactionPhase: String?
  var revision: Int?
  var sourceId: String?
}

struct RelayMessage: Codable, Sendable {
  var type: String
  var protocolVersion: Int?
  var appVersion: String?
  var sourceId: String?
  var sequence: Int?
  var messageId: String?
  var revision: Int?
  var sentAt: Int64?
  var requiresAck: Bool?
  var ackMessageId: String?
  var status: String?
  var capabilities: [String]?
  var clientId: String?

  var room: String?
  var role: String?
  var count: Int?
  var mode: String?
  var action: String?
  var transport: String?
  var transportPreference: String?
  var requestId: String?
  var roundTripId: String?
  var returnId: String?
  var deviceId: String?
  var strokeId: String?
  var strokeSequence: Int?
  var operationId: String?
  var historySequence: Int?
  var historyCursor: Int?
  var historyLength: Int?
  var historyRevision: Int?
  var whiteboardHistoryCursor: Int?
  var whiteboardHistoryLength: Int?
  var whiteboardHistoryRevision: Int?
  var requestSourceId: String?
  var color: String?
  var width: Double?
  var widthRatio: Double?
  var opacity: Double?
  var tool: String?
  var eraserSize: Double?
  var eraserRatio: Double?
  var canvasAspect: Double?
  var coordinateSpace: String?
  var point: RelayPoint?
  var points: [RelayPoint]?
  var history: [RelayMessage]?
  var preview: String?

  var name: String?
  var documentId: String?
  var documentVersion: Int?
  var documentHash: String?
  var documentSize: Int?
  var transactionId: String?
  var restoreAvailable: Bool?
  var pageCount: Int?
  var error: String?
  var phase: String?
  var loadedBytes: Int?
  var totalBytes: Int?
  var progress: Double?
  var document: PDFDocumentDescriptor?
  var viewport: PDFViewport?
  var whiteboardViewport: WhiteboardViewport?

  var pageIndex: Int?
  var zoom: Double?
  var offset: Double?
  var anchorX: Double?
  var anchorY: Double?
  var centerX: Double?
  var centerY: Double?
  var viewportWidth: Double?
  var viewportHeight: Double?
  var interactionId: String?
  var interactionPhase: String?

  static func join(room: String, clientId: String) -> RelayMessage {
    RelayMessage(
      type: "join",
      protocolVersion: inkBridgeProtocolVersion,
      appVersion: inkBridgeAppVersion,
      sourceId: clientId,
      capabilities: [
        "snapshot",
        "document-ready",
        "document-hash",
        "document-lifecycle",
        "document-progress",
        "document-reload",
        "viewport-v3",
        "viewport-control",
        "whiteboard-viewport-v1",
        "whiteboard-world-v1",
        "page-coordinate-v2",
        "native-pen-v2",
        "stroke-batch-v2",
        "highlighter-v1",
        "stroke-replace-v1",
        "stroke-idempotency",
        "history-v1",
        "durable-project-v1",
        "transport-control-v1",
        "screen-mirror-control-v1",
        "roundtrip-pdf-v1",
        "revision",
        "ack",
      ],
      room: room,
      role: "desktop"
    )
  }

  var documentDescriptor: PDFDocumentDescriptor? {
    if let document { return document }
    guard let name, let documentId, let documentVersion, let documentHash else { return nil }
    return PDFDocumentDescriptor(
      name: name,
      documentId: documentId,
      documentVersion: documentVersion,
      documentHash: documentHash,
      documentSize: documentSize,
      transactionId: transactionId,
      restoreAvailable: restoreAvailable
    )
  }
}
