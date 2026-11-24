import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor
final class MirrorQuestionStream: ObservableObject {
  @Published var videoSize: CGSize?
  var cameraWakeTarget: (() -> TabletCameraWakeTarget?)?
  let questions = MirrorQuestionCoordinator(bank: MirrorQuestionCoordinator.supportFolder.appending(path: "QuestionLibrary"))
}

struct TabletMirrorQuestionView: View {
  @ObservedObject var stream: MirrorQuestionStream
  let videoView: TabletMirrorView

  @StateObject private var interaction = Interaction()

  @MainActor
  private final class Interaction: ObservableObject {
    @Published var selection: CGRect?
    @Published var captureTask: Task<Void, Never>?
    @Published var sheet: Sheet?
    @Published var captureError: String?
    @Published var autoID: UUID?
    var autoGeneration = UUID()
    var lastVideoSize: CGSize?
    @Published var autoState: AutoState = .waiting
    @Published var cameraWaking = false

    enum ScanState {
      case starting, noFrame, noDetail, stabilizing
    }

    @Published var scanState: ScanState = .starting

    func setScanState(_ state: ScanState) {
      if scanState != state { scanState = state }
    }

    enum AutoState {
      case waiting, searching, verifying, result(MirrorSolvedQuestion), error(String)
    }
  }

  private struct Sheet: Identifiable {
    let id = UUID()
    var image: CGImage?
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: DT.spacing.s8) {
        Image(systemName: "viewfinder").accessibilityHidden(true)
        Text(hint).lineLimit(1)
        Spacer(minLength: 4)
        Button {
          captureQuestion()
        } label: {
          Label(mirrorQuestionText("快速解题", "Quick Solve"), systemImage: "text.viewfinder")
        }
        .buttonStyle(.borderedProminent)
        .disabled(interaction.selection == nil || interaction.captureTask != nil || interaction.autoID != nil || stream.videoSize == nil)
        Button {
          if interaction.autoID == nil {
            interaction.autoState = .waiting
            interaction.cameraWaking = false
            interaction.setScanState(.starting)
            interaction.autoID = UUID()
          } else {
            interaction.autoID = nil
          }
        } label: {
          Label(interaction.autoID == nil ? t("自动识题", "Auto Search") : t("停止自动识题", "Stop Auto Search"),
                systemImage: interaction.autoID == nil ? "play.circle" : "stop.circle")
        }
        .help(t("画面稳定后自动把题图发给所选模型", "Send the selected image to the chosen model when it is steady"))
        .disabled(interaction.selection == nil || interaction.captureTask != nil || stream.videoSize == nil)
        Button {
          interaction.autoID = nil
          interaction.sheet = Sheet()
        } label: {
          Image(systemName: "gearshape")
        }
        .accessibilityLabel(mirrorQuestionText("识题设置", "Question Search Settings"))
        .help(mirrorQuestionText("设置 DeepSeek API 密钥", "Set the DeepSeek API key"))
      }
      .padding(.horizontal, DT.spacing.s12)
      .frame(height: 44)
      .background(.bar)

      MirrorVideoRepresentable(videoView: videoView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { selectionOverlay }

      if interaction.autoID != nil {
        Divider()
        autoResult
      }
    }
    .onChange(of: stream.videoSize) { _, size in
      guard let size else { return }
      defer { interaction.lastVideoSize = size }
      guard let former = interaction.lastVideoSize, former != size else { return }
      interaction.autoID = nil
      interaction.captureTask?.cancel()
      interaction.captureTask = nil
      interaction.selection = nil
      interaction.sheet = nil
    }
    .onAppear { if let size = stream.videoSize { interaction.lastVideoSize = size } }
    .onExitCommand {
      if interaction.autoID == nil { interaction.selection = nil }
      else { interaction.autoID = nil }
    }
    .task(id: interaction.autoID) {
      if let id = interaction.autoID { await monitor(id: id) }
    }
    .sheet(item: $interaction.sheet) { MirrorQuestionSheet(image: $0.image, questions: stream.questions) }
    .alert(
      mirrorQuestionText("题图截取失败", "Couldn’t Capture Question"),
      isPresented: Binding(
        get: { interaction.captureError != nil },
        set: { if !$0 { interaction.captureError = nil } }
      )
    ) {
      Button(mirrorQuestionText("好", "OK"), role: .cancel) {}
    } message: {
      Text(interaction.captureError ?? "")
    }
  }

  private let t = mirrorQuestionText

  private var hint: String {
    let t = mirrorQuestionText
    if interaction.captureTask != nil { return t("正在截取题图…", "Capturing the question…") }
    if stream.videoSize == nil { return t("等待平板画面…", "Waiting for the tablet…") }
    if interaction.autoID != nil { return t("自动识题已开启", "Auto search is on") }
    if interaction.selection != nil { return t("已框选题目", "Question selected") }
    return t("在投屏画面上拖动框选题目", "Drag over the question to select it")
  }

  @ViewBuilder
  private var selectionOverlay: some View {
    if let videoSize = stream.videoSize {
      GeometryReader { geometry in
        let video = AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geometry.size))
        if video.width > 0, video.height > 0 {
          Color.clear
            .contentShape(Rectangle())
            .overlay {
              if let selection = interaction.selection {
                let rect = CGRect(
                  x: selection.minX * video.width, y: selection.minY * video.height,
                  width: selection.width * video.width, height: selection.height * video.height
                )
                // Draw the outline outside the crop so it stays out of the uploaded image.
                Rectangle()
                  .strokeBorder(.white, lineWidth: 2)
                  .shadow(color: .black.opacity(0.8), radius: 2)
                  .frame(width: rect.width + 6, height: rect.height + 6)
                  .position(x: rect.midX, y: rect.midY)
                  .allowsHitTesting(false)
              }
            }
            .frame(width: video.width, height: video.height)
            .gesture(DragGesture(minimumDistance: 2)
              .onChanged { value in
                interaction.selection = region(from: value.startLocation, to: value.location, size: video.size)
              }
              .onEnded { value in
                interaction.selection = region(from: value.startLocation, to: value.location, size: video.size)
              })
            .allowsHitTesting(interaction.captureTask == nil && interaction.autoID == nil)
            .position(x: video.midX, y: video.midY)
            .accessibilityHidden(true)
        }
      }
    }
  }

  private var autoResult: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if interaction.cameraWaking {
          Label(t("相机已待机，等待预览恢复…", "Camera is asleep. Waiting for the preview…"),
                systemImage: "camera")
        }
        switch interaction.autoState {
        case .waiting:
          Text(scanHint)
        case .searching:
          HStack {
            ProgressView().controlSize(.small)
            Text(t("\(MirrorSolveProvider.preference.title) 正在看图解题…", "\(MirrorSolveProvider.preference.title) is solving the question…"))
          }
        case .verifying:
          HStack {
            ProgressView().controlSize(.small)
            Text(t("正在联网核对题目…", "Checking the question online…"))
          }
        case .result(let report):
          MirrorSolvedQuestionView(question: report, questions: stream.questions).id(report.id)
        case .error(let message):
          Label(message, systemImage: "exclamationmark.circle").foregroundStyle(DT.error)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .textSelection(.enabled)
    }
    .frame(height: 180)
    .background(.bar)
  }

  private var scanHint: String {
    switch interaction.scanState {
    case .starting: t("正在读取框内画面…", "Reading the selected area…")
    case .noFrame: t("暂时无法截取投屏画面，正在重试…", "Unable to capture the mirrored image. Retrying…")
    case .noDetail: t("框内图形不够清晰。请让题目对焦并填满框内区域。", "The selection needs more detail. Focus the question and fill the selection.")
    case .stabilizing: t("已读到框内画面，正在确认是否稳定…", "Image captured. Checking whether it is steady…")
    }
  }

  private func monitor(id: UUID) async {
    guard let selection = interaction.selection, let videoSize = stream.videoSize else { return }
    let provider = MirrorSolveProvider.preference
    var stability = StableMirrorQuestion()
    var searchTask: Task<Void, Never>?
    defer { searchTask?.cancel() }
    let clock = ContinuousClock()
    var nextWakeCheck = clock.now

    while !Task.isCancelled, interaction.autoID == id {
      do { try await Task.sleep(for: .milliseconds(500)) }
      catch { return }
      guard let window = videoView.window, window.isVisible, !window.isMiniaturized else { continue }
      if clock.now >= nextWakeCheck {
        if let target = stream.cameraWakeTarget?() {
          let prompt = await target.readPrompt()
          guard !Task.isCancelled, interaction.autoID == id else { return }
          switch prompt {
          case .asleep(let point) where !interaction.cameraWaking:
            interaction.cameraWaking = true
            _ = stability.observe(nil)
            if videoView.window === window, window.isVisible, !window.isMiniaturized,
               stream.cameraWakeTarget?() == target {
              await target.tap(point)
            }
          case .clear:
            interaction.cameraWaking = false
          default: break
          }
        }
        nextWakeCheck = clock.now.advanced(by: .seconds(2))
      }
      guard !Task.isCancelled, interaction.autoID == id else { return }
      guard !interaction.cameraWaking, stream.videoSize == videoSize else { continue }
      guard let image = try? await MirrorQuestionCapture.capture(selection: selection, videoSize: videoSize, view: videoView) else {
        interaction.setScanState(.noFrame)
        _ = stability.observe(nil)
        continue
      }
      let transcript = await MirrorQuestionSearch.recognizeText(in: image)
      guard !Task.isCancelled, interaction.autoID == id else { return }
      if transcript.filter({ !$0.isWhitespace }).contains(TabletCameraWakeTarget.promptText) {
        _ = stability.observe(nil)
        continue
      }
      guard let frame = MirrorQuestionFrame(image: image) else {
        interaction.setScanState(.noDetail)
        _ = stability.observe(nil)
        continue
      }
      interaction.setScanState(.stabilizing)
      guard let question = stability.observe(frame) else { continue }

      searchTask?.cancel()
      let generation = UUID()
      interaction.autoGeneration = generation
      interaction.autoState = .searching
      searchTask = Task { @MainActor in
        do {
          let report = try await stream.questions.solve(image: image, frame: question, transcript: transcript,
                                                        provider: provider) {
            if interaction.autoID == id, interaction.autoGeneration == generation {
              interaction.autoState = .verifying
            }
          }
          guard !Task.isCancelled, interaction.autoID == id else { return }
          interaction.autoState = .result(report)
        } catch {
          guard !Task.isCancelled, interaction.autoID == id else { return }
          interaction.autoState = .error(error.localizedDescription)
        }
      }
    }
  }

  private func region(from start: CGPoint, to end: CGPoint, size: CGSize) -> CGRect? {
    let points = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(start.x - end.x), height: abs(start.y - end.y)
    ).intersection(CGRect(origin: .zero, size: size))
    guard !points.isNull, points.width >= 12, points.height >= 12 else { return nil }
    return CGRect(x: points.minX / size.width, y: points.minY / size.height,
                  width: points.width / size.width, height: points.height / size.height)
  }

  private func captureQuestion() {
    guard let selection = interaction.selection, let videoSize = stream.videoSize, interaction.captureTask == nil else { return }
    interaction.captureTask = Task { @MainActor in
      do {
        let image = try await MirrorQuestionCapture.capture(selection: selection, videoSize: videoSize, view: videoView)
        try Task.checkCancellation()
        interaction.sheet = Sheet(image: image)
      } catch {
        if Task.isCancelled { return }
        interaction.captureError = MirrorQuestionError.capture.localizedDescription
      }
      interaction.captureTask = nil
    }
  }
}

private struct MirrorVideoRepresentable: NSViewRepresentable {
  let videoView: TabletMirrorView
  func makeNSView(context: Context) -> TabletMirrorView { videoView }
  func updateNSView(_ nsView: TabletMirrorView, context: Context) {}
}

@MainActor
enum MirrorQuestionCapture {
  static func capture(selection: CGRect, videoSize: CGSize, view: NSView) async throws -> CGImage {
    guard let window = view.window, window.isVisible, !window.isMiniaturized else {
      throw MirrorQuestionError.capture
    }
    let windowID = CGWindowID(window.windowNumber)
    let shareable: SCShareableContent
    if #available(macOS 14.4, *) {
      shareable = try await SCShareableContent.currentProcess
    } else {
      shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    try Task.checkCancellation()
    guard let source = shareable.windows.first(where: { $0.windowID == windowID }),
          view.window === window, window.isVisible else { throw MirrorQuestionError.capture }

    let video = AVMakeRect(aspectRatio: videoSize, insideRect: view.bounds)
    let videoOnScreen = window.convertToScreen(view.convert(video, to: nil))
    let bounds = window.frame
    // AppKit screen coordinates start at the lower left. Captured image rows start at the top.
    let selectedInWindow = CGRect(
      x: videoOnScreen.minX - bounds.minX + selection.minX * videoOnScreen.width,
      y: bounds.maxY - videoOnScreen.maxY + selection.minY * videoOnScreen.height,
      width: selection.width * videoOnScreen.width,
      height: selection.height * videoOnScreen.height
    )
    let filter = SCContentFilter(desktopIndependentWindow: source)
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    guard scale > 0, bounds.width > 0, bounds.height > 0 else { throw MirrorQuestionError.capture }
    config.width = Int((bounds.width * scale).rounded())
    config.height = Int((bounds.height * scale).rounded())
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    if #available(macOS 14.2, *) { config.includeChildWindows = false }
    let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    try Task.checkCancellation()
    guard window.frame == bounds,
          window.convertToScreen(view.convert(AVMakeRect(aspectRatio: videoSize, insideRect: view.bounds), to: nil)) == videoOnScreen
    else { throw MirrorQuestionError.capture }

    let horizontalScale = CGFloat(screenshot.width) / bounds.width
    let verticalScale = CGFloat(screenshot.height) / bounds.height
    let crop = CGRect(
      x: selectedInWindow.minX * horizontalScale, y: selectedInWindow.minY * verticalScale,
      width: selectedInWindow.width * horizontalScale, height: selectedInWindow.height * verticalScale
    ).integral
    guard let image = screenshot.cropping(to: crop) else { throw MirrorQuestionError.capture }
    return image
  }
}

private struct MirrorQuestionSheet: View {
  let image: CGImage?
  let questions: MirrorQuestionCoordinator
  @Environment(\.dismiss) private var dismiss
  @StateObject private var searchState = SearchState()

  @MainActor
  private final class SearchState: ObservableObject {
    enum Phase {
      case loading, verifying, keyEntry, failure, complete(MirrorSolvedQuestion)
    }

    @Published var apiKey = ""
    @Published var provider = MirrorSolveProvider.preference {
      didSet { MirrorSolveProvider.preference = provider }
    }
    @Published var phase: Phase = .loading
    @Published var requestID = 0
    @Published var error: String?
  }

  private let t = mirrorQuestionText

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(image == nil ? t("识题设置", "Question Search Settings") : t("识题结果", "Question Search"))
          .font(.title2.weight(.semibold))
        Spacer()
        Button(t("关闭", "Close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let image, !hasResult {
            preview(image)
          }

          if let error = searchState.error {
            Label(error, systemImage: "exclamationmark.circle")
              .foregroundStyle(DT.error)
          }

          switch image == nil ? .keyEntry : searchState.phase {
          case .keyEntry:
            if image == nil {
              Picker(t("解题模型", "Solver"), selection: $searchState.provider) {
                ForEach(MirrorSolveProvider.allCases) { provider in
                  Text(provider.title).tag(provider)
                }
              }
              Text(t("GPT 使用本机已登录的 ChatGPT/Codex。搜原题使用 DeepSeek。", "GPT uses the ChatGPT sign-in in Codex. Original-question lookup uses DeepSeek."))
                .foregroundStyle(.secondary)
              Divider()
            }
            keyEntry
          case .loading:
            HStack {
              ProgressView().controlSize(.small)
              Text(t("\(MirrorSolveProvider.preference.title) 正在看图解题…", "\(MirrorSolveProvider.preference.title) is solving the question…"))
            }
          case .verifying:
            HStack {
              ProgressView().controlSize(.small)
              Text(t("正在联网核对题目…", "Checking the question online…"))
            }
          case .complete(let report):
            MirrorSolvedQuestionView(question: report, questions: questions).id(report.id)
            if let image { preview(image) }
          case .failure:
            HStack {
              Button(t("重试", "Retry")) { startSearch() }.buttonStyle(.borderedProminent)
              Button(t("更换密钥", "Change API Key")) {
                searchState.error = nil
                searchState.phase = .keyEntry
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .textSelection(.enabled)
      }
    }
    .frame(width: 500, height: image == nil ? 300 : 530)
    .onAppear {
      if image != nil, searchState.requestID == 0 { startSearch() }
    }
    .task(id: searchState.requestID) {
      if searchState.requestID > 0 { await search() }
    }
  }

  private var hasResult: Bool {
    if case .complete = searchState.phase { return true }
    return false
  }

  private func preview(_ image: CGImage) -> some View {
    Image(decorative: image, scale: 1)
      .resizable()
      .scaledToFit()
      .frame(maxWidth: .infinity, maxHeight: 136)
      .padding(8)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityLabel(t("框选的题图", "Captured question"))
  }

  private var keyEntry: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(t("配置 DeepSeek API 密钥，用于搜原题或用 DeepSeek 解题。密钥保存在 Mac 钥匙串中，相关用量由你的 DeepSeek 账号计费。",
             "Set a DeepSeek API key for original-question lookup or DeepSeek solving. The key is stored in your Mac keychain. Those requests are billed to your DeepSeek account."))
        .foregroundStyle(.secondary)
      SecureField("DeepSeek API Key", text: $searchState.apiKey)
        .onSubmit(saveKey)
      HStack {
        Link(t("获取 API 密钥", "Get an API Key"), destination: URL(string: "https://platform.deepseek.com/api_keys")!)
        Spacer()
        Button(image == nil ? t("保存", "Save") : t("保存并解题", "Save and Solve"), action: saveKey)
          .buttonStyle(.borderedProminent)
          .disabled(!validKey)
      }
    }
  }

  private var trimmedKey: String { searchState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var validKey: Bool { trimmedKey.hasPrefix("sk-") && !trimmedKey.contains(where: \.isWhitespace) }

  private func saveKey() {
    guard validKey else { return }
    do {
      try MirrorQuestionKeychain.save(trimmedKey)
      searchState.apiKey = ""
      if image == nil { dismiss() } else { startSearch() }
    } catch {
      searchState.error = error.localizedDescription
    }
  }

  private func startSearch() {
    searchState.error = nil
    searchState.phase = .loading
    searchState.requestID += 1
  }

  private func search() async {
    guard let image else { return }
    do {
      let requestID = searchState.requestID
      let response = try await questions.solve(image: image, frame: nil, transcript: nil, provider: searchState.provider) {
        if searchState.requestID == requestID { searchState.phase = .verifying }
      }
      try Task.checkCancellation()
      searchState.phase = .complete(response)
    } catch {
      guard !Task.isCancelled else { return }
      searchState.error = error.localizedDescription
      switch error as? MirrorQuestionError {
      case .authentication, .keychain: searchState.phase = .keyEntry
      default: searchState.phase = .failure
      }
    }
  }

}

private struct MirrorSolvedQuestionView: View {
  let question: MirrorSolvedQuestion
  let questions: MirrorQuestionCoordinator
  @StateObject private var source = SourceState()
  private let t = mirrorQuestionText

  @MainActor
  private final class SourceState: ObservableObject {
    @Published var requestID = 0
    @Published var loading = false
    @Published var report: MirrorQuestionReport?
    @Published var error: String?
  }

  var body: some View {
    let availableSource = source.report ?? question.review
    let published = availableSource?.publishedAnswer
    let result = published ?? question.result
    let hasAnswer = result.match != .unreadable && result.match != .uncertain
    let canCheckPublishedAnswer = source.report == nil && availableSource?.original != nil && published == nil
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(published == nil ? t("答案", "Answer") : t("原题答案", "Published Answer")).font(.headline).foregroundStyle(.secondary)
          Text(verbatim: answerTitle(result, hasAnswer: hasAnswer))
            .font(.system(size: hasAnswer ? 30 : 20, weight: .bold))
        }
        .accessibilityElement(children: .combine)
        Spacer()
        if result.match != .unreadable, availableSource == nil || canCheckPublishedAnswer {
          Button {
            source.error = nil
            source.loading = true
            source.requestID += 1
          } label: {
            Label(canCheckPublishedAnswer ? t("核对原题答案", "Check Published Answer") : t("搜原题", "Find Original"), systemImage: "magnifyingglass")
          }
          .disabled(source.loading)
        }
      }
      if !hasAnswer, !result.matchNote.isEmpty {
        Text(verbatim: result.matchNote)
      } else {
        ForEach(result.steps.indices, id: \.self) { index in
          Text(verbatim: result.steps[index])
        }
      }
      if source.loading {
        HStack {
          ProgressView().controlSize(.small)
          Text(t("正在查找原题出处…", "Looking for the original question…"))
        }
      }
      if availableSource == nil, let error = source.error ?? question.reviewError {
        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(DT.error)
      }
      if let report = availableSource {
        Divider()
        sourceResult(report)
        if !hasAnswer, !report.result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(t("联网复核倾向", "Tentative answer after web review") + " · " + report.result.answer)
            .font(.headline)
          ForEach(report.result.steps.indices, id: \.self) { index in
            Text(verbatim: report.result.steps[index])
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .task(id: source.requestID) {
      if source.requestID > 0 { await findSource() }
    }
  }

  private func answerTitle(_ result: MirrorQuestionResult, hasAnswer: Bool) -> String {
    if hasAnswer { return result.answer }
    if result.match == .unreadable { return t("题图需要补拍", "A clearer image is needed") }
    return t("答案暂不确定", "Answer uncertain")
  }

  private func findSource() async {
    do {
      let report = try await questions.findSource(for: question)
      try Task.checkCancellation()
      source.report = report
      source.loading = false
    } catch {
      guard !Task.isCancelled else { return }
      source.error = error.localizedDescription
      source.loading = false
    }
  }

  private func sourceResult(_ report: MirrorQuestionReport) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let original = report.original {
        Link(destination: original.url) {
          Label(t("原题链接", "Original Question") + " · " + original.label, systemImage: "arrow.up.right")
        }
      } else {
        Text(sourceStatus(report.result.match)).font(.headline)
      }
      if !report.result.matchNote.isEmpty, report.result.match != .exact || report.original != nil {
        Text(verbatim: report.result.matchNote).foregroundStyle(.secondary)
      }
      ForEach(report.sources.prefix(5)) { item in
        Link(item.label, destination: item.url)
      }
    }
  }

  private func sourceStatus(_ match: MirrorQuestionResult.Match) -> String {
    switch match {
    case .exact, .notFound, .uncertain: t("未找到可确认的原题链接", "No confirmed original question found")
    case .similar: t("找到相似题目", "Related questions found")
    case .unreadable: t("题图有内容看不清，请重新框选", "Part of the question is unclear. Select a new crop.")
    }
  }
}
