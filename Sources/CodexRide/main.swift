import CodexMicroBridge
import CoreBluetooth
import Foundation

private let rideService = CBUUID(string: "0000FC82-0000-1000-8000-00805F9B34FB")
private let legacyService = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
private let asyncCharacteristic = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
private let syncRxCharacteristic = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")
private let syncTxCharacteristic = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")
private let rideOn = Data([0x52, 0x69, 0x64, 0x65, 0x4f, 0x6e])
private let zwiftCompanyID: UInt16 = 0x094a
private let rideLeftType: UInt8 = 0x08
private let rideRightType: UInt8 = 0x07
private let controllerNotification: UInt8 = 0x23
private let companionService = CBUUID(string: "7A0A0001-1E8E-4D91-9A4B-21D02E0C0D01")
private let companionNotify = CBUUID(string: "7A0A0002-1E8E-4D91-9A4B-21D02E0C0D01")
private let companionWrite = CBUUID(string: "7A0A0003-1E8E-4D91-9A4B-21D02E0C0D01")

private final class StandardInputReader {
  private var pending = Data()
  private let onLine: (String) -> Void

  init(onLine: @escaping (String) -> Void) {
    self.onLine = onLine
    FileHandle.standardInput.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self.pending.append(data)
      while let newline = self.pending.firstIndex(of: 0x0A) {
        let lineData = self.pending[..<newline]
        self.pending.removeSubrange(...newline)
        guard let line = String(data: lineData, encoding: .utf8) else { continue }
        self.onLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
  }

  deinit { FileHandle.standardInput.readabilityHandler = nil }
}

private enum ReaderEvent {
  case status(state: String, details: [String: Any] = [:])
  case error(String)
  case button(source: String, name: String, state: String)

  var json: [String: Any] {
    switch self {
    case .status(let state, let details):
      return ["message": "status", "state": state].merging(details) { _, new in new }
    case .error(let error):
      return ["message": "error", "error": error]
    case .button(let source, let name, let state):
      return ["message": "button", "source": source, "button": name, "state": state]
    }
  }
}

private final class ZwiftRideReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let onEvent: (ReaderEvent) -> Void
  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var asyncInput: CBCharacteristic?
  private var syncInput: CBCharacteristic?
  private var syncOutput: CBCharacteristic?
  private var readyNotifications = Set<CBUUID>()
  private var handshakeSent = false
  private var pressed = Set<String>()

  init(onEvent: @escaping (ReaderEvent) -> Void) {
    self.onEvent = onEvent
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      onEvent(.status(state: "scanning"))
      central.scanForPeripherals(
        withServices: nil,
        options: [
          CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    case .unauthorized:
      onEvent(.error("Bluetooth permission denied"))
      exit(2)
    case .unsupported:
      onEvent(.error("Bluetooth is not supported"))
      exit(2)
    case .poweredOff:
      onEvent(.status(state: "bluetooth-off"))
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover candidate: CBPeripheral,
    advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    guard peripheral == nil else { return }
    let name =
      (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? candidate.name ?? ""
    let advertisedServices =
      advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let hasRideService =
      advertisedServices.contains(rideService) || advertisedServices.contains(legacyService)

    var controllerType: UInt8?
    if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
      manufacturer.count >= 3
    {
      let bytes = [UInt8](manufacturer)
      let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
      if company == zwiftCompanyID { controllerType = bytes[2] }
    }

    if controllerType == rideRightType {
      onEvent(.status(state: "found-right", details: ["name": name]))
      return
    }
    guard controllerType == rideLeftType || (name == "Zwift Ride" && hasRideService) else { return }

    peripheral = candidate
    candidate.delegate = self
    central.stopScan()
    onEvent(
      .status(
        state: "connecting",
        details: [
          "name": name,
          "id": candidate.identifier.uuidString,
          "rssi": rssi.intValue,
        ]))
    central.connect(candidate)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    onEvent(.status(state: "connected", details: ["name": peripheral.name ?? "Zwift Ride"]))
    peripheral.discoverServices([rideService, legacyService])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    onEvent(.error(error?.localizedDescription ?? "Connection failed"))
    restartScan()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    handleDisconnect(error: error)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    handleDisconnect(error: error)
  }

  private func handleDisconnect(error: Error?) {
    releaseAllButtons()
    onEvent(.status(state: "disconnected", details: ["error": error?.localizedDescription ?? ""]))
    restartScan()
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      onEvent(.error("Service discovery failed: \(error.localizedDescription)"))
      return
    }
    let services = peripheral.services ?? []
    guard
      let service = services.first(where: { $0.uuid == rideService || $0.uuid == legacyService })
    else {
      onEvent(.error("Zwift controller service was not found"))
      central.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics(
      [asyncCharacteristic, syncRxCharacteristic, syncTxCharacteristic],
      for: service
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    if let error {
      onEvent(.error("Characteristic discovery failed: \(error.localizedDescription)"))
      return
    }
    for characteristic in service.characteristics ?? [] {
      switch characteristic.uuid {
      case asyncCharacteristic: asyncInput = characteristic
      case syncRxCharacteristic: syncOutput = characteristic
      case syncTxCharacteristic: syncInput = characteristic
      default: break
      }
    }
    guard let asyncInput, let syncInput, syncOutput != nil else {
      onEvent(.error("Zwift Ride characteristics were incomplete"))
      central.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.setNotifyValue(true, for: asyncInput)
    peripheral.setNotifyValue(true, for: syncInput)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      onEvent(.error("Could not subscribe: \(error.localizedDescription)"))
      return
    }
    if characteristic.isNotifying { readyNotifications.insert(characteristic.uuid) }
    guard readyNotifications.contains(asyncCharacteristic),
      readyNotifications.contains(syncTxCharacteristic),
      !handshakeSent,
      let output = syncOutput
    else { return }

    let writeType: CBCharacteristicWriteType =
      output.properties.contains(.writeWithoutResponse)
      ? .withoutResponse : .withResponse
    peripheral.writeValue(rideOn, for: output, type: writeType)
    handshakeSent = true
    onEvent(.status(state: "handshake-sent"))
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    if let error {
      onEvent(.error("Bluetooth update failed: \(error.localizedDescription)"))
      return
    }
    guard let value = characteristic.value else { return }
    if characteristic.uuid == syncTxCharacteristic {
      if value.starts(with: rideOn) {
        onEvent(.status(state: "ready", details: ["name": peripheral.name ?? "Zwift Ride"]))
      }
      return
    }
    guard characteristic.uuid == asyncCharacteristic else { return }
    processNotification([UInt8](value))
  }

  private func processNotification(_ bytes: [UInt8]) {
    guard bytes.first == controllerNotification else { return }
    do {
      let current = try RideProtocolDecoder.pressedButtons(in: Array(bytes.dropFirst()))
      for button in current.subtracting(pressed).sorted() { emit(button: button, state: "down") }
      for button in pressed.subtracting(current).sorted() { emit(button: button, state: "up") }
      pressed = current
    } catch {
      onEvent(.error("Invalid Zwift Ride packet: \(error)"))
    }
  }

  private func emit(button: String, state: String) {
    onEvent(.button(source: peripheral?.name ?? "Zwift Ride", name: button, state: state))
  }

  private func releaseAllButtons() {
    for button in pressed.sorted() { emit(button: button, state: "up") }
    pressed.removeAll()
  }

  private func restartScan() {
    peripheral = nil
    asyncInput = nil
    syncInput = nil
    syncOutput = nil
    readyNotifications.removeAll()
    handshakeSent = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      guard self.central.state == .poweredOn else { return }
      self.onEvent(.status(state: "scanning"))
      self.central.scanForPeripherals(
        withServices: nil,
        options: [
          CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }
  }
}

private final class M5CompanionReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let onEvent: (CompanionEvent) -> Void
  private let onStatus: (String) -> Void
  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var notifyCharacteristic: CBCharacteristic?
  private var writeCharacteristic: CBCharacteristic?

  init(onEvent: @escaping (CompanionEvent) -> Void, onStatus: @escaping (String) -> Void) {
    self.onEvent = onEvent
    self.onStatus = onStatus
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func send(_ line: String) {
    DispatchQueue.main.async { [weak self] in
      self?.write(line)
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      scan()
    case .unauthorized:
      onStatus("Bluetooth permission denied")
    case .unsupported:
      onStatus("Bluetooth is not supported")
    case .poweredOff:
      onStatus("Bluetooth is off")
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover candidate: CBPeripheral,
    advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    guard peripheral == nil else { return }
    peripheral = candidate
    candidate.delegate = self
    central.stopScan()
    let name = candidate.name ?? "Codex M5"
    onStatus("connecting to \(name) (RSSI \(rssi.intValue))")
    central.connect(candidate)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    onStatus("connected; discovering service")
    peripheral.discoverServices([companionService])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    onStatus("connection failed: \(error?.localizedDescription ?? "unknown error")")
    restartScan()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    handleDisconnect(error: error)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    handleDisconnect(error: error)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      onStatus("service discovery failed: \(error.localizedDescription)")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == companionService }) else {
      onStatus("wireless companion service was not found")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics([companionNotify, companionWrite], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error {
      onStatus("characteristic discovery failed: \(error.localizedDescription)")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    for characteristic in service.characteristics ?? [] {
      switch characteristic.uuid {
      case companionNotify: notifyCharacteristic = characteristic
      case companionWrite: writeCharacteristic = characteristic
      default: break
      }
    }
    guard let notifyCharacteristic, writeCharacteristic != nil else {
      onStatus("wireless companion characteristics were incomplete")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.setNotifyValue(true, for: notifyCharacteristic)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      onStatus("notification subscription failed: \(error.localizedDescription)")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    guard characteristic.uuid == companionNotify, characteristic.isNotifying else { return }
    onStatus("wireless link ready")
    write("PING")
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      onStatus("notification failed: \(error.localizedDescription)")
      return
    }
    guard characteristic.uuid == companionNotify,
      let value = characteristic.value,
      let line = String(data: value, encoding: .utf8)
    else { return }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { onEvent(CompanionProtocol.decode(trimmed)) }
  }

  private func write(_ line: String) {
    guard let peripheral, let characteristic = writeCharacteristic else { return }
    let data = Data(line.utf8)
    let type: CBCharacteristicWriteType =
      characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    guard data.count <= peripheral.maximumWriteValueLength(for: type) else {
      onStatus("command is too large for BLE: \(line)")
      return
    }
    peripheral.writeValue(data, for: characteristic, type: type)
  }

  private func scan() {
    guard peripheral == nil, central.state == .poweredOn else { return }
    onStatus("scanning")
    central.scanForPeripherals(
      withServices: [companionService],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }

  private func handleDisconnect(error: Error?) {
    onStatus("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    restartScan()
  }

  private func restartScan() {
    peripheral = nil
    notifyCharacteristic = nil
    writeCharacteristic = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let command = arguments.first ?? "help"
  let argument = arguments.count > 1 ? arguments[1] : nil
  let defaultConfig = ProjectPaths.config("zwift-ride.example.json")
  let configPath = URL(fileURLWithPath: argument ?? defaultConfig).standardized.path

  switch command {
  case "validate":
    _ = try ConfigurationLoader.ride(at: configPath)
    print("Valid Zwift Ride mapping: \(configPath)")
  case "self-test":
    try runSelfTest()
    print("Zwift Ride decoder self-test passed")
  case "monitor":
    let reader = ZwiftRideReader { writeJSON($0.json) }
    withExtendedLifetime(reader) { RunLoop.main.run() }
  case "run":
    let config = try ConfigurationLoader.ride(at: configPath)
    let mapper = try RideMapper(config: config)
    let hardware = try HardwareTransport(port: config.serialPort)
    let companionMapper = CompanionMapper(mappings: config.companionMappings)
    let commandQueue = DispatchQueue(label: "Codex Micro Ride commands")
    let feedbackLock = NSLock()
    var latestFeedback: [Int: CodexFeedback] = [:]
    var latestVoiceState = CodexVoiceState.idle
    var voiceStateResolver = CodexVoiceStateResolver()
    var conversationState = CodexConversationState.idle
    var companion: M5CompanionReader? = nil
    var activityMonitor: CodexActivityMonitor? = nil
    var inputReader: StandardInputReader? = nil
    let speechEventsEnabled = ProcessInfo.processInfo.environment["CODEX_MICRO_TTS_EVENTS"] == "1"
    let sendCompanion: (String) -> Void = { line in
      companion?.send(line)
    }
    let sendCurrentState = {
      feedbackLock.lock()
      let snapshot = CodexFeedbackProjector.project(
        Array(latestFeedback.values),
        conversationState: conversationState
      )
      let voiceState = latestVoiceState
      feedbackLock.unlock()
      let aggregateState = CodexFeedbackProjector.aggregate(snapshot)
      writeError("[Codex] display -> \(aggregateState.rawValue)")
      for feedback in snapshot { sendCompanion(feedback.companionCommand) }
      sendCompanion(voiceState.companionCommand)
    }
    writeError("Using physical bridge: \(hardware.port)")
    if config.companionEnabled {
      writeError("Using wireless M5StickC companion")
      companion = M5CompanionReader(
        onEvent: { event in
          switch event {
          case .ready(let name):
            writeError("[M5StickC] ready \(name)")
            sendCurrentState()
          case .button(let button, let state):
            for command in companionMapper.process(button: button, state: state) {
              commandQueue.async {
                do {
                  try hardware.send(command)
                  writeError("M5StickC \(button) \(state) -> \(command.keyDescription)")
                } catch {
                  writeError("M5StickC command failed: \(error.localizedDescription)")
                }
              }
            }
          case .microphone:
            break
          case .display(let state):
            writeError("[M5StickC] display \(state)")
          case .unknown(let line):
            writeError("[M5StickC] \(line)")
          }
        },
        onStatus: { writeError("[M5StickC] \($0)") }
      )
      inputReader = StandardInputReader { line in
        guard
          line == "SPEECH PREPARING" || line == "SPEECH SPEAKING"
            || line == "SPEECH IDLE"
        else { return }
        sendCompanion(line)
      }
      hardware.startFeedback { line in
        guard let message = CodexFeedbackDecoder.decodeMessage(line) else { return }
        switch message {
        case .threads(let decoded):
          feedbackLock.lock()
          for feedback in decoded { latestFeedback[feedback.agent] = feedback }
          feedbackLock.unlock()
          sendCurrentState()
        case .lighting(let lighting):
          feedbackLock.lock()
          let changedVoiceState = voiceStateResolver.consume(lighting)
          if let changedVoiceState { latestVoiceState = changedVoiceState }
          feedbackLock.unlock()
          guard let changedVoiceState else { return }
          writeError("[Codex] voice -> \(changedVoiceState.rawValue.lowercased())")
          sendCompanion(changedVoiceState.companionCommand)
          if changedVoiceState == .completed {
            commandQueue.async {
              do {
                try hardware.send(.press(key: "ACT12", durationMs: 60))
                writeError("[Codex] transcription completed -> ACT12 submit")
              } catch {
                writeError("Codex transcription submit failed: \(error.localizedDescription)")
              }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
              feedbackLock.lock()
              let idleState = voiceStateResolver.completeDisplayWindow()
              if let idleState { latestVoiceState = idleState }
              feedbackLock.unlock()
              guard let idleState else { return }
              writeError("[Codex] voice -> idle")
              sendCompanion(idleState.companionCommand)
            }
          }
        }
      }
      try hardware.replayFeedback()
    }
    if config.companionEnabled || speechEventsEnabled {
      activityMonitor = CodexActivityMonitor(
        onSpeechEvent: { event in
          guard speechEventsEnabled else { return }
          switch event {
          case .taskStarted:
            writeError("SPEECH STARTED")
          case .turnAborted:
            writeError("SPEECH ABORTED")
          case .responseCompleted(let text):
            let encoded = Data(text.utf8).base64EncodedString()
            writeError("SPEECH COMPLETE \(encoded)")
          }
        },
        onChange: { state in
          feedbackLock.lock()
          conversationState = state
          feedbackLock.unlock()
          writeError("[Codex] conversation -> \(state)")
          sendCurrentState()
        }
      )
      activityMonitor?.start()
    }
    writeError("Using Zwift Ride mapping: \(configPath)")
    let reader = ZwiftRideReader { event in
      switch event {
      case .status(let state, _):
        writeError("[Zwift Ride] \(state)")
      case .error(let error):
        writeError("[Zwift Ride] \(error)")
      case .button(_, let button, let state):
        for command in mapper.process(.init(button: button, state: state)) {
          commandQueue.async {
            do {
              try hardware.send(command)
              writeError("\(button) \(state) -> \(command.keyDescription)")
            } catch {
              writeError("Zwift Ride command failed: \(error.localizedDescription)")
            }
          }
        }
      }
    }
    withExtendedLifetime((reader, hardware, companion, activityMonitor, inputReader)) {
      RunLoop.main.run()
    }
  default:
    print("Usage: codex-ride monitor | validate [config.json] | self-test | run [config.json]")
  }
} catch {
  writeError(error.localizedDescription)
  exit(1)
}

private func runSelfTest() throws {
  let released = try RideProtocolDecoder.pressedButtons(in: [0x08, 0xff, 0xff, 0xff, 0xff, 0x0f])
  guard released.isEmpty else { throw BridgeError("released-button packet decoded incorrectly") }

  let leftPressed = try RideProtocolDecoder.pressedButtons(in: [0x08, 0xfe, 0xff, 0xff, 0xff, 0x0f])
  guard leftPressed == ["navigationLeft"] else {
    throw BridgeError("navigation-button packet decoded incorrectly")
  }

  let paddle = try RideProtocolDecoder.pressedButtons(in: [
    0x08, 0xff, 0xff, 0xff, 0xff, 0x0f,
    0x1a, 0x02, 0x10, 0x3c,
  ])
  guard paddle == ["paddleLeft"] else { throw BridgeError("paddle packet decoded incorrectly") }
}

private func writeJSON(_ value: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: value),
    let newline = "\n".data(using: .utf8)
  else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(newline)
}

private func writeError(_ message: String) {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
}

extension HardwareCommand {
  fileprivate var keyDescription: String {
    switch self {
    case .hid(let key, _, _), .press(let key, _, _): return key
    case .joystick: return "joystick"
    }
  }
}
