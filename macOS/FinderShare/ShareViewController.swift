import AppKit
import UniformTypeIdentifiers

@MainActor
@objc(ShareViewController)
final class ShareViewController: NSViewController {
  private let summary = NSTextField(wrappingLabelWithString: "正在连接 LinkDesk…")
  private let spinner = NSProgressIndicator()
  private let close = NSButton(title: "关闭", target: nil, action: nil)
  private let session = URLSession(configuration: .ephemeral)
  private let shareURL = URL(string: "http://127.0.0.1:3212/share")!
  private let limit = 64 * 1024 * 1024
  private var transfer: Task<Void, Never>?

  override func loadView() {
    let title = NSTextField(labelWithString: "发送到 LinkDesk 平板")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    summary.textColor = .secondaryLabelColor
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.startAnimation(nil)
    close.target = self
    close.action = #selector(finishShare)
    close.isHidden = true

    let content = NSStackView(views: [title, summary, spinner, close])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    content.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
    view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 128))
    view.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: view.topAnchor),
      content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])
    preferredContentSize = view.frame.size
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard transfer == nil else { return }
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    let attachments = items.flatMap { $0.attachments ?? [] }
    transfer = Task { await send(attachments) }
  }

  @objc private func finishShare() {
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
  }

  private func send(_ attachments: [NSItemProvider]) async {
    do {
      guard (1...9).contains(attachments.count) else { throw ShareError("请选择 1 至 9 个文件。") }
      try await waitForRelay()
      var failures: [String] = []
      for (index, attachment) in attachments.enumerated() {
        summary.stringValue = "正在发送 \(index + 1)/\(attachments.count)…"
        do { try await upload(attachment) }
        catch { failures.append(error.localizedDescription) }
      }
      if let first = failures.first {
        throw ShareError("已发送 \(attachments.count - failures.count)/\(attachments.count) 个文件。\(first)")
      }
      summary.stringValue = "已发到平板的「文件传送」。"
      spinner.stopAnimation(nil)
      try await Task.sleep(for: .milliseconds(650))
      finishShare()
    } catch {
      spinner.stopAnimation(nil)
      summary.stringValue = error.localizedDescription
      close.isHidden = false
      preferredContentSize.height = 154
    }
  }

  private func waitForRelay() async throws {
    var request = URLRequest(url: shareURL, timeoutInterval: 1)
    request.setValue("1", forHTTPHeaderField: "X-LinkDesk-Finder")
    if (try? await responseCode(request)) == 204 { return }
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.zhekuan.linkdesk.mac").isEmpty {
      let app = Bundle.main.bundleURL.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let config = NSWorkspace.OpenConfiguration()
      config.activates = false
      _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
    }
    for _ in 0..<14 {
      if (try? await responseCode(request)) == 204 { return }
      try await Task.sleep(for: .milliseconds(300))
    }
    throw ShareError("请在 Mac 打开 LinkDesk 并完成配对，再从共享菜单发送。")
  }

  private func responseCode(_ request: URLRequest) async throws -> Int {
    let (_, response) = try await session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
  }

  private func upload(_ provider: NSItemProvider) async throws {
    let file = try await stageFile(provider)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let id = UUID().uuidString.lowercased()
    var request = URLRequest(url: shareURL.appending(path: id), timeoutInterval: 120)
    request.httpMethod = "PUT"
    request.setValue("1", forHTTPHeaderField: "X-LinkDesk-Finder")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    request.setValue(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: nameCharacters),
      forHTTPHeaderField: "X-File-Name")
    if file.pathExtension.lowercased() == "pdf" {
      request.setValue("annotate", forHTTPHeaderField: "X-File-Purpose")
    }
    let (_, response) = try await session.upload(for: request, fromFile: file)
    switch (response as? HTTPURLResponse)?.statusCode {
    case 200, 201: return
    case 413: throw ShareError("单个文件最大 64 MB。")
    case 429: throw ShareError("平板待接收的文件太多。")
    default: throw ShareError("传送暂时不可用，请重试。")
    }
  }

  private func stageFile(_ provider: NSItemProvider) async throws -> URL {
    let maximum = limit
    return try await withCheckedThrowingContinuation { continuation in
      func copy(_ url: URL?, error: Error?) {
        guard let url, url.isFileURL else {
          continuation.resume(throwing: error ?? ShareError("共享内容中没有可发送的文件。"))
          return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
          guard values.isRegularFile == true else { throw ShareError("请选择普通文件。") }
          guard let bytes = values.fileSize, bytes <= maximum else { throw ShareError("单个文件最大 64 MB。") }
          let manager = FileManager.default
          let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
          try manager.createDirectory(at: folder, withIntermediateDirectories: false)
          let staged = folder.appending(path: url.lastPathComponent)
          do { try manager.copyItem(at: url, to: staged) }
          catch {
            try? manager.removeItem(at: folder)
            throw error
          }
          continuation.resume(returning: staged)
        } catch { continuation.resume(throwing: error) }
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
          let backup = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
          copy(item as? URL ?? backup, error: error)
        }
      } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in copy(url, error: error) }
      } else {
        continuation.resume(throwing: ShareError("共享内容中没有可发送的文件。"))
      }
    }
  }
}

private struct ShareError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
