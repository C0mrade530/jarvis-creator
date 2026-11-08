import AVFoundation
import Foundation

@MainActor
final class StreamingSpeech {
    enum Outcome {
        case finished
        case failed(afterPlayback: Bool)
    }
    private enum OutputError: Error { case unavailable }

    private static let sampleRate = 24_000.0
    private static let packetFrames = 1_440
    private static let maximumBytes = 4_800_000

    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let onStarted: () -> Void
    private let onFinished: (Outcome) -> Void
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: StreamingSpeech.sampleRate, channels: 1)!
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var pending = Data()
    private var receivedBytes = 0
    private var queuedFrames = 0
    private var outputReady = false
    private var ended = false
    private var receivedEOF = false
    private var networkSucceeded = false
    private var notifiedPlayback = false
    private var audioObserver: NSObjectProtocol?
    private var drainDeadline: DispatchWorkItem?
    private(set) var isPlaying = false
    private(set) var level = 0.0

    static func elevenLabsRequest(text: String, voiceID: String, apiKey: String) -> URLRequest? {
        guard voiceID.range(of: #"\A[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil,
              apiKey.range(of: #"\A[A-Za-z0-9_-]{8,200}\z"#, options: .regularExpression) != nil else { return nil }
        let scalars = text.prefix(600).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "[" && $0 != "]"
        }
        let text = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: apiKey, with: "скрыто").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(voiceID)/stream"
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        guard let url = components.url,
              let body = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_multilingual_v2"]) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = body
        return request
    }

    init(request: URLRequest, configuration: URLSessionConfiguration = .ephemeral,
         onStarted: @escaping () -> Void, onFinished: @escaping (Outcome) -> Void) {
        self.request = request
        self.configuration = configuration
        self.onStarted = onStarted
        self.onFinished = onFinished
    }

    func start() {
        guard session == nil, !ended else { return }
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 45
        let delegate = PCMStreamDelegate { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let connection = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        session = connection
        task = connection.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        guard !ended else { return }
        shutDown()
    }

    private func receive(_ event: PCMStreamDelegate.Event) {
        guard !ended, !receivedEOF else { return }
        switch event {
        case .data(let bytes):
            receivedBytes += bytes.count
            guard receivedBytes <= Self.maximumBytes else { fail(); return }
            pending.append(bytes)
            // Queue 120 ms of PCM before starting the device, then play while later packets arrive.
            if outputReady || pending.count >= Self.packetFrames * 4 { enqueue(flush: false) }
        case .complete(let success):
            receivedEOF = true
            networkSucceeded = success && receivedBytes > 0 && receivedBytes.isMultiple(of: 2)
            if networkSucceeded { enqueue(flush: true) }
            else if !isPlaying { fail(); return }
            else { pending.removeAll() }
            guard !ended else { return }
            if queuedFrames == 0 { finishDrain(); return }
            let deadline = DispatchWorkItem { [weak self] in self?.fail() }
            drainDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(queuedFrames) / Self.sampleRate + 2, execute: deadline)
        }
    }

    private func enqueue(flush: Bool) {
        guard !ended, pending.count >= 2 else { return }
        if !outputReady {
            // A successful response should contain raw PCM, with no encoded-audio container header.
            if pending.starts(with: [0x52, 0x49, 0x46, 0x46]) || pending.starts(with: [0x49, 0x44, 0x33]) {
                fail()
                return
            }
            do { try prepareOutput() }
            catch { fail(); return }
        }
        let packetBytes = Self.packetFrames * 2
        var offset = 0
        while pending.count - offset >= packetBytes || (flush && pending.count - offset >= 2) {
            let frames = min(Self.packetFrames, (pending.count - offset) / 2)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let samples = buffer.floatChannelData?[0] else { fail(); return }
            buffer.frameLength = AVAudioFrameCount(frames)
            pending.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for frame in 0..<frames {
                    let i = offset + frame * 2
                    let sample = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                    samples[frame] = Float(sample) / 32768
                }
            }
            offset += frames * 2
            queuedFrames += frames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.bufferPlayed(frames) }
            }
        }
        pending.removeFirst(offset)
        if !isPlaying, queuedFrames > 0 {
            isPlaying = true
            player.play()
        }
    }

    private func prepareOutput() throws {
        let deviceFormat = engine.outputNode.outputFormat(forBus: 0)
        guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else { throw OutputError.unavailable }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var energy = 0.0
            for index in 0..<Int(buffer.frameLength) {
                let value = Double(samples[index])
                energy += value * value
            }
            let measured = min(1, sqrt(energy / Double(buffer.frameLength)) * 4)
            DispatchQueue.main.async {
                guard let self = self, self.isPlaying else { return }
                self.level = measured
            }
        }
        outputReady = true
        audioObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.isPlaying, !self.engine.isRunning else { return }
                self.fail()
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func bufferPlayed(_ frames: Int) {
        guard !ended, isPlaying else { return }
        queuedFrames -= frames
        if !notifiedPlayback {
            notifiedPlayback = true
            onStarted()
        }
        if receivedEOF, queuedFrames == 0 { finishDrain() }
    }

    private func finishDrain() {
        guard !ended else { return }
        let outcome: Outcome = networkSucceeded && notifiedPlayback ? .finished : .failed(afterPlayback: isPlaying)
        shutDown()
        onFinished(outcome)
    }

    private func fail() {
        guard !ended else { return }
        let started = isPlaying
        shutDown()
        onFinished(.failed(afterPlayback: started))
    }

    private func shutDown() {
        ended = true
        isPlaying = false
        level = 0
        drainDeadline?.cancel()
        drainDeadline = nil
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        if let audioObserver = audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
        audioObserver = nil
        if outputReady {
            player.stop()
            engine.stop()
            player.removeTap(onBus: 0)
        }
        pending.removeAll()
    }
}

private final class PCMStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case data(Data)
        case complete(Bool)
    }

    private let emit: @Sendable (Event) -> Void
    private var accepted = false

    init(emit: @escaping @Sendable (Event) -> Void) { self.emit = emit }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let mime = response.mimeType?.lowercased() ?? ""
        accepted = (response as? HTTPURLResponse)?.statusCode == 200
            && !mime.contains("json") && !mime.hasPrefix("text/")
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if accepted { emit(.data(data)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        emit(.complete(accepted && error == nil))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
