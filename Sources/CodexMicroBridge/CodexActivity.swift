import Foundation

public enum CodexConversationState: Int, Comparable {
  case idle = 0
  case working = 1
  case needsInput = 2

  public static func < (left: CodexConversationState, right: CodexConversationState) -> Bool {
    left.rawValue < right.rawValue
  }
}

public struct CodexActivityTracker {
  public private(set) var activeTurnIDs = Set<String>()
  public private(set) var pendingResponseCallIDs = Set<String>()

  public init() {}

  @discardableResult
  public mutating func consume(_ line: String) -> Bool {
    let previousState = state
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let recordType = object["type"] as? String,
      let payload = object["payload"] as? [String: Any]
    else { return false }

    if recordType == "event_msg", let eventType = payload["type"] as? String,
      let turnID = payload["turn_id"] as? String
    {
      switch eventType {
      case "task_started":
        activeTurnIDs.removeAll()
        activeTurnIDs.insert(turnID)
        pendingResponseCallIDs.removeAll()
      case "task_complete", "turn_aborted":
        activeTurnIDs.remove(turnID)
        pendingResponseCallIDs.removeAll()
      default:
        break
      }
    } else if recordType == "response_item", let itemType = payload["type"] as? String {
      if itemType == "function_call", payload["name"] as? String == "request_user_input",
        let callID = payload["call_id"] as? String
      {
        pendingResponseCallIDs.insert(callID)
      } else if itemType == "function_call_output", let callID = payload["call_id"] as? String {
        pendingResponseCallIDs.remove(callID)
      }
    }
    return previousState != state
  }

  public var state: CodexConversationState {
    if !pendingResponseCallIDs.isEmpty { return .needsInput }
    return activeTurnIDs.isEmpty ? .idle : .working
  }
}

public enum CodexFeedbackProjector {
  public static func project(
    _ feedback: [CodexFeedback],
    conversationState: CodexConversationState,
    agentCount: Int = 6
  ) -> [CodexFeedback] {
    guard agentCount > 0, conversationState != .idle || !feedback.isEmpty else { return [] }

    var states = Dictionary(
      uniqueKeysWithValues:
        feedback
        .filter { (0..<agentCount).contains($0.agent) }
        .map { ($0.agent, $0.state) }
    )
    for agent in 0..<agentCount where states[agent] == nil {
      states[agent] = .off
    }

    let projectedState: CodexAgentState?
    switch conversationState {
    case .idle:
      projectedState = nil
    case .working:
      let blockers: Set<CodexAgentState> = [.thinking, .needsInput, .error]
      projectedState = states.values.contains(where: blockers.contains) ? nil : .thinking
    case .needsInput:
      let blockers: Set<CodexAgentState> = [.needsInput, .error]
      projectedState = states.values.contains(where: blockers.contains) ? nil : .needsInput
    }

    if let projectedState {
      let inactiveAgent = (0..<agentCount).first {
        states[$0] == .idle || states[$0] == .off
      }
      let unreadAgent = (0..<agentCount).first { states[$0] == .unread }
      let workingAgent = (0..<agentCount).first { states[$0] == .thinking }
      let overrideAgent = inactiveAgent ?? unreadAgent ?? workingAgent ?? 0
      states[overrideAgent] = projectedState
    }

    return (0..<agentCount).compactMap { agent in
      states[agent].map { CodexFeedback(agent: agent, state: $0) }
    }
  }

  public static func aggregate(_ feedback: [CodexFeedback]) -> CodexAgentState {
    let states = Set(feedback.map(\.state))
    for state in [
      CodexAgentState.error,
      .needsInput,
      .thinking,
      .unread,
      .idle,
    ] where states.contains(state) {
      return state
    }
    return .off
  }
}

public final class CodexActivityMonitor {
  private struct TrackedSession {
    var offset: UInt64 = 0
    var pending = Data()
    var tracker = CodexActivityTracker()
    var speechTracker = CodexSpeechTurnTracker()
    var hasCaughtUp = false
  }

  private let sessionsRoot: URL
  private let pollInterval: TimeInterval
  private let callbackQueue: DispatchQueue
  private let onChange: (CodexConversationState) -> Void
  private let onSpeechEvent: ((CodexSpeechEvent) -> Void)?
  private let queue = DispatchQueue(label: "Codex activity monitor")
  private var timer: DispatchSourceTimer?
  private var sessions: [URL: TrackedSession] = [:]
  private var lastState: CodexConversationState?
  private var lastDiscovery = Date.distantPast

  public init(
    sessionsRoot: URL = CodexActivityMonitor.defaultSessionsRoot,
    pollInterval: TimeInterval = 0.25,
    callbackQueue: DispatchQueue = .main,
    onSpeechEvent: ((CodexSpeechEvent) -> Void)? = nil,
    onChange: @escaping (CodexConversationState) -> Void
  ) {
    self.sessionsRoot = sessionsRoot
    self.pollInterval = pollInterval
    self.callbackQueue = callbackQueue
    self.onSpeechEvent = onSpeechEvent
    self.onChange = onChange
  }

  deinit { stop() }

  public func start() {
    queue.async { [weak self] in
      guard let self, self.timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: self.pollInterval)
      timer.setEventHandler { [weak self] in self?.poll() }
      self.timer = timer
      timer.resume()
    }
  }

  public func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
    }
  }

  public static var defaultSessionsRoot: URL {
    let environment = ProcessInfo.processInfo.environment
    let codexHome =
      environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    return codexHome.appendingPathComponent("sessions", isDirectory: true)
  }

  private func poll() {
    let now = Date()
    if now.timeIntervalSince(lastDiscovery) >= 1 {
      discoverSessions(now: now)
      lastDiscovery = now
    }
    for url in sessions.keys {
      readChanges(at: url)
    }

    let state = sessions.values.map(\.tracker.state).max() ?? .idle
    guard state != lastState else { return }
    lastState = state
    callbackQueue.async { [onChange] in onChange(state) }
  }

  private func discoverSessions(now: Date) {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy/MM/dd"

    let directories = (0...1).compactMap { daysAgo -> URL? in
      guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else {
        return nil
      }
      return sessionsRoot.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }
    let recentCutoff = now.addingTimeInterval(-12 * 60 * 60)
    var discovered = Set<URL>()

    for directory in directories {
      guard
        let urls = try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.contentModificationDateKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }
      for url in urls where url.pathExtension == "jsonl" {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
          let modified = values.contentModificationDate,
          modified >= recentCutoff
        else { continue }
        discovered.insert(url)
        if sessions[url] == nil {
          sessions[url] = TrackedSession()
        }
      }
    }

    for (url, session) in sessions
    where !discovered.contains(url) && session.tracker.state == .idle {
      sessions.removeValue(forKey: url)
    }
  }

  private func readChanges(at url: URL) {
    guard var session = sessions[url],
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else { return }
    let fileSize = size.uint64Value
    if fileSize < session.offset {
      session = TrackedSession()
    }
    guard fileSize > session.offset else { return }

    do {
      let handle = try FileHandle(forReadingFrom: url)
      try handle.seek(toOffset: session.offset)
      let data = try handle.readToEnd() ?? Data()
      try handle.close()
      session.offset += UInt64(data.count)
      session.pending.append(data)

      var speechEvents: [CodexSpeechEvent] = []
      while let newline = session.pending.firstIndex(of: 0x0A) {
        let lineData = session.pending[..<newline]
        session.pending.removeSubrange(...newline)
        if let line = String(data: lineData, encoding: .utf8) {
          session.tracker.consume(line)
          if let event = session.speechTracker.consume(line), session.hasCaughtUp {
            speechEvents.append(event)
          }
        }
      }
      session.hasCaughtUp = true
      sessions[url] = session
      if let onSpeechEvent {
        for event in speechEvents {
          callbackQueue.async { onSpeechEvent(event) }
        }
      }
    } catch {
      return
    }
  }
}
