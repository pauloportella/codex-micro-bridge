import AppKit
import CodexMicroBridge
import Foundation
import SwiftUI

private enum BridgeLifecycle: String {
  case stopped = "Stopped"
  case starting = "Starting"
  case running = "Running"
  case stopping = "Stopping"
  case failed = "Failed"
}

private enum DeviceState: String {
  case unavailable = "Unavailable"
  case waiting = "Waiting"
  case scanning = "Scanning"
  case connecting = "Connecting"
  case ready = "Ready"
  case disconnected = "Disconnected"
  case error = "Error"
}

private enum CodexState: String {
  case offline = "Offline"
  case waiting = "Waiting"
  case idle = "Idle"
  case thinking = "Thinking"
  case needsYou = "Needs You"
  case error = "Error"
  case listening = "Listening"
  case processing = "Processing"
  case heard = "Heard"
  case done = "Done"
  case preparing = "Preparing"
  case speaking = "Speaking"

  var symbol: String {
    switch self {
    case .offline, .waiting: return "circle.dotted"
    case .idle: return "circle.fill"
    case .thinking: return "ellipsis.circle.fill"
    case .needsYou: return "exclamationmark.circle.fill"
    case .error: return "xmark.octagon.fill"
    case .listening: return "waveform.circle.fill"
    case .processing: return "text.bubble.fill"
    case .heard, .done: return "checkmark.circle.fill"
    case .preparing: return "text.bubble"
    case .speaking: return "speaker.wave.2.fill"
    }
  }

  var color: Color {
    switch self {
    case .offline, .waiting: return .secondary
    case .idle: return .primary
    case .thinking: return .blue
    case .needsYou: return .orange
    case .error: return .red
    case .listening: return .green
    case .processing, .heard: return .primary
    case .done: return .green
    case .preparing, .speaking: return .purple
    }
  }
}

private enum SpeechPhase {
  case idle
  case preparing
  case speaking
}

@MainActor
private final class BridgeController: ObservableObject {
  private enum DefaultsKey {
    static let automaticSpeech = "speech.automatic"
    static let voice = "speech.voice"
    static let length = "speech.length"
    static let outputUID = "speech.outputUID"
    static let outputName = "speech.outputName"
  }

  static let voices = [
    "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer",
    "verse", "marin", "cedar",
  ]

  @Published private(set) var lifecycle = BridgeLifecycle.stopped
  @Published private(set) var codexState = CodexState.offline
  @Published private(set) var m5State = DeviceState.unavailable
  @Published private(set) var rideState = DeviceState.unavailable
  @Published private(set) var leonardoState = DeviceState.unavailable
  @Published private(set) var logs: [String] = []
  @Published private(set) var hasAPIKey = false
  @Published private(set) var lastResponse: String?
  @Published private(set) var speechStatus = "Add an OpenAI API key to enable speech."
  @Published private(set) var audioOutputs: [AudioOutputDevice] = [.systemDefault]
  @Published var showingLogs = false
  @Published var apiKeyDraft = ""
  @Published var automaticSpeech: Bool {
    didSet { UserDefaults.standard.set(automaticSpeech, forKey: DefaultsKey.automaticSpeech) }
  }
  @Published var selectedVoice: String {
    didSet { UserDefaults.standard.set(selectedVoice, forKey: DefaultsKey.voice) }
  }
  @Published var selectedLength: SpeechLength {
    didSet { UserDefaults.standard.set(selectedLength.rawValue, forKey: DefaultsKey.length) }
  }
  @Published var selectedOutputUID: String {
    didSet {
      UserDefaults.standard.set(selectedOutputUID, forKey: DefaultsKey.outputUID)
      let name = audioOutputs.first(where: { $0.id == selectedOutputUID })?.name ?? ""
      UserDefaults.standard.set(name, forKey: DefaultsKey.outputName)
    }
  }

  private let keyStore = APIKeyStore()
  private let speechClient = OpenAISpeechClient()
  private let speechFormatter = CodexSpeechFormatter()
  private let audioCatalog = AudioOutputCatalog()
  private let audioPlayer = PCMOutputPlayer()
  private var process: Process?
  private var logPipe: Pipe?
  private var inputPipe: Pipe?
  private var pendingLogData = Data()
  private var hasAutoStarted = false
  private var terminationObserver: NSObjectProtocol?
  private var threadState = CodexState.offline
  private var voiceState: CodexState?
  @Published private var speechPhase = SpeechPhase.idle
  private var speechTask: Task<Void, Never>?
  private var speechGeneration = 0
  private var pendingResponse: String?

  init() {
    let defaults = UserDefaults.standard
    automaticSpeech = defaults.object(forKey: DefaultsKey.automaticSpeech) as? Bool ?? true
    selectedVoice = defaults.string(forKey: DefaultsKey.voice) ?? "marin"
    selectedLength =
      SpeechLength(rawValue: defaults.string(forKey: DefaultsKey.length) ?? "")
      ?? .standard
    selectedOutputUID = defaults.string(forKey: DefaultsKey.outputUID) ?? ""
    do {
      hasAPIKey = try keyStore.load() != nil
      speechStatus = hasAPIKey ? "Ready" : "Add an OpenAI API key to enable speech."
    } catch {
      speechStatus = error.localizedDescription
    }
    refreshAudioOutputs()
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.stopSpeech(status: nil)
        self?.process?.terminate()
        await self?.speechFormatter.stop()
      }
    }
  }

  deinit {
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
  }

  var isRunning: Bool {
    lifecycle == .starting || lifecycle == .running || lifecycle == .stopping
  }

  var canSpeakLastResponse: Bool { lastResponse != nil && hasAPIKey }
  var canStopSpeech: Bool { speechPhase != .idle }

  func startAutomatically() {
    guard !hasAutoStarted else { return }
    hasAutoStarted = true
    start()
  }

  func start() {
    guard process == nil else { return }
    do {
      let helperURL = try resolveHelperURL()
      let configURL = try resolveConfigURL()
      let launchedProcess = Process()
      let output = Pipe()
      let input = Pipe()

      lifecycle = .starting
      threadState = .waiting
      voiceState = nil
      refreshCodexState()
      m5State = .scanning
      rideState = .scanning
      leonardoState = .waiting
      appendLog("Starting bridge")

      launchedProcess.executableURL = helperURL
      launchedProcess.arguments = ["run", configURL.path]
      launchedProcess.currentDirectoryURL = projectRoot(for: configURL)
      launchedProcess.standardInput = input
      launchedProcess.standardOutput = output
      launchedProcess.standardError = output
      var environment = ProcessInfo.processInfo.environment
      environment["CODEX_MICRO_TTS_EVENTS"] = "1"
      launchedProcess.environment = environment

      output.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        Task { @MainActor [weak self] in self?.consume(data) }
      }
      launchedProcess.terminationHandler = { [weak self] completedProcess in
        Task { @MainActor [weak self] in
          self?.processEnded(status: completedProcess.terminationStatus)
        }
      }

      try launchedProcess.run()
      process = launchedProcess
      logPipe = output
      inputPipe = input
    } catch {
      lifecycle = .failed
      codexState = .offline
      leonardoState = .error
      let message = "Start failed: \(error.localizedDescription)"
      appendLog(message)
      NSLog("Codex Micro Bridge: %@", message)
    }
  }

  func stop() {
    guard let process else { return }
    stopSpeech(status: "Stopped")
    lifecycle = .stopping
    appendLog("Stopping bridge")
    process.terminate()
  }

  func quit() {
    stopSpeech(status: nil)
    process?.terminate()
    NSApplication.shared.terminate(nil)
  }

  func saveAPIKey() {
    let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      speechStatus = "Enter an OpenAI API key first."
      return
    }
    do {
      try keyStore.save(key)
      apiKeyDraft = ""
      hasAPIKey = true
      speechStatus = "API key saved securely in Keychain."
    } catch {
      speechStatus = error.localizedDescription
    }
  }

  func removeAPIKey() {
    stopSpeech(status: nil)
    do {
      try keyStore.delete()
      hasAPIKey = false
      apiKeyDraft = ""
      speechStatus = "API key removed."
    } catch {
      speechStatus = error.localizedDescription
    }
  }

  func refreshAudioOutputs() {
    do {
      audioOutputs = try audioCatalog.devices()
      if !selectedOutputUID.isEmpty,
        !audioOutputs.contains(where: { $0.id == selectedOutputUID })
      {
        let savedName =
          UserDefaults.standard.string(forKey: DefaultsKey.outputName)
          ?? selectedOutputUID
        speechStatus = "Selected output unavailable: \(savedName)."
      }
    } catch {
      audioOutputs = [.systemDefault]
      speechStatus = error.localizedDescription
    }
  }

  func speakLastResponse() {
    guard let lastResponse else { return }
    requestSpeech(lastResponse)
  }

  func testVoice() {
    stopSpeech(status: nil)
    startSynthesis(
      source: "This is an AI-generated voice from Codex Micro Bridge.",
      formatWithCodex: false
    )
  }

  func stopSpeaking() {
    stopSpeech(status: "Stopped")
  }

  private func requestSpeech(_ text: String) {
    guard hasAPIKey else {
      speechStatus = "Add an OpenAI API key to enable speech."
      return
    }
    if speechPhase == .speaking {
      pendingResponse = text
      speechStatus = "Latest response queued"
      return
    }
    if speechPhase == .preparing {
      speechTask?.cancel()
      audioPlayer.stop()
    }
    pendingResponse = nil
    startSynthesis(source: text, formatWithCodex: true)
  }

  private func startSynthesis(source: String, formatWithCodex: Bool) {
    guard let apiKey = try? keyStore.load(), !apiKey.isEmpty else {
      hasAPIKey = false
      speechStatus = "Add an OpenAI API key to enable speech."
      return
    }
    speechGeneration += 1
    let generation = speechGeneration
    let voice = selectedVoice
    let length = selectedLength
    let outputUID = selectedOutputUID
    let outputName =
      audioOutputs.first(where: { $0.id == outputUID })?.name
      ?? UserDefaults.standard.string(forKey: DefaultsKey.outputName)
      ?? outputUID
    do {
      _ = try audioCatalog.resolveDeviceID(uid: outputUID, knownName: outputName)
    } catch {
      speechStatus = error.localizedDescription
      return
    }

    speechPhase = .preparing
    speechStatus = formatWithCodex ? "Preparing spoken response…" : "Preparing voice test…"
    sendBridgeControl("SPEECH PREPARING")
    refreshCodexState()
    let preparationStarted = Date()
    speechTask = Task { [weak self] in
      guard let self else { return }
      do {
        let spokenText: String
        var formatterDuration = 0.0
        if formatWithCodex {
          spokenText = try await speechFormatter.format(source, length: length)
          formatterDuration = Date().timeIntervalSince(preparationStarted)
          appendLog(String(format: "Speech formatted in %.1fs", formatterDuration))
        } else {
          spokenText = source
        }
        try Task.checkCancellation()
        let cleanText = SpeechTextSanitizer.clean(spokenText)
        let chunks = SpeechTextSanitizer.chunks(cleanText)
        guard !chunks.isEmpty else { throw CodexSpeechFormatterError.missingResponse }

        let audio = speechClient.synthesizePCM(chunks: chunks, apiKey: apiKey, voice: voice)
        try await audioPlayer.play(audio, outputUID: outputUID, outputName: outputName) {
          guard generation == self.speechGeneration else { return }
          self.speechPhase = .speaking
          self.speechStatus =
            "Speaking on \(outputName.isEmpty ? "System Default" : outputName)"
          self.sendBridgeControl("SPEECH SPEAKING")
          self.refreshCodexState()
          let totalDuration = Date().timeIntervalSince(preparationStarted)
          if formatWithCodex {
            self.appendLog(
              String(
                format: "Speech started in %.1fs (format %.1fs, audio %.1fs)",
                totalDuration, formatterDuration, max(0, totalDuration - formatterDuration)))
          } else {
            self.appendLog(String(format: "Voice test started in %.1fs", totalDuration))
          }
        }
        try Task.checkCancellation()
        completeSpeech(generation: generation)
      } catch is CancellationError {
        guard generation == speechGeneration else { return }
        finishSpeech(status: "Stopped")
      } catch {
        guard generation == speechGeneration else { return }
        finishSpeech(status: error.localizedDescription)
      }
    }
  }

  private func completeSpeech(generation: Int) {
    guard generation == speechGeneration else { return }
    finishSpeech(status: "Finished")
    if let pendingResponse {
      self.pendingResponse = nil
      startSynthesis(source: pendingResponse, formatWithCodex: true)
    }
  }

  private func finishSpeech(status: String) {
    speechTask = nil
    speechPhase = .idle
    speechStatus = status
    sendBridgeControl("SPEECH IDLE")
    refreshCodexState()
  }

  private func stopSpeech(status: String?) {
    speechGeneration += 1
    speechTask?.cancel()
    speechTask = nil
    audioPlayer.stop()
    pendingResponse = nil
    speechPhase = .idle
    sendBridgeControl("SPEECH IDLE")
    if let status { speechStatus = status }
    refreshCodexState()
  }

  private func sendBridgeControl(_ line: String) {
    guard let handle = inputPipe?.fileHandleForWriting else { return }
    try? handle.write(contentsOf: Data("\(line)\n".utf8))
  }

  private func resolveHelperURL() throws -> URL {
    let fileManager = FileManager.default
    let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/codex-ride")
    if fileManager.isExecutableFile(atPath: bundleHelper.path) { return bundleHelper }
    let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .deletingLastPathComponent().appendingPathComponent("codex-ride")
    if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }
    if let root = ProcessInfo.processInfo.environment["CODEX_MICRO_BRIDGE_ROOT"] {
      let helper = URL(fileURLWithPath: root).appendingPathComponent(".build/release/codex-ride")
      if fileManager.isExecutableFile(atPath: helper.path) { return helper }
    }
    throw NSError(
      domain: "CodexMicroMenu", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "The codex-ride helper is missing. Rebuild the app."
      ])
  }

  private func resolveConfigURL() throws -> URL {
    let fileManager = FileManager.default
    if let bundled = Bundle.main.url(forResource: "zwift-ride", withExtension: "json") {
      return bundled
    }
    if let root = ProcessInfo.processInfo.environment["CODEX_MICRO_BRIDGE_ROOT"] {
      let config = URL(fileURLWithPath: root).appendingPathComponent(
        "config/zwift-ride.example.json")
      if fileManager.fileExists(atPath: config.path) { return config }
    }
    let config = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(
      "config/zwift-ride.example.json")
    if fileManager.fileExists(atPath: config.path) { return config }
    throw NSError(
      domain: "CodexMicroMenu", code: 2,
      userInfo: [
        NSLocalizedDescriptionKey: "The Zwift Ride configuration is missing."
      ])
  }

  private func projectRoot(for configURL: URL) -> URL {
    if configURL.lastPathComponent == "zwift-ride.example.json" {
      return configURL.deletingLastPathComponent().deletingLastPathComponent()
    }
    return Bundle.main.bundleURL
  }

  private func consume(_ data: Data) {
    pendingLogData.append(data)
    while let newline = pendingLogData.firstIndex(of: 0x0A) {
      let lineData = pendingLogData[..<newline]
      pendingLogData.removeSubrange(...newline)
      guard let line = String(data: lineData, encoding: .utf8) else { continue }
      consume(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func consume(_ line: String) {
    guard !line.isEmpty else { return }
    if consumeSpeechProtocol(line) { return }
    appendLog(line)

    if line.hasPrefix("Using physical bridge: ") {
      lifecycle = .running
      leonardoState = .ready
      return
    }
    if line.hasPrefix("[Codex] conversation -> ") {
      switch line.split(separator: " ").last {
      case "idle": threadState = .idle
      case "working": threadState = .thinking
      case "needsInput": threadState = .needsYou
      default: break
      }
      refreshCodexState()
      return
    }
    if line.hasPrefix("[Codex] display -> ") {
      let label = String(line.dropFirst("[Codex] display -> ".count)).uppercased()
      if let state = codexState(forDisplayLabel: label) {
        threadState = state
        refreshCodexState()
      }
      return
    }
    if line.hasPrefix("[Codex] voice -> ") {
      switch line.split(separator: " ").last {
      case "recording":
        stopSpeech(status: "Stopped for dictation")
        voiceState = .listening
      case "processing": voiceState = .processing
      case "completed": voiceState = .heard
      case "idle": voiceState = nil
      default: break
      }
      refreshCodexState()
      return
    }
    if line.hasPrefix("[M5StickC] display ") {
      let label = String(line.dropFirst("[M5StickC] display ".count)).uppercased()
      if label == "PREPARING" || label == "SPEAKING" { return }
      if let state = codexState(forDisplayLabel: label) {
        if state == .listening || state == .processing || state == .heard {
          voiceState = state
        } else {
          threadState = state
        }
        refreshCodexState()
      }
      return
    }
    if line.hasPrefix("[M5StickC]") {
      updateM5State(from: line.lowercased())
      return
    }
    if line.hasPrefix("[Zwift Ride]") {
      updateRideState(from: line.lowercased())
      return
    }
    let lowercased = line.lowercased()
    if lowercased.contains("physical bridge") && lowercased.contains("failed") {
      leonardoState = .error
    }
  }

  private func consumeSpeechProtocol(_ line: String) -> Bool {
    if line == "SPEECH STARTED" || line == "SPEECH ABORTED" {
      stopSpeech(status: speechPhase == .idle ? nil : "Stopped for new turn")
      return true
    }
    let prefix = "SPEECH COMPLETE "
    guard line.hasPrefix(prefix) else { return line.hasPrefix("SPEECH ") }
    let encoded = String(line.dropFirst(prefix.count))
    guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      speechStatus = "The completed Codex response could not be decoded."
      return true
    }
    lastResponse = text
    if automaticSpeech {
      requestSpeech(text)
    } else {
      speechStatus = "Response ready"
    }
    return true
  }

  private func codexState(forDisplayLabel label: String) -> CodexState? {
    switch label {
    case "OFFLINE", "OFF": return .offline
    case "WAITING": return .waiting
    case "IDLE": return .idle
    case "THINKING": return .thinking
    case "NEEDS YOU", "NEEDS_INPUT": return .needsYou
    case "ERROR": return .error
    case "LISTENING": return .listening
    case "PROCESSING": return .processing
    case "HEARD": return .heard
    case "DONE", "UNREAD": return .done
    case "PREPARING": return .preparing
    case "SPEAKING": return .speaking
    default: return nil
    }
  }

  private func refreshCodexState() {
    if let voiceState {
      codexState = voiceState
    } else if speechPhase == .preparing {
      codexState = .preparing
    } else if speechPhase == .speaking {
      codexState = .speaking
    } else {
      codexState = threadState
    }
  }

  private func updateM5State(from line: String) {
    if line.contains("bluetooth permission denied") || line.contains("not supported")
      || line.contains("failed") || line.contains("incomplete")
    {
      m5State = .error
    } else if line.contains("ready") || line.contains("wireless link ready") {
      m5State = .ready
    } else if line.contains("connecting") || line.contains("discovering") {
      m5State = .connecting
    } else if line.contains("disconnected") {
      m5State = .disconnected
    } else if line.contains("scanning") {
      m5State = .scanning
    }
  }

  private func updateRideState(from line: String) {
    if line.contains("permission denied") || line.contains("not supported")
      || line.contains("failed") || line.contains("incomplete") || line.contains("invalid")
    {
      rideState = .error
    } else if line.hasSuffix(" ready") {
      rideState = .ready
    } else if line.hasSuffix(" connected") || line.contains("handshake-sent") {
      rideState = .connecting
    } else if line.contains("connecting") {
      rideState = .connecting
    } else if line.contains("disconnected") || line.contains("bluetooth-off") {
      rideState = .disconnected
    } else if line.contains("scanning") || line.contains("found-right") {
      rideState = .scanning
    }
  }

  private func processEnded(status: Int32) {
    if !pendingLogData.isEmpty, let line = String(data: pendingLogData, encoding: .utf8) {
      consume(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    pendingLogData.removeAll()
    logPipe?.fileHandleForReading.readabilityHandler = nil
    logPipe = nil
    inputPipe = nil
    process = nil
    let wasStopping = lifecycle == .stopping
    lifecycle = status == 0 || wasStopping ? .stopped : .failed
    threadState = .offline
    voiceState = nil
    stopSpeech(status: nil)
    m5State = .unavailable
    rideState = .unavailable
    leonardoState = .unavailable
    let message = wasStopping ? "Bridge stopped" : "Bridge exited with status \(status)"
    appendLog(message)
    if !wasStopping, status != 0 { NSLog("Codex Micro Bridge: %@", message) }
  }

  private func appendLog(_ line: String) {
    let timestamp = Date.now.formatted(date: .omitted, time: .standard)
    logs.append("\(timestamp)  \(line)")
    if logs.count > 60 { logs.removeFirst(logs.count - 60) }
  }
}

extension DeviceState {
  fileprivate var color: Color {
    switch self {
    case .ready: return .green
    case .scanning, .connecting, .waiting: return .orange
    case .error: return .red
    case .unavailable, .disconnected: return .secondary
    }
  }
}

private struct StatusRow: View {
  let name: String
  let state: DeviceState

  var body: some View {
    HStack(spacing: 9) {
      Circle().fill(state.color).frame(width: 8, height: 8)
      Text(name)
      Spacer()
      Text(state.rawValue).foregroundStyle(.secondary)
    }
  }
}

private struct SettingsSection<Content: View>: View {
  let title: String
  let description: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.headline)
      Text(description)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct PopUpOption {
  let id: String
  let title: String
}

private struct PopUpSelector: NSViewRepresentable {
  let options: [PopUpOption]
  @Binding var selection: String

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSPopUpButton {
    let control = NSPopUpButton(frame: .zero, pullsDown: false)
    control.target = context.coordinator
    control.action = #selector(Coordinator.selectionChanged(_:))
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return control
  }

  func updateNSView(_ control: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    context.coordinator.optionIDs = options.map(\.id)

    let titles = options.map(\.title)
    if control.itemTitles != titles {
      control.removeAllItems()
      control.addItems(withTitles: titles)
    }

    if let index = options.firstIndex(where: { $0.id == selection }) {
      control.selectItem(at: index)
    }
  }

  final class Coordinator: NSObject {
    var selection: Binding<String>
    var optionIDs: [String] = []

    init(selection: Binding<String>) {
      self.selection = selection
    }

    @objc func selectionChanged(_ sender: NSPopUpButton) {
      guard optionIDs.indices.contains(sender.indexOfSelectedItem) else { return }
      selection.wrappedValue = optionIDs[sender.indexOfSelectedItem]
    }
  }
}

private struct SpeechSettings: View {
  @ObservedObject var controller: BridgeController

  private var keyButtonTitle: String { controller.hasAPIKey ? "Replace" : "Save Key" }
  private var keyPlaceholder: String {
    controller.hasAPIKey ? "Paste a replacement key" : "Paste an OpenAI API key"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsSection(
        title: "Spoken Responses",
        description: "Automatically speak each completed Codex response"
      ) {
        HStack {
          Text("Speak completed responses")
          Spacer()
          Toggle("", isOn: $controller.automaticSpeech)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }

      SettingsSection(
        title: "OpenAI API Key",
        description: "Used only to generate speech audio"
      ) {
        HStack(spacing: 8) {
          SecureField(keyPlaceholder, text: $controller.apiKeyDraft)
            .textFieldStyle(.roundedBorder)
          Button(keyButtonTitle) { controller.saveAPIKey() }
            .disabled(
              controller.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if controller.hasAPIKey {
          HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Text("Saved in Keychain")
              .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
              controller.removeAPIKey()
            } label: {
              Text("Remove")
            }
            .buttonStyle(.borderless)
          }
          .font(.caption)
        }
      }

      SettingsSection(
        title: "Voice",
        description: "The voice used for spoken responses"
      ) {
        PopUpSelector(
          options: BridgeController.voices.map {
            PopUpOption(id: $0, title: $0.capitalized)
          },
          selection: $controller.selectedVoice
        )
        .frame(maxWidth: .infinity)
        .frame(height: 28)
      }

      SettingsSection(
        title: "Spoken Length",
        description: "How much detail to keep in the spoken version"
      ) {
        Picker("Spoken Length", selection: $controller.selectedLength) {
          ForEach(SpeechLength.allCases) { length in
            Text(length.rawValue.capitalized).tag(length)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      SettingsSection(
        title: "Audio Output",
        description: "Where spoken responses are played"
      ) {
        HStack(spacing: 7) {
          PopUpSelector(
            options: controller.audioOutputs.map {
              PopUpOption(id: $0.id, title: $0.name)
            },
            selection: $controller.selectedOutputUID
          )
          .frame(maxWidth: .infinity)
          .frame(height: 28)

          Button {
            controller.refreshAudioOutputs()
          } label: {
            Image(systemName: "arrow.clockwise")
              .frame(width: 16, height: 16)
          }
          .buttonStyle(.bordered)
          .help("Refresh audio outputs")
        }
      }

      SettingsSection(
        title: "Playback",
        description: controller.speechStatus
      ) {
        HStack(spacing: 8) {
          Button {
            controller.testVoice()
          } label: {
            Text("Test Voice").frame(maxWidth: .infinity)
          }
          .disabled(!controller.hasAPIKey)
          Button {
            controller.speakLastResponse()
          } label: {
            Text("Replay Last").frame(maxWidth: .infinity)
          }
          .disabled(!controller.canSpeakLastResponse)
          Button {
            controller.stopSpeaking()
          } label: {
            Text("Stop").frame(maxWidth: .infinity)
          }
          .disabled(!controller.canStopSpeech)
        }
      }

      Text("AI-generated voice. Only speech audio uses the API key.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.top, 9)
    .padding(.horizontal, 2)
  }
}

private struct MenuContent: View {
  @ObservedObject var controller: BridgeController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsSection(
          title: "Codex Micro Bridge",
          description: "Current conversation state"
        ) {
          HStack(spacing: 10) {
            Image(systemName: controller.codexState.symbol)
              .font(.system(size: 24, weight: .semibold))
              .foregroundStyle(controller.codexState.color)
            Text(controller.codexState.rawValue)
              .font(.title2.bold())
            Spacer()
            Text(controller.lifecycle.rawValue)
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          }
        }

        SettingsSection(
          title: "Devices",
          description: "Connected Codex Micro companions"
        ) {
          VStack(spacing: 10) {
            StatusRow(name: "Leonardo", state: controller.leonardoState)
            StatusRow(name: "M5StickC Plus2", state: controller.m5State)
            StatusRow(name: "Zwift Ride", state: controller.rideState)
          }
        }

        SettingsSection(
          title: "Bridge",
          description: "Connect device input and conversation feedback"
        ) {
          Button {
            controller.isRunning ? controller.stop() : controller.start()
          } label: {
            Text(controller.isRunning ? "Stop Bridge" : "Start Bridge")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(controller.lifecycle == .starting || controller.lifecycle == .stopping)
        }

        SpeechSettings(controller: controller)

        SettingsSection(
          title: "Recent Activity",
          description: "Latest events from the bridge"
        ) {
          DisclosureGroup("Show activity", isExpanded: $controller.showingLogs) {
            ScrollView {
              Text(controller.logs.suffix(30).joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .frame(height: 130)
          }
          .font(.caption)
        }

        Button("Quit Codex Micro Bridge") { controller.quit() }
          .keyboardShortcut("q")
          .frame(maxWidth: .infinity)
      }
      .padding(16)
    }
    .frame(width: 380, height: 640)
    .task { controller.startAutomatically() }
  }
}

private struct CodexMicroMenuApp: App {
  @StateObject private var controller: BridgeController

  init() {
    let controller = BridgeController()
    _controller = StateObject(wrappedValue: controller)
    DispatchQueue.main.async { controller.startAutomatically() }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(controller: controller)
    } label: {
      Label(controller.codexState.rawValue, systemImage: controller.codexState.symbol)
    }
    .menuBarExtraStyle(.window)
  }
}

CodexMicroMenuApp.main()
