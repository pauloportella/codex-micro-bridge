import Foundation

enum OpenAISpeechError: LocalizedError {
  case invalidResponse
  case requestFailed(Int)
  case invalidAudio

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The Speech API returned an invalid response."
    case .requestFailed(let status):
      return "The Speech API request failed (HTTP \(status))."
    case .invalidAudio:
      return "The Speech API returned invalid PCM audio."
    }
  }
}

struct OpenAISpeechClient: Sendable {
  private let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

  func synthesizePCM(
    chunks: [String], apiKey: String, voice: String
  ) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let producer = Task {
        do {
          for text in chunks {
            try Task.checkCancellation()
            let request = try request(text: text, apiKey: apiKey, voice: voice)
            let stream = SpeechStreamRequest().start(request)
            for try await data in stream {
              try Task.checkCancellation()
              continuation.yield(data)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in producer.cancel() }
    }
  }

  private func request(text: String, apiKey: String, voice: String) throws -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": "gpt-4o-mini-tts",
      "voice": voice,
      "input": text,
      "instructions": "Speak naturally and conversationally, with clear pacing and warm restraint.",
      "response_format": "pcm",
    ])
    return request
  }
}

private final class SpeechStreamRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var finished = false

  func start(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 90
      configuration.timeoutIntervalForResource = 90
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      let task = session.dataTask(with: request)

      lock.lock()
      self.continuation = continuation
      self.session = session
      self.task = task
      lock.unlock()

      continuation.onTermination = { [weak self] termination in
        if case .cancelled = termination { self?.cancel() }
      }
      task.resume()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      finish(throwing: OpenAISpeechError.invalidResponse)
      completionHandler(.cancel)
      return
    }
    guard response.statusCode == 200 else {
      finish(throwing: OpenAISpeechError.requestFailed(response.statusCode))
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let continuation = finished ? nil : self.continuation
    lock.unlock()
    continuation?.yield(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    if let error {
      finish(throwing: error)
    } else {
      finish()
    }
  }

  private func cancel() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let task = self.task
    let session = self.session
    continuation = nil
    self.task = nil
    self.session = nil
    lock.unlock()
    task?.cancel()
    session?.invalidateAndCancel()
  }

  private func finish(throwing error: Error? = nil) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    let session = self.session
    self.continuation = nil
    task = nil
    self.session = nil
    lock.unlock()

    if let error {
      continuation?.finish(throwing: error)
    } else {
      continuation?.finish()
    }
    session?.finishTasksAndInvalidate()
  }
}
