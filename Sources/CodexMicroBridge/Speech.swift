import Foundation

public enum CodexSpeechEvent: Equatable {
  case taskStarted
  case turnAborted
  case responseCompleted(String)
}

public struct PCM16StreamAssembler {
  private var trailingByte: UInt8?

  public init() {}

  public mutating func append(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }

    var aligned = Data()
    aligned.reserveCapacity(data.count + (trailingByte == nil ? 0 : 1))
    if let trailingByte {
      aligned.append(trailingByte)
      self.trailingByte = nil
    }
    aligned.append(data)
    if !aligned.count.isMultiple(of: MemoryLayout<Int16>.size) {
      trailingByte = aligned.removeLast()
    }
    return aligned
  }

  public var hasIncompleteSample: Bool { trailingByte != nil }
}

public struct CodexSpeechTurnTracker {
  private var activeTurnID: String?
  private var latestAssistantText: String?

  public init() {}

  public mutating func consume(_ line: String) -> CodexSpeechEvent? {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let recordType = object["type"] as? String,
      let payload = object["payload"] as? [String: Any]
    else { return nil }

    if recordType == "event_msg", let eventType = payload["type"] as? String {
      switch eventType {
      case "task_started":
        activeTurnID = payload["turn_id"] as? String
        latestAssistantText = nil
        return .taskStarted
      case "turn_aborted":
        activeTurnID = nil
        latestAssistantText = nil
        return .turnAborted
      case "task_complete":
        guard activeTurnID != nil else { return nil }
        let text = latestAssistantText
        activeTurnID = nil
        latestAssistantText = nil
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return nil
        }
        return .responseCompleted(text)
      default:
        return nil
      }
    }

    guard recordType == "response_item",
      payload["type"] as? String == "message",
      payload["role"] as? String == "assistant",
      activeTurnID != nil,
      let content = payload["content"] as? [[String: Any]]
    else { return nil }

    let text = content.compactMap { item -> String? in
      guard item["type"] as? String == "output_text" else { return nil }
      return item["text"] as? String
    }.joined(separator: "\n")
    if !text.isEmpty { latestAssistantText = text }
    return nil
  }
}

public enum SpeechTextSanitizer {
  public static func clean(_ input: String) -> String {
    var text = input
    text = replacing(#"(?s)```.*?```"#, in: text, with: " ")
    text = replacing(#"(?m)^(?: {4}|\t).*$"#, in: text, with: " ")
    text = replacing(#"!\[[^\]]*\]\([^)]*\)"#, in: text, with: " ")
    text = replacing(#"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
    text = replacing(#"https?://\S+"#, in: text, with: " ")
    text = replacing(#"(?<!\w)(?:~|/)(?:[\w. -]+/)+[\w. -]+"#, in: text, with: " a file path ")
    text = replacing(#"`([^`]+)`"#, in: text, with: "$1")
    text = replacing(#"(?m)^\s{0,3}(?:#{1,6}|>|[-*+]\s|\d+[.)]\s)\s*"#, in: text, with: "")
    text = replacing(#"[*_~]"#, in: text, with: "")
    text = replacing(#"\s+"#, in: text, with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return text
  }

  public static func chunks(_ text: String, maximumLength: Int = 3_900) -> [String] {
    guard maximumLength > 0 else { return [] }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var sentences: [String] = []
    trimmed.enumerateSubstrings(
      in: trimmed.startIndex..<trimmed.endIndex,
      options: [.bySentences, .substringNotRequired]
    ) { _, range, _, _ in
      sentences.append(String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if sentences.isEmpty { sentences = [trimmed] }

    var result: [String] = []
    var current = ""
    for sentence in sentences where !sentence.isEmpty {
      for segment in split(sentence, maximumLength: maximumLength) {
        let candidate = current.isEmpty ? segment : "\(current) \(segment)"
        if candidate.count <= maximumLength {
          current = candidate
        } else {
          if !current.isEmpty { result.append(current) }
          current = segment
        }
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private static func split(_ text: String, maximumLength: Int) -> [String] {
    guard text.count > maximumLength else { return [text] }
    var result: [String] = []
    var current = ""
    for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
      let candidate = current.isEmpty ? word : "\(current) \(word)"
      if candidate.count <= maximumLength {
        current = candidate
      } else {
        if !current.isEmpty { result.append(current) }
        if word.count <= maximumLength {
          current = word
        } else {
          var remainder = word[...]
          while remainder.count > maximumLength {
            let end = remainder.index(remainder.startIndex, offsetBy: maximumLength)
            result.append(String(remainder[..<end]))
            remainder = remainder[end...]
          }
          current = String(remainder)
        }
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private static func replacing(_ pattern: String, in input: String, with replacement: String)
    -> String
  {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return expression.stringByReplacingMatches(
      in: input,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }
}
