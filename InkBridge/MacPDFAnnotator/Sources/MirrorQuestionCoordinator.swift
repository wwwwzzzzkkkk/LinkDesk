import CoreGraphics
import Foundation

@MainActor
final class MirrorQuestionCoordinator {
  typealias Solve = @MainActor @Sendable (MirrorQuestionInput, MirrorSolveProvider) async throws -> MirrorSolvedQuestion
  typealias Lookup = @MainActor @Sendable (MirrorQuestionInput, MirrorQuestionSearch.Operation) async throws -> MirrorQuestionReport

  private struct Entry {
    let id: UUID
    let frame: MirrorQuestionFrame
    let task: Task<MirrorSolvedQuestion, Error>
  }

  static var supportFolder: URL {
    URL.applicationSupportDirectory.appending(path: "LinkDesk", directoryHint: .isDirectory)
  }

  private let bank: URL?
  private let reviewDelay: Duration
  private lazy var savedFrames: [UUID: MirrorQuestionFrame] = loadFrames()
  private let solveQuestion: Solve
  private let lookUp: Lookup
  private var entries: [Entry] = []
  private var finished: [UUID: UUID] = [:]
  private var sourceRequests: [UUID: Task<MirrorQuestionReport, Error>] = [:]

  init(bank: URL? = nil, reviewDelay: Duration = .seconds(20), solve: @escaping Solve = MirrorQuestionCoordinator.modelSolve,
       lookup: @escaping Lookup = MirrorQuestionCoordinator.modelLookup) {
    self.bank = bank
    self.reviewDelay = reviewDelay
    solveQuestion = solve
    lookUp = lookup
  }

  func solve(image: CGImage, frame: MirrorQuestionFrame?, transcript: String?, provider: MirrorSolveProvider,
             onReview: @escaping @MainActor () -> Void) async throws -> MirrorSolvedQuestion {
    let signature = frame ?? MirrorQuestionFrame(image: image)
    if let signature,
       let index = entries.lastIndex(where: { $0.frame.matches(signature) }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      var solution = try await entry.task.value
      if let source = sourceRequests[solution.id], let report = try? await source.value {
        solution.review = report
        if let published = report.publishedAnswer { solution.result = published }
      }
      return solution
    }

    if let signature, let bank {
      for (id, frame) in savedFrames where frame.matches(signature) {
        let file = bank.appending(path: "\(id.uuidString).answer")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(MirrorSolvedQuestion.self, from: data) {
          return saved
        }
      }
    }

    let id = UUID()
    let task = Task { @MainActor in
      do {
        let input = try await MirrorQuestionInput.prepare(image: image, transcript: transcript)
        let solved = try await solveWithDeadline(input, provider: provider, onReview: onReview)
        if let signature {
          save(solved, frame: signature)
          finished[id] = solved.id
          prune()
        }
        return solved
      } catch {
        entries.removeAll { $0.id == id }
        throw error
      }
    }
    if let signature { entries.append(Entry(id: id, frame: signature, task: task)) }
    return try await task.value
  }

  private enum Outcome: Sendable {
    case deadline
    case stopped
    case solved(Result<MirrorSolvedQuestion, Error>)
    case reviewed(Result<MirrorQuestionReport, Error>)
  }

  private func solveWithDeadline(_ input: MirrorQuestionInput, provider: MirrorSolveProvider,
                                 onReview: @escaping @MainActor () -> Void) async throws -> MirrorSolvedQuestion {
    try await withThrowingTaskGroup(of: Outcome.self) { group in
      group.addTask { [solveQuestion] in
        do { return .solved(.success(try await solveQuestion(input, provider))) }
        catch { return .solved(.failure(error)) }
      }
      group.addTask { [reviewDelay] in
        do { try await Task.sleep(for: reviewDelay); return .deadline }
        catch { return .stopped }
      }
      defer { group.cancelAll() }

      var solution: MirrorSolvedQuestion?
      var review: Result<MirrorQuestionReport, Error>?
      var startedReview = false
      while let outcome = try await group.next() {
        switch outcome {
        case .deadline:
          break
        case .stopped:
          continue
        case .solved(.success(let value)):
          if value.result.match != .uncertain { return value }
          solution = value
        case .solved(.failure(let error)):
          if !startedReview { throw error }
          let unknown = MirrorQuestionResult(question: "", match: .uncertain, matchURL: nil,
                                            matchNote: error.localizedDescription, steps: [], answer: "")
          solution = MirrorSolvedQuestion(input: input, result: unknown)
        case .reviewed(let result):
          review = result
          if case .success(let report) = result, let published = report.publishedAnswer {
            return MirrorSolvedQuestion(input: input, result: published, review: report)
          }
        }

        if var solution, let review {
          switch review {
          case .success(let report): solution.review = report
          case .failure(let error): solution.reviewError = error.localizedDescription
          }
          return solution
        }

        if !startedReview {
          startedReview = true
          onReview()
          group.addTask { [lookUp] in
            do { return .reviewed(.success(try await lookUp(input, .verify))) }
            catch { return .reviewed(.failure(error)) }
          }
        }
      }
      throw MirrorQuestionError.invalidResponse
    }
  }

  func findSource(for question: MirrorSolvedQuestion) async throws -> MirrorQuestionReport {
    if let review = question.review, review.original == nil || review.publishedAnswer != nil { return review }
    if let task = sourceRequests[question.id] { return try await task.value }
    let task = Task { @MainActor in
      do {
        let report = try await lookUp(question.input, .findSource)
        if let frame = savedFrames[question.id] {
          var updated = question
          updated.review = report
          if let published = report.publishedAnswer { updated.result = published }
          save(updated, frame: frame)
        }
        return report
      }
      catch {
        sourceRequests[question.id] = nil
        throw error
      }
    }
    sourceRequests[question.id] = task
    return try await task.value
  }

  private func loadFrames() -> [UUID: MirrorQuestionFrame] {
    guard let bank, let files = try? FileManager.default.contentsOfDirectory(at: bank, includingPropertiesForKeys: nil)
    else { return [:] }
    var frames: [UUID: MirrorQuestionFrame] = [:]
    for file in files where file.pathExtension == "frame" {
      if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
         let data = try? Data(contentsOf: file),
         let frame = try? JSONDecoder().decode(MirrorQuestionFrame.self, from: data) {
        frames[id] = frame
      }
    }
    return frames
  }

  private func save(_ solution: MirrorSolvedQuestion, frame: MirrorQuestionFrame) {
    guard let bank, solution.result.match != .uncertain, solution.result.match != .unreadable,
          !solution.result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do {
      try FileManager.default.createDirectory(at: bank, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
      let name = solution.id.uuidString
      let encoder = JSONEncoder()
      try encoder.encode(solution).write(to: bank.appending(path: name + ".answer"), options: .atomic)
      try encoder.encode(frame).write(to: bank.appending(path: name + ".frame"), options: .atomic)
      savedFrames[solution.id] = frame
    } catch {
      NSLog("LinkDesk question library could not save a record.")
    }
  }

  private func prune() {
    while finished.count > 24, let index = entries.firstIndex(where: { finished[$0.id] != nil }) {
      if let questionID = finished.removeValue(forKey: entries.remove(at: index).id) {
        sourceRequests[questionID] = nil
      }
    }
  }

  private static func modelSolve(_ input: MirrorQuestionInput, provider: MirrorSolveProvider) async throws -> MirrorSolvedQuestion {
    let key = try provider == .deepSeek ? MirrorQuestionKeychain.load() : nil
    return try await provider.solve(input, deepSeekKey: key)
  }

  private static func modelLookup(_ input: MirrorQuestionInput, operation: MirrorQuestionSearch.Operation) async throws -> MirrorQuestionReport {
    guard let key = try MirrorQuestionKeychain.load() else { throw MirrorQuestionError.authentication }
    return try await MirrorQuestionSearch.request(operation, input: input, key: key)
  }
}
