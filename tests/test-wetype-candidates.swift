import Foundation
@main struct CandidateTests {
  static func main() {
    precondition(WeTypeCandidates.parse("1 你好 2 你号 3 拟好") == ["你好", "你号", "拟好"])
    precondition(WeTypeCandidates.parse("1 😀 2 中文") == ["😀", "中文"])
    precondition(WeTypeCandidates.parse("ordinary 123 text").isEmpty)
    precondition(WeTypeCandidates.parse("2 错误 3 候选").isEmpty)
    precondition(WeTypeCandidates.parse("1 唯一").isEmpty)
    print("WETYPE_CANDIDATES_PASS: exact ordered candidates, Unicode and invalid labels")
  }
}
