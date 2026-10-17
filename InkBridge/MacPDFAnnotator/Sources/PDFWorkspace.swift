import AppKit
import Foundation
import PDFKit

enum AppMode: String, CaseIterable, Identifiable {
  case pdf
  case whiteboard

  var id: String { rawValue }
  var title: String { self == .pdf ? L10n.pdfTitle : L10n.whiteboardTitle }
}

struct RecentPDF: Codable, Identifiable, Equatable {
  let path: String
  let name: String
  let openedAt: Date
  var id: String { path }
}

@MainActor
final class PDFWorkspace: ObservableObject {
  @Published var documentName = L10n.waitPDFTitle
  @Published var room: String
  @Published var isShowingPairing = false
  @Published var isToolbarCollapsed = false
  @Published var isSearchPresented = false
  @Published private(set) var mode: AppMode = .pdf
  @Published private(set) var activePenColor = "#152441"
  @Published private(set) var activePenSummary = L10n.penReady
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var exportStatus = ""
  @Published private(set) var recentPDFs: [RecentPDF] = []
  @Published private(set) var searchQuery = ""
  @Published private(set) var searchCurrent = 0
  @Published private(set) var searchTotal = 0

  let relay = RelayClient()
  let usbRelay = USBRelayManager()
  let tabletMirror = TabletMirrorManager()
  weak var canvas: PDFCanvasView?
  weak var whiteboardCanvas: WhiteboardCanvasView?
  private var document: PDFDocument?
  private var sourceURL: URL?
  private var pendingLocalDocument: (document: PDFDocument, sourceURL: URL, transactionId: String)?
  private var pendingHistorySnapshot: (
    messages: [RelayMessage],
    cursor: Int?,
    revision: Int?,
    documentId: String?
  )?
  private var pendingViewport: PDFViewport?
  private var pendingWhiteboardViewport: WhiteboardViewport?
  private var pendingWhiteboardHistory: (messages: [RelayMessage], cursor: Int?, revision: Int?) = ([], nil, nil)
  private var pdfCanUndo = false
  private var pdfCanRedo = false
  private var whiteboardCanUndo = false
  private var whiteboardCanRedo = false
  private var restoringDocumentId: String?
  private var currentDocumentId: String?
  private var hasStarted = false
  private var exportStatusDismissWorkItem: DispatchWorkItem?
  private var pendingScreenMirrorRequest: (action: String, requestId: String)?
  private var pendingRoundTrip: (roundTripId: String, transactionId: String, sourceURL: URL)?
  private var roundTripSourceURLs: [String: URL] = [:]

  init() {
    let savedRoom = UserDefaults.standard.string(forKey: Self.roomDefaultsKey) ?? ""
    if savedRoom.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil {
      room = savedRoom
    } else {
      room = Self.makeRoomCode()
      UserDefaults.standard.set(room, forKey: Self.roomDefaultsKey)
    }
    recentPDFs = Self.loadRecentPDFs()
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    LocalRelayLauncher.shared.startIfNeeded()
    LocalRelayLauncher.shared.publishDiscoveryService(room: room)
    tabletMirror.arm()
    relay.onDrawing = { [weak self] message in self?.handleDrawing(message) }
    relay.onHistory = { [weak self] message in
      guard let self,
            message.documentId == nil || message.documentId == self.currentDocumentId else { return }
      self.canvas?.applyHistory(message)
    }
    relay.onWhiteboardHistory = { [weak self] message in
      self?.whiteboardCanvas?.applyHistory(message)
    }
    relay.onHistorySnapshot = { [weak self] messages, cursor, revision, documentId in
      guard let self else { return }
      self.pendingHistorySnapshot = (messages, cursor, revision, documentId)
      self.applyPendingHistoryIfReady()
    }
    relay.onWhiteboardHistorySnapshot = { [weak self] messages, cursor, revision in
      self?.pendingWhiteboardHistory = (messages, cursor, revision)
      self?.whiteboardCanvas?.restore(messages, cursor: cursor, revision: revision)
    }
    relay.onViewport = { [weak self] viewport in
      guard let self else { return }
      if viewport.documentId == nil || viewport.documentId == self.currentDocumentId {
        self.canvas?.apply(viewport)
      } else {
        self.pendingViewport = viewport
      }
    }
    relay.onWhiteboardViewport = { [weak self] viewport in
      self?.pendingWhiteboardViewport = viewport
      self?.whiteboardCanvas?.apply(viewport)
    }
    relay.onMode = { [weak self] value in self?.applyRemoteMode(value) }
    relay.onDocumentCommitted = { [weak self] descriptor in self?.commitPendingDocument(descriptor) }
    relay.onDocumentCancelled = { [weak self] transactionId in
      guard self?.pendingLocalDocument?.transactionId == transactionId else { return }
      self?.pendingLocalDocument = nil
    }
    relay.onSessionConnected = { [weak self] in
      guard let self else { return }
      self.usbRelay.sessionDidConnect()
      if let pending = self.pendingScreenMirrorRequest {
        self.relay.sendScreenMirrorRequest(action: pending.action, requestId: pending.requestId)
      }
    }
    relay.onTransportStatus = { [weak self] transport, requestId, deviceId in
      self?.usbRelay.reportTabletTransport(transport, requestId: requestId, deviceId: deviceId)
    }
    relay.onScreenMirrorStatus = { [weak self] status, requestId, error in
      guard let self else { return }
      if requestId == self.pendingScreenMirrorRequest?.requestId {
        self.pendingScreenMirrorRequest = nil
      }
      switch status {
      case "started": self.tabletMirror.remoteStartWasAccepted()
      case "stopped": self.tabletMirror.stop()
      case "failed": self.tabletMirror.remoteStartFailed(error ?? L10n.tabletCaptureFailure)
      default: break
      }
    }
    relay.onScreenMirrorRequest = { [weak self] action, _ in
      guard let self else { return }
      if action == "start" {
        self.tabletMirror.start()
      } else if action == "stop" {
        self.tabletMirror.stop()
      }
    }
    relay.onRoundTripReturn = { [weak self] message in self?.handleRoundTripReturn(message) }
    usbRelay.onTransportRequest = { [weak self] transport, preference, requestId in
      self?.relay.sendTransportRequest(
        mode: transport,
        preference: preference,
        requestId: requestId
      )
    }
    relay.connect(room: room)
    usbRelay.start()
  }

  func toggleTabletMirror() {
    let action = tabletMirror.isReceiving ? "stop" : "start"
    let requestId = UUID().uuidString.lowercased()
    pendingScreenMirrorRequest = (action, requestId)
    if action == "start" {
      tabletMirror.start()
    } else {
      tabletMirror.stop()
    }
    relay.sendScreenMirrorRequest(action: action, requestId: requestId)
  }

  func attach(canvas: PDFCanvasView) {
    self.canvas = canvas
    canvas.onPreview = { [weak self] preview in self?.relay.sendPreview(preview) }
    canvas.onViewport = { [weak self] viewport in self?.relay.sendViewport(viewport) }
    canvas.onHistoryAvailability = { [weak self] canUndo, canRedo in
      self?.pdfCanUndo = canUndo
      self?.pdfCanRedo = canRedo
      self?.publishHistoryAvailability()
    }
    canvas.onSearchState = { [weak self] current, total in
      self?.searchCurrent = current
      self?.searchTotal = total
    }
    canvas.document = document
    applyPendingHistoryIfReady()
  }

  func attach(whiteboardCanvas: WhiteboardCanvasView) {
    self.whiteboardCanvas = whiteboardCanvas
    whiteboardCanvas.onViewport = { [weak self] viewport in
      self?.relay.sendWhiteboardViewport(viewport)
    }
    whiteboardCanvas.onHistoryAvailability = { [weak self] canUndo, canRedo in
      self?.whiteboardCanUndo = canUndo
      self?.whiteboardCanRedo = canRedo
      self?.publishHistoryAvailability()
    }
    whiteboardCanvas.restore(
      pendingWhiteboardHistory.messages,
      cursor: pendingWhiteboardHistory.cursor,
      revision: pendingWhiteboardHistory.revision
    )
    if let pendingWhiteboardViewport { whiteboardCanvas.apply(pendingWhiteboardViewport) }
  }

  func selectMode(_ newMode: AppMode) {
    guard mode != newMode else { return }
    mode = newMode
    if newMode != .pdf { isSearchPresented = false }
    publishHistoryAvailability()
    relay.sendMode(newMode.rawValue)
  }

  private func applyRemoteMode(_ value: String) {
    guard let newMode = AppMode(rawValue: value) else { return }
    mode = newMode
    if newMode != .pdf { isSearchPresented = false }
    publishHistoryAvailability()
  }

  private func handleDrawing(_ message: RelayMessage) {
    if message.type == "stroke:start" {
      if let color = message.color { activePenColor = color }
      if message.tool == "eraser" {
        activePenSummary = L10n.format("eraserSummary", Int((message.eraserSize ?? 48).rounded()))
      } else {
        activePenSummary = L10n.format("penSummary", String(format: "%.1f", message.width ?? 3.5))
      }
    }
    let targetMode: AppMode
    if let explicit = message.mode.flatMap(AppMode.init(rawValue:)) {
      targetMode = explicit
    } else if message.pageIndex != nil {
      targetMode = .pdf
    } else if message.type.hasPrefix("pdf:") {
      targetMode = .pdf
    } else if message.type == "cursor:hide" || message.type == "clear" {
      targetMode = mode
    } else {
      targetMode = .whiteboard
    }
    if targetMode == .pdf {
      guard message.documentId == nil || message.documentId == currentDocumentId else { return }
      canvas?.handle(message)
    }
    else { whiteboardCanvas?.handle(message) }
  }

  func openPDF() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openPDF(at: url)
  }

  func openRecent(_ recent: RecentPDF) {
    openPDF(at: URL(fileURLWithPath: recent.path))
  }

  func startPDFRoundTrip() {
    let panel = NSOpenPanel()
    panel.title = L10n.sendPDFTitle
    panel.prompt = L10n.sendToTablet
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let roundTripId = UUID().uuidString.lowercased()
    openPDF(at: url, roundTripId: roundTripId)
  }

  func openPDF(at url: URL, roundTripId: String? = nil) {
    guard let document = PDFDocument(url: url),
          let data = try? Data(contentsOf: url) else {
      showExportStatus(L10n.format("openFileError", url.lastPathComponent))
      removeMissingRecent(path: url.path)
      return
    }
    selectMode(.pdf)
    NotificationCenter.default.post(name: .linkDeskOpenCanvas, object: nil)
    let transactionId = relay.uploadPDF(data, named: url.lastPathComponent)
    pendingLocalDocument = (document, url, transactionId)
    if let roundTripId {
      pendingRoundTrip = (roundTripId, transactionId, url)
      roundTripSourceURLs[roundTripId] = url
      showExportStatus(L10n.sendingPDF)
    } else {
      showExportStatus("")
    }
  }

  private func commitPendingDocument(_ descriptor: PDFDocumentDescriptor) {
    if let pendingLocalDocument,
       descriptor.transactionId == pendingLocalDocument.transactionId {
      let roundTrip = pendingRoundTrip?.transactionId == pendingLocalDocument.transactionId
        ? pendingRoundTrip
        : nil
      clearSearch()
      document = pendingLocalDocument.document
      sourceURL = pendingLocalDocument.sourceURL
      documentName = descriptor.name
      currentDocumentId = descriptor.documentId
      canvas?.document = pendingLocalDocument.document
      rememberRecent(pendingLocalDocument.sourceURL)
      self.pendingLocalDocument = nil
      applyPendingHistoryIfReady()
      if let roundTrip {
        pendingRoundTrip = nil
        relay.sendRoundTripOpen(roundTripId: roundTrip.roundTripId, document: descriptor)
        showExportStatus(L10n.sentPDF)
      }
      return
    }
    guard currentDocumentId != descriptor.documentId,
          restoringDocumentId != descriptor.documentId else { return }
    restoringDocumentId = descriptor.documentId
    relay.downloadPDF(descriptor) { [weak self] data in
      guard let self, self.restoringDocumentId == descriptor.documentId else { return }
      self.restoringDocumentId = nil
      guard let data, let restored = PDFDocument(data: data) else {
        self.showExportStatus(L10n.restorePDFHint)
        return
      }
      self.clearSearch()
      self.document = restored
      self.sourceURL = nil
      self.documentName = descriptor.name
      self.currentDocumentId = descriptor.documentId
      self.canvas?.document = restored
      self.showExportStatus(descriptor.restoreAvailable == true ? L10n.restoredInk : "")
      self.applyPendingHistoryIfReady()
    }
  }

  private func handleRoundTripReturn(_ message: RelayMessage) {
    guard let roundTripId = message.roundTripId,
          let returnId = message.returnId else { return }
    showExportStatus(L10n.receivingPDF)
    relay.downloadRoundTripReturn(returnId: returnId) { [weak self] data in
      guard let self else { return }
      guard let data else {
        self.showExportStatus(L10n.returnPDFFailure)
        return
      }
      let source = self.roundTripSourceURLs[roundTripId]
      let fallbackBase = source?.deletingPathExtension().lastPathComponent
        ?? URL(fileURLWithPath: message.name ?? "PDF").deletingPathExtension().lastPathComponent
      let panel = NSSavePanel()
      panel.title = L10n.saveReturnPDF
      panel.prompt = L10n.saveToMac
      panel.allowedContentTypes = [.pdf]
      panel.directoryURL = source?.deletingLastPathComponent()
      panel.nameFieldStringValue = fallbackBase + L10n.source("annotatedSuffix")
      guard panel.runModal() == .OK, let destination = panel.url else {
        self.showExportStatus(L10n.returnNotSaved)
        return
      }
      do {
        try data.write(to: destination, options: .atomic)
        self.roundTripSourceURLs.removeValue(forKey: roundTripId)
        self.showExportStatus(L10n.format("saveSuccess", destination.lastPathComponent))
      } catch {
        self.showExportStatus(L10n.format("saveError", error.localizedDescription))
      }
    }
  }

  private func applyPendingHistoryIfReady() {
    guard document != nil else { return }
    if let pendingViewport,
       pendingViewport.documentId == nil || pendingViewport.documentId == currentDocumentId {
      canvas?.apply(pendingViewport)
      if canvas != nil { self.pendingViewport = nil }
    }
    guard let pendingHistorySnapshot,
          pendingHistorySnapshot.documentId == nil
            || pendingHistorySnapshot.documentId == currentDocumentId else { return }
    canvas?.restoreHistory(
      pendingHistorySnapshot.messages,
      cursor: pendingHistorySnapshot.cursor,
      revision: pendingHistorySnapshot.revision
    )
    if canvas != nil {
      let restoredDrawing = pendingHistorySnapshot.messages.contains {
        $0.type == "clear" || $0.type.hasPrefix("stroke:")
      }
      self.pendingHistorySnapshot = nil
      if restoredDrawing { showExportStatus(L10n.restoredInk) }
    }
  }

  func cancelPDFTransfer() {
    relay.cancelPDFUpload()
  }

  func saveAs() {
    guard document != nil else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = sourceURL?.deletingPathExtension().lastPathComponent.appending(L10n.source("exportSuffix")) ?? L10n.source("exportDefaultName")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    showExportStatus(canvas?.export(to: url) == true
      ? L10n.format("saveAsSuccess", url.lastPathComponent)
      : L10n.exportPDFFailure)
  }

  private func showExportStatus(_ status: String) {
    exportStatusDismissWorkItem?.cancel()
    exportStatusDismissWorkItem = nil
    exportStatus = status
    guard !status.isEmpty else { return }
    let isFailure = ["failureMarker", "unavailableMarker", "insufficientMarker"].contains { status.contains(L10n.value($0)) || status.contains(L10n.source($0)) }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.exportStatus == status else { return }
      self.exportStatus = ""
      self.exportStatusDismissWorkItem = nil
    }
    exportStatusDismissWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + (isFailure ? DT.motion.errorNotice : DT.motion.notice),
      execute: workItem
    )
  }

  func undo() { relay.sendHistory("history:undo", mode: mode.rawValue) }
  func redo() { relay.sendHistory("history:redo", mode: mode.rawValue) }
  func clear() {
    relay.sendClear(mode: AppMode.pdf.rawValue)
  }
  func clearWhiteboard() {
    relay.sendClear(mode: AppMode.whiteboard.rawValue)
  }

  private func publishHistoryAvailability() {
    if mode == .whiteboard {
      canUndo = whiteboardCanUndo
      canRedo = whiteboardCanRedo
    } else {
      canUndo = pdfCanUndo
      canRedo = pdfCanRedo
    }
  }
  func zoomIn() {
    if mode == .whiteboard { whiteboardCanvas?.zoom(by: 1.25) }
    else { canvas?.zoomIn() }
  }
  func zoomOut() {
    if mode == .whiteboard { whiteboardCanvas?.zoom(by: 0.8) }
    else { canvas?.zoomOut() }
  }
  func zoomToFit() {
    if mode == .whiteboard { whiteboardCanvas?.resetViewport() }
    else { canvas?.zoomToFit() }
  }

  var hasDocument: Bool {
    document != nil
  }

  func presentSearch() {
    guard mode == .pdf, hasDocument else { return }
    isSearchPresented = true
  }

  func closeSearch() {
    isSearchPresented = false
    clearSearch()
  }

  func updateSearchQuery(_ query: String) {
    searchQuery = query
    canvas?.search(query)
  }

  func nextSearchResult() { canvas?.nextSearchResult() }
  func previousSearchResult() { canvas?.previousSearchResult() }

  func clearSearch() {
    searchQuery = ""
    searchCurrent = 0
    searchTotal = 0
    canvas?.clearSearch()
  }

  var pairingLink: String {
    "http://\(LocalNetwork.ipv4Address ?? "127.0.0.1"):3210/?role=pdfpad&room=\(room)"
  }

  private static func makeRoomCode() -> String {
    let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    return String((0..<6).map { _ in alphabet.randomElement()! })
  }

  private static let roomDefaultsKey = "InkBridgeRoomCode"
  private static let recentDefaultsKey = "InkBridgeRecentPDFsV1"

  private func rememberRecent(_ url: URL) {
    let recent = RecentPDF(path: url.path, name: url.lastPathComponent, openedAt: Date())
    recentPDFs.removeAll { $0.path == recent.path }
    recentPDFs.insert(recent, at: 0)
    recentPDFs = Array(recentPDFs.prefix(8))
    Self.saveRecentPDFs(recentPDFs)
  }

  private func removeMissingRecent(path: String) {
    recentPDFs.removeAll { $0.path == path }
    Self.saveRecentPDFs(recentPDFs)
  }

  private static func loadRecentPDFs() -> [RecentPDF] {
    guard let data = UserDefaults.standard.data(forKey: recentDefaultsKey),
          let values = try? JSONDecoder().decode([RecentPDF].self, from: data) else { return [] }
    return values.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private static func saveRecentPDFs(_ values: [RecentPDF]) {
    guard let data = try? JSONEncoder().encode(values) else { return }
    UserDefaults.standard.set(data, forKey: recentDefaultsKey)
  }
}

enum LocalNetwork {
  static var ipv4Address: String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: interface.ifa_name)
      guard name.hasPrefix("en") else { continue }
      var address = interface.ifa_addr.pointee
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(&address, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return String(decoding: bytes, as: UTF8.self)
    }
    return nil
  }
}
