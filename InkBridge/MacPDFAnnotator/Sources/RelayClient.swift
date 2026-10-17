import CryptoKit
import Foundation

@MainActor
final class RelayClient: ObservableObject {
  @Published private(set) var status = "未连接"
  @Published private(set) var isConnected = false { didSet { if !isConnected { peerCount = 0 } } }
  @Published private(set) var peerCount = 0
  @Published private(set) var documentStatus = ""
  @Published private(set) var documentProgress: Double?
  @Published private(set) var isDocumentTransferActive = false
  @Published private(set) var canCancelPDFTransfer = false
  @Published private(set) var canRetryPDFTransfer = false
  @Published private(set) var tabletTransport: ConnectionTransport?
  @Published private(set) var tabletDeviceId = ""

  var onDrawing: ((RelayMessage) -> Void)?
  var onViewport: ((PDFViewport) -> Void)?
  var onWhiteboardViewport: ((WhiteboardViewport) -> Void)?
  var onMode: ((String) -> Void)?
  var onHistory: ((RelayMessage) -> Void)?
  var onWhiteboardHistory: ((RelayMessage) -> Void)?
  var onHistorySnapshot: (([RelayMessage], Int?, Int?, String?) -> Void)?
  var onWhiteboardHistorySnapshot: (([RelayMessage], Int?, Int?) -> Void)?
  var onDocumentCommitted: ((PDFDocumentDescriptor) -> Void)?
  var onDocumentCancelled: ((String) -> Void)?
  var onSessionConnected: (() -> Void)?
  var onTransportStatus: ((ConnectionTransport, String?, String?) -> Void)?
  var onScreenMirrorRequest: ((String, String?) -> Void)?
  var onScreenMirrorStatus: ((String, String?, String?) -> Void)?
  var onRoundTripReturn: ((RelayMessage) -> Void)?

  private struct PendingPDFUpload {
    let data: Data
    let name: String
    let id: String
    let version: Int
    let hash: String
    let transactionId: String
  }

  private var task: URLSessionWebSocketTask?
  private var room = ""
  private var reconnectWorkItem: DispatchWorkItem?
  private var pendingDocument: PendingPDFUpload?
  private var committedDocumentUpload: PendingPDFUpload?
  private var activeDocument: PDFDocumentDescriptor?
  private var uploadTask: URLSessionUploadTask?
  private var uploadAttempt = 0
  private var uploadRequestId = 0
  private var documentPreparationId = 0
  private var preparingTransactionId: String?
  private var lastCommittedTransactionId: String?
  private var sequence = 0
  private var lastRevision = 0
  private var pendingAcks: [String: Date] = [:]
  private let clientId: String

  init() {
    if let saved = UserDefaults.standard.string(forKey: Self.clientIdDefaultsKey), !saved.isEmpty {
      clientId = saved
    } else {
      let generated = "mac-\(UUID().uuidString.lowercased())"
      UserDefaults.standard.set(generated, forKey: Self.clientIdDefaultsKey)
      clientId = generated
    }
  }

  func connect(room: String) {
    reconnectWorkItem?.cancel()
    disconnect()
    self.room = room
    lastRevision = 0
    guard let url = URL(string: "ws://127.0.0.1:3210/ws") else { return }
    status = "正在连接本机服务"
    let task = URLSession.shared.webSocketTask(with: url)
    // A persisted project can legitimately contain several megabytes of
    // pressure samples and history operations. URLSession defaults to a 1 MiB
    // WebSocket frame limit. Long highlighter sessions can legitimately exceed
    // 16 MiB, so keep a bounded 32 MiB ceiling that restores the current project
    // without allowing an unbounded snapshot allocation.
    task.maximumMessageSize = 32 * 1_024 * 1_024
    self.task = task
    task.resume()
    send(.join(room: room, clientId: clientId))
    receiveNext()
  }

  func disconnect() {
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    pendingAcks = [:]
    isConnected = false
  }

  func sendPreview(_ preview: String) {
    send(RelayMessage(type: "pdf:preview", preview: preview))
  }

  func sendViewport(_ viewport: PDFViewport) {
    var message = RelayMessage(
      type: "pdf:viewport",
      pageIndex: viewport.pageIndex,
      zoom: viewport.zoom,
      offset: viewport.offset,
      anchorX: viewport.anchorX,
      anchorY: viewport.anchorY,
      viewportWidth: viewport.viewportWidth,
      viewportHeight: viewport.viewportHeight,
      interactionId: viewport.interactionId,
      interactionPhase: viewport.interactionPhase
    )
    applyActiveDocument(to: &message)
    send(message)
  }

  func sendWhiteboardViewport(_ viewport: WhiteboardViewport) {
    send(RelayMessage(
      type: "whiteboard:viewport",
      zoom: viewport.zoom,
      centerX: viewport.centerX,
      centerY: viewport.centerY,
      viewportWidth: viewport.viewportWidth,
      viewportHeight: viewport.viewportHeight,
      interactionId: viewport.interactionId,
      interactionPhase: viewport.interactionPhase
    ))
  }

  func sendMode(_ mode: String) {
    send(RelayMessage(type: "app:mode", mode: mode))
  }

  func sendTransportRequest(
    mode: ConnectionTransport,
    preference: ConnectionPreference,
    requestId: String
  ) {
    send(RelayMessage(
      type: "transport:request",
      transport: mode.rawValue,
      transportPreference: preference.rawValue,
      requestId: requestId
    ))
  }

  func sendScreenMirrorRequest(action: String, requestId: String) {
    guard action == "start" || action == "stop" else { return }
    send(RelayMessage(
      type: "screen-mirror:request",
      action: action,
      requestId: requestId
    ))
  }

  func sendRoundTripOpen(roundTripId: String, document: PDFDocumentDescriptor) {
    send(RelayMessage(
      type: "roundtrip:open",
      roundTripId: roundTripId,
      name: document.name,
      documentId: document.documentId,
      documentVersion: document.documentVersion,
      documentHash: document.documentHash,
      documentSize: document.documentSize
    ))
  }

  func downloadRoundTripReturn(returnId: String, completion: @escaping @MainActor (Data?) -> Void) {
    guard !room.isEmpty,
          let url = URL(string: "http://127.0.0.1:3210/api/roundtrip/return/\(room)/\(returnId)") else {
      completion(nil)
      return
    }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 120
    URLSession.shared.dataTask(with: request) { data, response, _ in
      let valid = (response as? HTTPURLResponse)?.statusCode == 200
        && data?.starts(with: Data("%PDF-".utf8)) == true
      Task { @MainActor in completion(valid ? data : nil) }
    }.resume()
  }

  func sendClear(mode: String) {
    var message = RelayMessage(type: "clear", mode: mode)
    if mode == "pdf" { applyActiveDocument(to: &message) }
    send(message)
  }

  func sendHistory(_ type: String, mode: String) {
    guard type == "history:undo" || type == "history:redo" else { return }
    var message = RelayMessage(type: type, mode: mode)
    if mode == "pdf" { applyActiveDocument(to: &message) }
    send(message)
  }

  func downloadPDF(
    _ descriptor: PDFDocumentDescriptor,
    completion: @escaping @MainActor (Data?) -> Void
  ) {
    guard !room.isEmpty else {
      completion(nil)
      return
    }
    var components = URLComponents(string: "http://127.0.0.1:3210/api/pdf/\(room)")
    components?.queryItems = [
      URLQueryItem(name: "id", value: descriptor.documentId),
      URLQueryItem(name: "version", value: String(descriptor.documentVersion)),
      URLQueryItem(name: "hash", value: descriptor.documentHash),
    ]
    guard let url = components?.url else {
      completion(nil)
      return
    }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 120
    URLSession.shared.dataTask(with: request) { data, response, _ in
      let hash = data.map {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
      }
      let valid = (response as? HTTPURLResponse)?.statusCode == 200
        && data?.starts(with: Data("%PDF-".utf8)) == true
        && hash == descriptor.documentHash
      Task { @MainActor in completion(valid ? data : nil) }
    }.resume()
  }

  @discardableResult
  func uploadPDF(_ data: Data, named name: String) -> String {
    uploadTask?.cancel()
    uploadTask = nil
    uploadRequestId += 1
    documentPreparationId += 1
    let preparationId = documentPreparationId
    let version = Self.nextDocumentVersion()
    let transactionId = UUID().uuidString.lowercased()
    preparingTransactionId = transactionId
    pendingDocument = nil
    uploadAttempt = 0
    documentProgress = 0
    isDocumentTransferActive = true
    canCancelPDFTransfer = true
    canRetryPDFTransfer = false
    documentStatus = "正在校验 PDF…"
    Task.detached(priority: .userInitiated) { [weak self] in
      let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      await MainActor.run {
        guard let self,
              self.documentPreparationId == preparationId,
              self.preparingTransactionId == transactionId else { return }
        self.pendingDocument = PendingPDFUpload(
          data: data,
          name: name,
          id: "sha256-\(hash)",
          version: version,
          hash: hash,
          transactionId: transactionId
        )
        self.uploadPendingPDF()
      }
    }
    return transactionId
  }

  func cancelPDFUpload() {
    guard canCancelPDFTransfer else { return }
    let transactionId = preparingTransactionId ?? pendingDocument?.transactionId
    documentPreparationId += 1
    uploadRequestId += 1
    uploadTask?.cancel()
    uploadTask = nil
    pendingDocument = nil
    preparingTransactionId = nil
    uploadAttempt = 0
    documentProgress = nil
    isDocumentTransferActive = false
    canCancelPDFTransfer = false
    canRetryPDFTransfer = false
    documentStatus = "已取消 PDF 传送"
    if let transactionId { onDocumentCancelled?(transactionId) }
  }

  func retryPDFUpload() {
    if pendingDocument != nil {
      uploadTask?.cancel()
      uploadTask = nil
      uploadAttempt = 0
      documentProgress = 0
      isDocumentTransferActive = true
      canCancelPDFTransfer = true
      canRetryPDFTransfer = false
      uploadPendingPDF()
      return
    }
    if activeDocument != nil {
      var message = RelayMessage(type: "pdf:reload")
      applyActiveDocument(to: &message)
      send(message)
      documentProgress = 0
      isDocumentTransferActive = true
      canRetryPDFTransfer = false
      documentStatus = "已要求平板重新加载 PDF…"
      return
    }
  }

  private func uploadPendingPDF() {
    guard let pendingDocument,
          !room.isEmpty,
          let url = URL(string: "http://127.0.0.1:3210/api/pdf/\(room)") else {
      documentStatus = "PDF 等待本机服务启动"
      return
    }
    uploadAttempt += 1
    let attempt = uploadAttempt
    uploadRequestId += 1
    let requestId = uploadRequestId
    documentStatus = "正在提交 PDF…"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/pdf", forHTTPHeaderField: "content-type")
    let encodedName = pendingDocument.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? pendingDocument.name
    request.setValue(encodedName, forHTTPHeaderField: "x-pdf-name")
    request.setValue(pendingDocument.id, forHTTPHeaderField: "x-pdf-id")
    request.setValue(String(pendingDocument.version), forHTTPHeaderField: "x-pdf-version")
    request.setValue(pendingDocument.hash, forHTTPHeaderField: "x-pdf-sha256")
    request.setValue(pendingDocument.transactionId, forHTTPHeaderField: "x-pdf-transaction-id")
    request.setValue(inkBridgeAppVersion, forHTTPHeaderField: "x-inkbridge-version")
    request.setValue(String(inkBridgeProtocolVersion), forHTTPHeaderField: "x-inkbridge-protocol")
    let task = URLSession.shared.uploadTask(with: request, from: pendingDocument.data) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self,
              requestId == self.uploadRequestId,
              attempt == self.uploadAttempt else { return }
        self.uploadTask = nil
        if let error {
          if (error as NSError).code == NSURLErrorCancelled { return }
          if attempt < 3 {
            self.documentStatus = "PDF 传送未完成，正在重试…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
              guard let self,
                    self.pendingDocument?.transactionId == pendingDocument.transactionId,
                    self.uploadAttempt == attempt,
                    self.uploadTask == nil else { return }
              self.uploadPendingPDF()
            }
          } else {
            self.documentStatus = "PDF 传送失败：\(error.localizedDescription)"
            self.documentProgress = nil
            self.isDocumentTransferActive = false
            self.canCancelPDFTransfer = false
            self.canRetryPDFTransfer = true
          }
          return
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 200 || statusCode == 201 || statusCode == 204 {
          if let data, let descriptor = try? JSONDecoder().decode(PDFDocumentDescriptor.self, from: data) {
            self.acceptCommittedDocument(descriptor)
          }
          if self.documentStatus == "正在提交 PDF…" {
            self.documentStatus = "PDF 已提交，等待平板加载…"
          }
        } else if statusCode == 409 {
          self.documentStatus = "PDF 已被更新版本替代"
          self.isDocumentTransferActive = false
          self.canCancelPDFTransfer = false
        } else if statusCode == 413 {
          self.documentStatus = "PDF 超过 250 MB，无法传送"
          self.isDocumentTransferActive = false
          self.canCancelPDFTransfer = false
          self.canRetryPDFTransfer = false
        } else if statusCode == 422 {
          self.documentStatus = "PDF 校验失败，文件可能已损坏"
          self.isDocumentTransferActive = false
          self.canCancelPDFTransfer = false
          self.canRetryPDFTransfer = true
        } else if statusCode == 507 {
          self.documentStatus = "Mac 可用内存不足，无法接收该 PDF"
          self.isDocumentTransferActive = false
          self.canCancelPDFTransfer = false
          self.canRetryPDFTransfer = true
        } else {
          self.documentStatus = "PDF 传送失败（HTTP \(statusCode)）"
          self.isDocumentTransferActive = false
          self.canCancelPDFTransfer = false
          self.canRetryPDFTransfer = true
        }
      }
    }
    uploadTask = task
    task.resume()
    scheduleUploadProgress(requestId: requestId, expectedBytes: pendingDocument.data.count)
  }

  private func scheduleUploadProgress(requestId: Int, expectedBytes: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self,
            requestId == self.uploadRequestId,
            let uploadTask = self.uploadTask else { return }
      let expected = max(1, expectedBytes)
      let fraction = min(1, max(0, Double(uploadTask.countOfBytesSent) / Double(expected)))
      self.documentProgress = fraction
      self.documentStatus = "正在提交 PDF \(Int((fraction * 100).rounded()))%"
      self.scheduleUploadProgress(requestId: requestId, expectedBytes: expectedBytes)
    }
  }

  private func acceptCommittedDocument(_ descriptor: PDFDocumentDescriptor) {
    activeDocument = descriptor
    documentProgress = 0
    isDocumentTransferActive = true
    canCancelPDFTransfer = false
    canRetryPDFTransfer = false
    documentStatus = "PDF 已提交，等待平板加载…"
    guard descriptor.transactionId != lastCommittedTransactionId else { return }
    lastCommittedTransactionId = descriptor.transactionId
    if let transactionId = descriptor.transactionId,
       let pendingDocument,
       pendingDocument.transactionId == transactionId {
      committedDocumentUpload = pendingDocument
      self.pendingDocument = nil
      preparingTransactionId = nil
    }
    onDocumentCommitted?(descriptor)
  }

  private func receiveNext() {
    guard let currentTask = task else { return }
    currentTask.receive { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.task === currentTask else { return }
        switch result {
        case .success(let response):
          self.handle(response)
          self.receiveNext()
        case .failure:
          self.isConnected = false
          self.status = "正在启动本机服务"
          self.retryConnection()
        }
      }
    }
  }

  private func handle(_ response: URLSessionWebSocketTask.Message) {
    let data: Data
    switch response {
    case .data(let value): data = value
    case .string(let value): data = Data(value.utf8)
    @unknown default: return
    }
    guard let message = try? JSONDecoder().decode(RelayMessage.self, from: data) else { return }
    if message.sourceId == clientId { return }
    if let revision = message.revision {
      guard revision >= lastRevision else { return }
      lastRevision = revision
    }

    if message.type == "presence", let count = message.count { peerCount = count }
    if message.type == "ack" {
      if let id = message.ackMessageId { pendingAcks.removeValue(forKey: id) }
      return
    }

    if message.type == "session:welcome" || message.type == "presence" || message.type == "sync" {
      isConnected = true
      status = "已连接 · 协议 v\(message.protocolVersion ?? 1)"
      if message.type == "session:welcome" { onSessionConnected?() }
    }

    if message.type == "session:snapshot" {
      if let mode = message.mode { onMode?(mode) }
      if let descriptor = message.document {
        acceptCommittedDocument(descriptor)
      } else if pendingDocument != nil {
        activeDocument = nil
        uploadTask?.cancel()
        uploadTask = nil
        uploadAttempt = 0
        documentStatus = "本机服务已恢复，正在重新发送 PDF…"
        uploadPendingPDF()
      } else if preparingTransactionId != nil && isDocumentTransferActive {
        activeDocument = nil
        documentStatus = "本机服务已恢复，正在准备 PDF…"
      } else if committedDocumentUpload != nil {
        pendingDocument = committedDocumentUpload
        activeDocument = nil
        uploadTask?.cancel()
        uploadTask = nil
        uploadAttempt = 0
        documentStatus = "本机服务已恢复，正在重新发送 PDF…"
        uploadPendingPDF()
      }
      onHistorySnapshot?(
        message.history?.filter { isPDFHistory($0) && isCurrentDocument($0) } ?? [],
        message.historyCursor,
        message.historyRevision,
        message.document?.documentId ?? activeDocument?.documentId
      )
      onWhiteboardHistorySnapshot?(
        message.history?.filter { !$0.type.hasPrefix("pdf:") && $0.pageIndex == nil && $0.documentId == nil } ?? [],
        message.whiteboardHistoryCursor,
        message.whiteboardHistoryRevision ?? message.historyRevision
      )
      if var viewport = message.viewport, isCurrentDocument(viewport) {
        viewport.revision = message.revision
        viewport.sourceId = message.sourceId
        onViewport?(viewport)
      }
      if var viewport = message.whiteboardViewport {
        viewport.revision = message.revision
        viewport.sourceId = message.sourceId
        onWhiteboardViewport?(viewport)
      }
      return
    }

    if message.type == "sync" {
      onHistorySnapshot?(
        message.history?.filter { isPDFHistory($0) && isCurrentDocument($0) } ?? [],
        message.historyCursor,
        message.historyRevision,
        activeDocument?.documentId
      )
      return
    }

    if message.type == "pdf:document", let descriptor = message.documentDescriptor {
      acceptCommittedDocument(descriptor)
      if let history = message.history {
        onHistorySnapshot?(
          history.filter { isPDFHistory($0) && isCurrentDocument($0) },
          message.historyCursor,
          message.historyRevision,
          descriptor.documentId
        )
      }
      return
    }

    if message.type == "pdf:progress", isCurrentDocument(message) {
      let value = min(1, max(0, message.progress ?? 0))
      documentProgress = value
      isDocumentTransferActive = true
      canCancelPDFTransfer = false
      canRetryPDFTransfer = false
      let percent = Int((value * 100).rounded())
      switch message.phase {
      case "verify": documentStatus = "平板正在校验 PDF…"
      case "render": documentStatus = "平板正在打开 PDF…"
      default: documentStatus = "平板正在接收 PDF \(percent)%"
      }
      return
    }

    if message.type == "pdf:ready", isCurrentDocument(message) {
      let pages = message.pageCount.map { "（\($0) 页）" } ?? ""
      documentStatus = "平板已加载 PDF\(pages)"
      documentProgress = nil
      isDocumentTransferActive = false
      canCancelPDFTransfer = false
      canRetryPDFTransfer = false
      return
    }

    if message.type == "pdf:error", isCurrentDocument(message) {
      documentStatus = "平板加载失败：\(message.error ?? "未知错误")"
      documentProgress = nil
      isDocumentTransferActive = false
      canCancelPDFTransfer = false
      canRetryPDFTransfer = true
      return
    }

    if message.type == "app:mode", let mode = message.mode {
      onMode?(mode)
      return
    }

    if message.type == "transport:status",
       let value = message.transport,
       let transport = ConnectionTransport(rawValue: value) {
      tabletTransport = transport
      tabletDeviceId = message.deviceId ?? ""
      onTransportStatus?(transport, message.requestId, message.deviceId)
      return
    }

    if message.type == "screen-mirror:status", let status = message.status {
      onScreenMirrorStatus?(status, message.requestId, message.error)
      return
    }

    if message.type == "screen-mirror:request", let action = message.action {
      onScreenMirrorRequest?(action, message.requestId)
      return
    }

    if message.type == "roundtrip:return-ready", message.returnId != nil {
      onRoundTripReturn?(message)
      return
    }

    if message.type == "history:undo" || message.type == "history:redo" {
      if message.mode == "whiteboard" {
        onWhiteboardHistory?(message)
      } else if isCurrentDocument(message) {
        onHistory?(message)
      }
      return
    }

    if message.type == "pdf:viewport",
       let pageIndex = message.pageIndex,
       let zoom = message.zoom,
       let offset = message.offset,
       isCurrentDocument(message) {
      onViewport?(PDFViewport(
        pageIndex: pageIndex,
        zoom: zoom,
        offset: offset,
        anchorX: message.anchorX,
        anchorY: message.anchorY,
        viewportWidth: message.viewportWidth,
        viewportHeight: message.viewportHeight,
        interactionId: message.interactionId,
        interactionPhase: message.interactionPhase,
        documentId: message.documentId,
        documentVersion: message.documentVersion,
        documentHash: message.documentHash,
        revision: message.revision,
        sourceId: message.sourceId
      ))
      return
    }

    if message.type == "whiteboard:viewport",
       let centerX = message.centerX,
       let centerY = message.centerY,
       let zoom = message.zoom,
       let viewportWidth = message.viewportWidth,
       let viewportHeight = message.viewportHeight {
      onWhiteboardViewport?(WhiteboardViewport(
        centerX: centerX,
        centerY: centerY,
        zoom: zoom,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        interactionId: message.interactionId,
        interactionPhase: message.interactionPhase,
        revision: message.revision,
        sourceId: message.sourceId
      ))
      return
    }

    if message.type == "stroke:start"
      || message.type == "stroke:move"
      || message.type == "stroke:replace"
      || message.type == "stroke:end"
      || message.type == "cursor:move"
      || message.type == "cursor:hide"
      || message.type == "clear" {
      if isCurrentDocument(message) { onDrawing?(message) }
    }
  }

  private func send(_ input: RelayMessage) {
    var message = input
    sequence += 1
    message.protocolVersion = inkBridgeProtocolVersion
    message.appVersion = inkBridgeAppVersion
    message.sourceId = clientId
    message.sequence = sequence
    message.messageId = "\(clientId):\(sequence)"
    message.sentAt = Int64(Date().timeIntervalSince1970 * 1_000)
    message.requiresAck = Self.requiresAck(message.type)
    if message.requiresAck == true, let id = message.messageId { pendingAcks[id] = Date() }
    guard let data = try? JSONEncoder().encode(message) else { return }
    guard let currentTask = task else { return }
    currentTask.send(.data(data)) { [weak self] error in
      guard error != nil else { return }
      DispatchQueue.main.async {
        guard let self, self.task === currentTask else { return }
        self.isConnected = false
        self.status = "本机服务未启动"
      }
    }
  }

  private func applyActiveDocument(to message: inout RelayMessage) {
    guard let activeDocument else { return }
    message.documentId = activeDocument.documentId
    message.documentVersion = activeDocument.documentVersion
    message.documentHash = activeDocument.documentHash
  }

  private func isCurrentDocument(_ message: RelayMessage) -> Bool {
    guard let messageId = message.documentId, let messageVersion = message.documentVersion else { return true }
    guard let activeDocument else { return false }
    return messageId == activeDocument.documentId && messageVersion == activeDocument.documentVersion
  }

  private func isCurrentDocument(_ viewport: PDFViewport) -> Bool {
    guard let messageId = viewport.documentId, let messageVersion = viewport.documentVersion else { return true }
    guard let activeDocument else { return false }
    return messageId == activeDocument.documentId && messageVersion == activeDocument.documentVersion
  }

  private func isPDFHistory(_ message: RelayMessage) -> Bool {
    message.mode == "pdf" || message.pageIndex != nil || message.documentId != nil
  }

  private func retryConnection() {
    guard !room.isEmpty else { return }
    reconnectWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.connect(room: self.room)
    }
    reconnectWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
  }

  private static func requiresAck(_ type: String) -> Bool {
    [
      "app:mode", "clear", "history:undo", "history:redo", "pdf:reload",
      "pdf:viewport", "whiteboard:viewport", "stroke:end", "transport:request", "transport:status",
      "screen-mirror:request", "screen-mirror:status",
      "roundtrip:open",
    ].contains(type)
  }

  private static func nextDocumentVersion() -> Int {
    let next = UserDefaults.standard.integer(forKey: documentVersionDefaultsKey) + 1
    UserDefaults.standard.set(next, forKey: documentVersionDefaultsKey)
    return next
  }

  private static let clientIdDefaultsKey = "InkBridgeProtocolClientId"
  private static let documentVersionDefaultsKey = "InkBridgeDocumentVersion"
}
