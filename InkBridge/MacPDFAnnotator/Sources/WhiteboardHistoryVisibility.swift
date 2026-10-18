func visibleWhiteboardHistoryOperationIndexes(
  in operationMessages: [[RelayMessage]],
  historyCursor: Int
) -> [Int] {
  let cursor = min(operationMessages.count, max(0, historyCursor))
  var visibleIndexes = Array(0..<cursor)

  for index in cursor..<operationMessages.count {
    let messages = operationMessages[index]
    let isPendingStroke = messages.contains { $0.type.hasPrefix("stroke:") }
      && !messages.contains { $0.type == "stroke:end" }
    if isPendingStroke { visibleIndexes.append(index) }
  }

  return visibleIndexes
}
