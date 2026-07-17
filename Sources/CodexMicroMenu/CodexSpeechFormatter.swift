import Darwin
import Foundation

enum SpeechLength: String, CaseIterable, Identifiable {
  case brief
  case standard
  case detailed

  var id: String { rawValue }

  var label: String {
    switch self {
    case .brief: return "Brief (20–30 sec)"
    case .standard: return "Standard (45–60 sec)"
    case .detailed: return "Detailed (up to 2 min)"
    }
  }

  var prompt: String {
    switch self {
    case .brief: return "Aim for roughly 20 to 30 seconds of speech."
    case .standard: return "Aim for roughly 45 to 60 seconds of speech."
    case .detailed: return "Use up to roughly two minutes when the information warrants it."
    }
  }
}

enum CodexSpeechFormatterError: LocalizedError {
  case codexUnavailable
  case serverExited
  case serverError(String)
  case missingThread
  case missingResponse
  case invalidStructuredOutput
  case timedOut
  case chatGPTSubscriptionRequired

  var errorDescription: String? {
    switch self {
    case .codexUnavailable:
      return "The Codex app-server executable is unavailable."
    case .serverExited:
      return "The Codex speech formatter stopped unexpectedly."
    case .serverError(let message):
      return "Codex speech preparation failed: \(message)"
    case .missingThread:
      return "Codex did not create the speech-preparation thread."
    case .missingResponse:
      return "Codex returned no spoken response."
    case .invalidStructuredOutput:
      return "Codex returned an invalid spoken-response format."
    case .timedOut:
      return "Codex speech preparation timed out."
    case .chatGPTSubscriptionRequired:
      return
        "Codex speech preparation requires a ChatGPT subscription login; API-key Codex auth is not used."
    }
  }
}

actor CodexSpeechFormatter {
  private let model = "gpt-5.3-codex-spark"
  private var session: CodexAppServerSession?
  private var nextRequestID = 0

  func format(_ source: String, length: SpeechLength) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { try await self.formatUsingSession(source, length: length) }
      group.addTask {
        try await Task.sleep(nanoseconds: 90_000_000_000)
        throw CodexSpeechFormatterError.timedOut
      }
      guard let result = try await group.next() else {
        throw CodexSpeechFormatterError.serverExited
      }
      group.cancelAll()
      return result
    }
  }

  func stop() {
    session?.stop()
    session = nil
  }

  private func formatUsingSession(_ source: String, length: SpeechLength) async throws -> String {
    let activeSession = try await readySession()
    return try await withTaskCancellationHandler {
      do {
        return try await performFormat(
          source, length: length, session: activeSession)
      } catch {
        reset(activeSession)
        throw error
      }
    } onCancel: {
      activeSession.stop()
    }
  }

  private func readySession() async throws -> CodexAppServerSession {
    if let session, session.isRunning { return session }
    session?.stop()

    let newSession = try CodexAppServerSession(executable: resolveCodexExecutable())
    session = newSession
    do {
      let initializeID = requestID()
      try newSession.send([
        "method": "initialize",
        "id": initializeID,
        "params": [
          "capabilities": ["experimentalApi": true],
          "clientInfo": [
            "name": "codex_micro_bridge",
            "title": "Codex Micro Bridge",
            "version": "0.4.0",
          ],
        ],
      ])
      _ = try await response(id: initializeID, from: newSession)
      try newSession.send(["method": "initialized", "params": [:]])

      let accountID = requestID()
      try newSession.send([
        "method": "account/read",
        "id": accountID,
        "params": ["refreshToken": false],
      ])
      let accountMessage = try await response(id: accountID, from: newSession)
      guard let result = accountMessage["result"] as? [String: Any],
        let account = result["account"] as? [String: Any],
        account["type"] as? String == "chatgpt"
      else { throw CodexSpeechFormatterError.chatGPTSubscriptionRequired }
      return newSession
    } catch {
      reset(newSession)
      throw error
    }
  }

  private func performFormat(
    _ source: String,
    length: SpeechLength,
    session: CodexAppServerSession
  ) async throws -> String {
    let threadID = requestID()
    try session.send(threadStartRequest(id: threadID, length: length))
    let threadMessage = try await response(id: threadID, from: session)
    guard let result = threadMessage["result"] as? [String: Any],
      let thread = result["thread"] as? [String: Any],
      let codexThreadID = thread["id"] as? String
    else { throw CodexSpeechFormatterError.missingThread }

    let turnID = requestID()
    try session.send(turnStartRequest(id: turnID, threadID: codexThreadID, source: source))
    var finalAgentText: String?
    while let message = try await session.nextMessage() {
      try Task.checkCancellation()
      try throwServerError(from: message)
      guard let method = message["method"] as? String,
        let params = message["params"] as? [String: Any]
      else { continue }

      if method == "item/completed", let item = params["item"] as? [String: Any],
        item["type"] as? String == "agentMessage",
        item["phase"] as? String != "commentary",
        let text = item["text"] as? String
      {
        finalAgentText = text
      } else if method == "turn/completed" {
        if let turn = params["turn"] as? [String: Any],
          turn["status"] as? String != "completed"
        {
          let error = turn["error"] as? [String: Any]
          throw CodexSpeechFormatterError.serverError(
            error?["message"] as? String ?? "the formatter turn did not complete")
        }
        guard let finalAgentText else { throw CodexSpeechFormatterError.missingResponse }
        return try parseStructuredOutput(finalAgentText)
      }
    }
    throw CodexSpeechFormatterError.serverExited
  }

  private func response(
    id: Int, from session: CodexAppServerSession
  ) async throws -> [String: Any] {
    while let message = try await session.nextMessage() {
      try Task.checkCancellation()
      try throwServerError(from: message)
      if (message["id"] as? NSNumber)?.intValue == id { return message }
    }
    throw CodexSpeechFormatterError.serverExited
  }

  private func throwServerError(from message: [String: Any]) throws {
    if let error = message["error"] as? [String: Any] {
      throw CodexSpeechFormatterError.serverError(
        error["message"] as? String ?? "unknown error")
    }
  }

  private func requestID() -> Int {
    defer { nextRequestID += 1 }
    return nextRequestID
  }

  private func reset(_ activeSession: CodexAppServerSession) {
    activeSession.stop()
    if session === activeSession { session = nil }
  }

  private func threadStartRequest(id: Int, length: SpeechLength) -> [String: Any] {
    [
      "method": "thread/start",
      "id": id,
      "params": [
        "model": model,
        "ephemeral": true,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "cwd": FileManager.default.temporaryDirectory.path,
        "config": [
          "web_search": "disabled",
          "project_doc_max_bytes": 0,
        ],
        "baseInstructions": """
        You are the speech editor for Codex Micro Bridge. Rewrite supplied final answers into a natural spoken reply to the same user. Preserve outcomes, important decisions, warnings, validation results, blockers, and required next actions. Remove Markdown structure, code blocks, raw URLs, hashes, and file paths unless essential. Do not invent, reconsider, or add recommendations. Keep the source language and conversational tone. Do not announce that this is a summary. Never call tools. Return only the requested structured output. \(length.prompt)
        """,
      ],
    ]
  }

  private func turnStartRequest(id: Int, threadID: String, source: String) -> [String: Any] {
    [
      "method": "turn/start",
      "id": id,
      "params": [
        "threadId": threadID,
        "model": model,
        "effort": "high",
        "input": [
          [
            "type": "text",
            "text": "Transform the supplied source response into spokenText.",
          ]
        ],
        "additionalContext": [
          "source_final_response": [
            "kind": "untrusted",
            "value": source,
          ]
        ],
        "outputSchema": [
          "type": "object",
          "additionalProperties": false,
          "required": ["spokenText"],
          "properties": [
            "spokenText": [
              "type": "string",
              "minLength": 1,
            ]
          ],
        ],
      ],
    ]
  }

  private func parseStructuredOutput(_ output: String) throws -> String {
    guard let data = output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let spokenText = object["spokenText"] as? String
    else { throw CodexSpeechFormatterError.invalidStructuredOutput }
    let trimmed = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CodexSpeechFormatterError.missingResponse }
    return trimmed
  }

  private func resolveCodexExecutable() throws -> URL {
    let candidates = [
      ProcessInfo.processInfo.environment["CODEX_BINARY"],
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
    ].compactMap { $0 }
    if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return URL(fileURLWithPath: path)
    }
    throw CodexSpeechFormatterError.codexUnavailable
  }
}

private final class CodexAppServerSession: @unchecked Sendable {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let error: FileHandle
  private let reader: BlockingLineReader
  private let lock = NSLock()
  private var stopped = false

  init(executable: URL) throws {
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = executable
    process.arguments = ["app-server", "--stdio"]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "OPENAI_API_KEY")
    environment.removeValue(forKey: "CODEX_API_KEY")
    process.environment = environment
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }

    self.process = process
    input = inputPipe.fileHandleForWriting
    output = outputPipe.fileHandleForReading
    error = errorPipe.fileHandleForReading
    reader = BlockingLineReader(handle: outputPipe.fileHandleForReading)
    try process.run()
  }

  deinit { stop() }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !stopped && process.isRunning
  }

  func send(_ message: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    try input.write(contentsOf: data)
  }

  func nextMessage() async throws -> [String: Any]? {
    guard
      let line = try await Task.detached(
        priority: .userInitiated,
        operation: {
          try self.reader.nextLine()
        }
      ).value
    else { return nil }
    guard let data = line.data(using: .utf8),
      let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return try await nextMessage() }
    return message
  }

  func stop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    lock.unlock()

    error.readabilityHandler = nil
    try? input.close()
    try? output.close()
    try? error.close()
    if process.isRunning { process.terminate() }
  }
}

private final class BlockingLineReader: @unchecked Sendable {
  private let handle: FileHandle
  private var buffer = Data()

  init(handle: FileHandle) {
    self.handle = handle
  }

  func nextLine() throws -> String? {
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        return String(data: line, encoding: .utf8)
      }
      let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard count > 0 else {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(data: buffer, encoding: .utf8)
      }
      buffer.append(contentsOf: bytes.prefix(count))
    }
  }
}
