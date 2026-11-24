import CoreGraphics
import Foundation

@main
struct MirrorQuestionSearchTests {
  static func main() async throws {
    var stability = StableMirrorQuestion()
    let firstImage = visualQuestion(changedOption: false)
    let secondImage = visualQuestion(changedOption: true)
    let diagram = MirrorQuestionFrame(image: firstImage)!
    let slightlyDimmer = MirrorQuestionFrame(image: visualQuestion(changedOption: false, brightness: 0.96))!
    let nextDiagram = MirrorQuestionFrame(image: secondImage)!
    precondition(diagram.matches(slightlyDimmer))
    precondition(!diagram.matches(nextDiagram), "A changed option must be detected despite identical OCR.")
    precondition(MirrorQuestionFrame(image: visualQuestion(changedOption: nil)) == nil)
    precondition(stability.observe(diagram) == nil)
    precondition(stability.observe(slightlyDimmer) != nil)
    let black = MirrorQuestionFrame(image: visualQuestion(changedOption: nil, brightness: 0.02))
    precondition(black == nil)
    precondition(stability.observe(black) == nil)
    precondition(stability.observe(diagram) == nil)
    precondition(stability.observe(diagram) == nil, "Restoring the same view must not trigger a new solve.")
    precondition(stability.observe(nextDiagram) == nil)
    precondition(stability.observe(nil) == nil)
    precondition(stability.observe(nextDiagram) == nil)
    precondition(stability.observe(nextDiagram) != nil)
    precondition(stability.observe(nextDiagram) == nil)

    let shifted = MirrorQuestionFrame(image: visualQuestion(changedOption: false, shift: 5))!
    precondition(diagram.matches(shifted), "A little camera movement must not stall recognition.")
    precondition(!shifted.matches(nextDiagram))

    try await testSharedCache(firstImage, next: secondImage)

    let verified = try MirrorQuestionSearch.decodeResponse(fixture(openedPage: true))
    precondition(verified.original?.url.absoluteString == "https://example.org/algebra")
    precondition(verified.result.steps == ["Subtract 1 from both sides."])
    precondition(verified.sources.isEmpty, "The original link should appear once.")

    let unopened = try MirrorQuestionSearch.decodeResponse(fixture(openedPage: false))
    precondition(unopened.original == nil, "A citation alone must not be shown as the original.")

    do {
      _ = try MirrorQuestionSearch.decodeResponse(fixture(openedPage: false, searched: false))
      fatalError("A readable question requires a successful web search.")
    } catch MirrorQuestionError.noSearch {
      // Expected when Flash answers without making its optional web tool call.
    }
    let unreadable = try MirrorQuestionSearch.decodeResponse(
      fixture(openedPage: false, searched: false, match: "unreadable")
    )
    precondition(unreadable.result.match == .unreadable)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DeepSeekFixtureProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let canvas = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    canvas.setFillColor(CGColor(gray: 1, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let input = try await MirrorQuestionInput.prepare(image: canvas.makeImage()!, transcript: "x + 1 = 3")
    let solved = try await MirrorQuestionSearch.request(.solve, input: input, key: "sk-fixture", session: session)
    precondition(solved.result.answer == "2" && solved.original == nil)
    let source = try await MirrorQuestionSearch.request(.findSource, input: input, key: "sk-fixture", session: session)
    precondition(source.original?.url.host() == "example.org")
    let uncertain = try MirrorQuestionSearch.decodeResponse(
      fixture(openedPage: false, searched: false, match: "uncertain"), operation: .solve
    )
    precondition(uncertain.result.match == .uncertain && uncertain.result.answer.isEmpty)
    print("DeepSeek quick solve and original-source request validation passed.")
  }

  @MainActor
  private static func testSharedCache(_ image: CGImage, next: CGImage) async throws {
    var solvedCount = 0
    var verificationCount = 0
    var sourceCount = 0
    let review = try MirrorQuestionSearch.decodeResponse(fixture(openedPage: true))
    let uncertain = try MirrorQuestionSearch.decodeResponse(
      fixture(openedPage: false, searched: false, match: "uncertain"), operation: .solve
    ).result
    let bank = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: bank) }
    let coordinator = MirrorQuestionCoordinator(bank: bank, solve: { input, _ in
      solvedCount += 1
      try await Task.sleep(for: .milliseconds(20))
      let direct = MirrorQuestionResult(question: "", match: .notFound, matchURL: nil, matchNote: "",
                                        steps: ["Direct model reasoning"], answer: "1")
      let result = input.transcript == "first" ? uncertain : direct
      return MirrorSolvedQuestion(input: input, result: result)
    }, lookup: { _, operation in
      if operation == .verify { verificationCount += 1 }
      else { sourceCount += 1 }
      return review
    })

    async let automatic = coordinator.solve(image: image, frame: nil, transcript: "first", provider: .gpt) {}
    async let repeated = coordinator.solve(image: image, frame: nil, transcript: "first", provider: .gpt) {}
    let (original, same) = try await (automatic, repeated)
    precondition(solvedCount == 1 && verificationCount == 1)
    precondition(original.id == same.id && same.result.answer == "2")
    let manual = try await coordinator.solve(image: image, frame: nil, transcript: nil, provider: .deepSeek) {}
    precondition(manual.id == original.id && solvedCount == 1 && verificationCount == 1)
    _ = try await coordinator.findSource(for: manual)
    precondition(sourceCount == 0, "An automatic verification must serve the manual source request.")

    let different = try await coordinator.solve(image: next, frame: nil, transcript: "next", provider: .gpt) {}
    precondition(different.id != original.id && different.result.answer == "1" && solvedCount == 2 && verificationCount == 1)
    _ = try await coordinator.findSource(for: different)
    _ = try await coordinator.findSource(for: different)
    precondition(sourceCount == 1, "Repeated explicit lookups must reuse the first result.")
    let updated = try await coordinator.solve(image: next, frame: nil, transcript: nil, provider: .gpt) {}
    precondition(updated.result.answer == "2", "The original published answer should replace the direct answer.")
    let reopened = MirrorQuestionCoordinator(bank: bank, solve: { _, _ in fatalError("Saved answer hit the model") })
    let saved = try await reopened.solve(image: image, frame: nil, transcript: nil, provider: .gpt) {}
    precondition(saved.id == original.id && saved.result.answer == "2" && saved.review?.original != nil)
    let storedUpdate = try await reopened.solve(image: next, frame: nil, transcript: nil, provider: .gpt) {}
    precondition(storedUpdate.result.answer == "2" && storedUpdate.review?.original != nil)

    var deadlineReviews = 0
    let delayed = MirrorQuestionCoordinator(reviewDelay: .milliseconds(15), solve: { _, _ in
      try await Task.sleep(for: .seconds(3))
      fatalError("The verified result must finish without waiting for the slow model.")
    }, lookup: { _, operation in
      precondition(operation == .verify)
      deadlineReviews += 1
      return review
    })
    let timed = try await delayed.solve(image: image, frame: nil, transcript: "same", provider: .gpt) {}
    let recovered = try await delayed.solve(image: image, frame: nil, transcript: "same", provider: .gpt) {}
    precondition(timed.id == recovered.id && timed.result.answer == "2" && deadlineReviews == 1)
  }

  private static func visualQuestion(changedOption: Bool?, brightness: CGFloat = 1, shift: CGFloat = 0) -> CGImage {
    let canvas = CGContext(data: nil, width: 320, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    canvas.setFillColor(gray: brightness, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 256))
    if let changedOption {
      canvas.translateBy(x: shift, y: 0)
      canvas.setFillColor(gray: brightness - 0.85, alpha: 1)
      canvas.fillEllipse(in: CGRect(x: 40, y: 90, width: 45, height: 60))
      canvas.fill(CGRect(x: 125, y: 90, width: 45, height: 60))
      canvas.fill(CGRect(x: 210, y: changedOption ? 60 : 90, width: 45, height: 60))
    }
    return canvas.makeImage()!
  }

  static func fixture(openedPage: Bool, searched: Bool = true, match: String = "exact") -> Data {
    let url = "https://example.org/algebra"
    let source: [String: Any] = ["url": url, "title": "Algebra exercise"]
    var output: [[String: Any]] = []
    if searched {
      output.append(["type": "web_search_call", "status": "completed", "kind": "deep_search",
                     "action": ["type": "search", "sources": [source]]])
    }
    if openedPage {
      output.append(["type": "web_search_call", "status": "completed", "kind": "deep_search",
                     "action": ["type": "open_page", "url": url], "page": source])
    }
    let answer: [String: Any] = [
      "question": "Solve x + 1 = 3.", "match": match, "matchURL": url,
      "matchNote": "The values match.", "steps": ["Subtract 1 from both sides."], "answer": match == "uncertain" ? "" : "2",
    ]
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    output.append(["type": "message", "content": [[
      "type": "output_text", "text": "```json\n\(text)\n```",
      "annotations": [source.merging(["type": "url_citation"]) { first, _ in first }],
    ]]])
    return try! JSONSerialization.data(withJSONObject: ["status": "completed", "output": output])
  }
}

private final class DeepSeekFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    precondition(request.url?.absoluteString == "https://api.deepseek.com/responses")
    precondition(request.httpMethod == "POST")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-fixture")
    let body = try! JSONSerialization.jsonObject(with: requestBody()) as! [String: Any]
    precondition(body["model"] as? String == "deepseek-flash")
    precondition(body["store"] as? Bool == false)
    let searching = body["tools"] != nil
    let reasoning = body["reasoning"] as? [String: String]
    if searching {
      precondition(body["text"] == nil, "DeepSeek web tools support plain text responses.")
      precondition((body["tools"] as? [[String: String]])?.first?["type"] == "deepseek_web_search")
    } else {
      precondition((body["text"] as? [String: [String: String]])?["format"]?["type"] == "json_object")
      precondition(reasoning?["effort"] == "high")
    }
    let input = body["input"] as! [[String: Any]]
    let parts = input[0]["content"] as! [[String: String]]
    precondition(parts.contains {
      $0["type"] == "input_image" && $0["image_url"]?.hasPrefix("data:image/png;base64,") == true && $0["detail"] == "high"
    })
    precondition(parts.contains { $0["text"]?.contains("x + 1 = 3") == true })
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: MirrorQuestionSearchTests.fixture(
      openedPage: searching, searched: searching, match: searching ? "exact" : "not_found"
    ))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private func requestBody() -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { return body }
      body.append(buffer, count: count)
    }
  }
}
