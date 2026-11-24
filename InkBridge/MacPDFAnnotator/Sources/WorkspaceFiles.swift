import AppKit
import CryptoKit
import SwiftUI

@MainActor
final class WorkspaceFiles: ObservableObject {
  static let shared = WorkspaceFiles()
  @Published private(set) var status = ""
  @Published private(set) var busy = false
  @Published private(set) var lastReceived: URL?
  @Published private(set) var pendingCount = 0

  private struct Transfer: Decodable {
    let id: String
    let name: String
    let size: Int
    let sha256: String
    let annotationID: String?
    let transport: String?
  }

  private struct TransferError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  private let session = URLSession(configuration: .ephemeral)
  private let limit = 64 * 1024 * 1024
  private let receiptKey = "LinkDeskFileReceipts"
  private let deferredKey = "LinkDeskDeferredFileSaves"
  private var deferred: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "LinkDeskDeferredFileSaves") ?? [])
  private var room = ""
  private var poller: Task<Void, Never>?
  private var sender: Task<Void, Never>?

  func start(room: String) {
    guard self.room != room || poller == nil else { return }
    self.room = room
    poller?.cancel()
    poller = Task { [weak self] in
      while !Task.isCancelled {
        await self?.receive(room: room)
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }

  func chooseFiles() {
    let picker = NSOpenPanel()
    picker.title = "发送文件到平板"
    picker.prompt = "发送"
    picker.allowsMultipleSelection = true
    picker.canChooseDirectories = false
    if picker.runModal() == .OK { send(picker.urls) }
  }

  @discardableResult
  func send(_ urls: [URL]) -> Bool {
    guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
    guard sender == nil else { return false }
    busy = true
    sender = Task { [weak self] in
      guard let self else { return }
      defer { sender = nil; busy = false }
      var failed: [String] = []
      for (index, url) in urls.enumerated() {
        status = "正在发送 \(index + 1)/\(urls.count) · \(url.lastPathComponent)"
        do { try await upload(url) }
        catch {
          failed.append("\(url.lastPathComponent)（\(error.localizedDescription)）")
        }
      }
      status = failed.isEmpty ? "已发送 \(urls.count) 个文件，请在平板打开文件传送" :
        "已发送 \(urls.count - failed.count)/\(urls.count) · \(failed.joined(separator: "、"))"
    }
    return true
  }

  func savePendingFiles() {
    deferred.removeAll()
    UserDefaults.standard.removeObject(forKey: deferredKey)
  }

  func openReceiveFolder() {
    if let folder = try? downloadsFolder() { NSWorkspace.shared.open(folder) }
  }

  private func endpoint(_ recipient: String, room: String, id: String? = nil) -> URL {
    let root = URL(string: "http://127.0.0.1:3210")!
    let list = root.appending(path: "/api/files/\(room)/\(recipient)")
    return id.map { list.appending(path: $0) } ?? list
  }

  private func upload(_ url: URL) async throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw TransferError("请选择普通文件") }
    guard let size = values.fileSize, size <= limit else { throw TransferError("单个文件最大 64 MB") }
    guard !room.isEmpty else { throw TransferError("请先打开 LinkDesk 并完成配对") }
    let id = UUID().uuidString.lowercased()
    var request = URLRequest(url: endpoint("tablet", room: room, id: id), timeoutInterval: 120)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(size), forHTTPHeaderField: "Content-Length")
    var nameCharacters = CharacterSet.alphanumerics
    nameCharacters.formUnion(CharacterSet(charactersIn: "-._~"))
    request.setValue(url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: nameCharacters),
      forHTTPHeaderField: "X-File-Name")
    if url.pathExtension.lowercased() == "pdf" {
      request.setValue("annotate", forHTTPHeaderField: "X-File-Purpose")
    }
    let (_, response) = try await session.upload(for: request, fromFile: url)
    try check(response)
  }

  private func receive(room: String) async {
    guard !room.isEmpty else { return }
    let inbox = endpoint("mac", room: room)
    do {
      let (list, response) = try await session.data(from: inbox)
      try check(response)
      let items = try JSONDecoder().decode([Transfer].self, from: list)
      let existingReceipts = UserDefaults.standard.dictionary(forKey: receiptKey) as? [String: Date] ?? [:]
      pendingCount = items.filter { existingReceipts[$0.id] == nil }.count
      for item in items {
        guard !Task.isCancelled else { return }
        let download = inbox.appending(path: item.id)
        var receipts = UserDefaults.standard.dictionary(forKey: receiptKey) as? [String: Date] ?? [:]
        if receipts[item.id] == nil {
          guard !deferred.contains(item.id) else { continue }
          do {
            let (temporary, response) = try await session.download(from: download)
            try check(response)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try verify(temporary, item: item)
            guard let saved = try await saveFile(temporary, item: item) else {
              deferSave(item.id)
              if !busy { status = "待保存 · \(item.name)" }
              continue
            }
            receipts[item.id] = Date()
            pendingCount = max(0, pendingCount - 1)
            let retained = receipts.sorted { $0.value > $1.value }.prefix(128)
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) }), forKey: receiptKey)
            lastReceived = saved
            if !busy {
              let transport = item.transport.map { "（\($0)）" } ?? ""
              status = "已保存\(transport) · \(saved.lastPathComponent)"
            }
          } catch {
            deferSave(item.id)
            if !busy { status = "接收失败 · \(item.name) · \(error.localizedDescription)" }
            continue
          }
        }
        var acknowledgement = URLRequest(url: download)
        acknowledgement.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: acknowledgement)
        try check(response)
      }
    } catch {
      // The local relay can be starting or reconnecting. The next poll retries.
    }
  }

  private func verify(_ url: URL, item: Transfer) throws {
    guard item.size >= 0, item.size <= limit,
          try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == item.size else {
      throw TransferError("文件大小不一致")
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    while let bytes = try file.read(upToCount: 256 * 1024), !bytes.isEmpty {
      digest.update(data: bytes)
    }
    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else {
      throw TransferError("文件校验失败")
    }
  }

  private func downloadsFolder() throws -> URL {
    let folder = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appending(path: "LinkDesk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func deferSave(_ id: String) {
    deferred.insert(id)
    UserDefaults.standard.set(Array(deferred), forKey: deferredKey)
  }

  private func saveFile(_ temporary: URL, item: Transfer) async throws -> URL? {
    let folder = try downloadsFolder()
    let name = (item.name as NSString).lastPathComponent
    guard name == item.name, name != ".", name != "..", !name.isEmpty else {
      throw TransferError("文件名无效")
    }
    let ext = (name as NSString).pathExtension
    var stem = (name as NSString).deletingPathExtension
    if item.annotationID != nil && ext.lowercased() == "pdf" { stem += " - 批注" }
    let suffix = ext.isEmpty ? "" : "." + ext
    var index = 1
    var suggested = stem + suffix
    while FileManager.default.fileExists(atPath: folder.appending(path: suggested).path) {
      index += 1
      suggested = stem + " (\(index))" + suffix
    }

    let panel = NSSavePanel()
    panel.title = "保存来自平板的文件"
    panel.message = item.transport.map { "收到文件 · \($0)" } ?? "收到来自平板的文件"
    panel.nameFieldStringValue = suggested
    panel.directoryURL = folder
    panel.canCreateDirectories = true
    NSApp.activate(ignoringOtherApps: true)
    let result = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    guard result == .OK, let destination = panel.url else { return nil }
    try Data(contentsOf: temporary, options: .mappedIfSafe).write(to: destination, options: .atomic)
    return destination
  }

  private func check(_ response: URLResponse) throws {
    switch (response as? HTTPURLResponse)?.statusCode {
    case 200, 201: return
    case 404: throw TransferError("连接未就绪，请先完成配对")
    case 413: throw TransferError("单个文件最大 64 MB")
    case 429: throw TransferError("接收端待处理文件太多")
    default: throw TransferError("传输暂时不可用，请重试")
    }
  }
}
