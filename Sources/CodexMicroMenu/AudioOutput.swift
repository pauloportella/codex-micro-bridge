import AVFoundation
import AudioToolbox
import CodexMicroBridge
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Hashable {
  static let systemDefault = AudioOutputDevice(id: "", name: "System Default")

  let id: String
  let name: String
}

enum AudioOutputError: LocalizedError {
  case coreAudio(OSStatus)
  case missingDevice(String)
  case invalidPCM
  case unavailableOutputUnit

  var errorDescription: String? {
    switch self {
    case .coreAudio(let status):
      return "Core Audio could not access the output device (\(status))."
    case .missingDevice(let name):
      return "The selected audio output is unavailable: \(name)."
    case .invalidPCM:
      return "The Speech API returned malformed PCM audio."
    case .unavailableOutputUnit:
      return "The macOS audio output unit is unavailable."
    }
  }
}

struct AudioOutputCatalog {
  func devices() throws -> [AudioOutputDevice] {
    let ids = try audioDeviceIDs()
    let outputs = try ids.compactMap { id -> AudioOutputDevice? in
      guard try hasOutputStreams(id) else { return nil }
      return AudioOutputDevice(
        id: try stringProperty(id, kAudioDevicePropertyDeviceUID),
        name: try stringProperty(id, kAudioObjectPropertyName))
    }
    return [.systemDefault]
      + outputs.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  func resolveDeviceID(uid: String, knownName: String) throws -> AudioDeviceID {
    if uid.isEmpty { return try defaultOutputDeviceID() }
    for id in try audioDeviceIDs() where try hasOutputStreams(id) {
      if try stringProperty(id, kAudioDevicePropertyDeviceUID) == uid { return id }
    }
    throw AudioOutputError.missingDevice(knownName.isEmpty ? uid : knownName)
  }

  private func audioDeviceIDs() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return ids
  }

  private func defaultOutputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return id
  }

  private func hasOutputStreams(_ id: AudioDeviceID) throws -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
    if status == kAudioHardwareUnknownPropertyError { return false }
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return size >= UInt32(MemoryLayout<AudioStreamID>.size)
  }

  private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector)
    throws -> String
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return value.map { $0.takeUnretainedValue() as String } ?? "Unknown Output"
  }
}

@MainActor
final class PCMOutputPlayer {
  private static let startupBufferBytes = 24_000

  private let catalog = AudioOutputCatalog()
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var completion: CheckedContinuation<Void, Error>?
  private var pendingBufferCount = 0
  private var streamFinished = false
  private var playbackGeneration = 0

  func play(
    _ stream: AsyncThrowingStream<Data, Error>,
    outputUID: String,
    outputName: String,
    onPlaybackStarted: () -> Void
  ) async throws {
    stop()
    playbackGeneration += 1
    let generation = playbackGeneration

    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 24_000,
      channels: 1,
      interleaved: false
    )!
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    guard let audioUnit = engine.outputNode.audioUnit else {
      throw AudioOutputError.unavailableOutputUnit
    }
    var deviceID = try catalog.resolveDeviceID(uid: outputUID, knownName: outputName)
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }

    try engine.start()
    self.engine = engine
    self.player = player
    pendingBufferCount = 0
    streamFinished = false

    try await withTaskCancellationHandler {
      do {
        var assembler = PCM16StreamAssembler()
        var startupData = Data()
        var playbackStarted = false

        for try await data in stream {
          try Task.checkCancellation()
          let aligned = assembler.append(data)
          guard !aligned.isEmpty else { continue }
          if playbackStarted {
            try schedule(aligned, format: format, generation: generation)
          } else {
            startupData.append(aligned)
            if startupData.count >= Self.startupBufferBytes {
              try schedule(startupData, format: format, generation: generation)
              startupData.removeAll(keepingCapacity: false)
              player.play()
              playbackStarted = true
              onPlaybackStarted()
            }
          }
        }

        guard !assembler.hasIncompleteSample else { throw AudioOutputError.invalidPCM }
        if !startupData.isEmpty {
          try schedule(startupData, format: format, generation: generation)
          player.play()
          playbackStarted = true
          onPlaybackStarted()
        }
        guard playbackStarted else { throw AudioOutputError.invalidPCM }

        streamFinished = true
        if pendingBufferCount > 0 {
          try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            if pendingBufferCount == 0 { finish(generation: generation) }
          }
        } else {
          finish(generation: generation)
        }
      } catch {
        stop(error: error)
        throw error
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.stop(error: CancellationError()) }
    }
  }

  func stop() {
    stop(error: CancellationError())
  }

  private func schedule(_ data: Data, format: AVAudioFormat, generation: Int) throws {
    guard generation == playbackGeneration,
      !data.isEmpty,
      data.count.isMultiple(of: MemoryLayout<Int16>.size),
      let player
    else { throw AudioOutputError.invalidPCM }

    let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let samples = buffer.floatChannelData?[0]
    else { throw AudioOutputError.invalidPCM }
    buffer.frameLength = frameCount
    data.withUnsafeBytes { bytes in
      for index in 0..<Int(frameCount) {
        let sample = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
        samples[index] = Float(Int16(littleEndian: sample)) / Float(Int16.max)
      }
    }

    pendingBufferCount += 1
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in self?.bufferCompleted(generation: generation) }
    }
  }

  private func bufferCompleted(generation: Int) {
    guard generation == playbackGeneration else { return }
    pendingBufferCount = max(0, pendingBufferCount - 1)
    if streamFinished, pendingBufferCount == 0 { finish(generation: generation) }
  }

  private func stop(error: Error) {
    playbackGeneration += 1
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    pendingBufferCount = 0
    streamFinished = false
    let continuation = completion
    completion = nil
    continuation?.resume(throwing: error)
  }

  private func finish(generation: Int) {
    guard generation == playbackGeneration else { return }
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    pendingBufferCount = 0
    streamFinished = false
    let continuation = completion
    completion = nil
    continuation?.resume()
  }
}
