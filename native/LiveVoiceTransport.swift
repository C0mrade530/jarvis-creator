import AVFoundation
import Foundation

// OpenAI Live primary WebSocket: https://developers.openai.com/api/reference/resources/live/primary-websocket
// Audio on this connection is raw mono, signed 16-bit little-endian PCM at 24 kHz.
enum LiveVoiceWire {
    static let model = "gpt-live-1"
    static let sampleRate = 24_000
    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!

    static func sessionStart(instructions: String, voice: String, eventID: String) -> [String: Any] {
        ["type": "session.start", "event_id": eventID, "session": [
            "model": model, "instructions": instructions, "store": false,
            "audio": ["format": ["type": "audio/pcm", "rate": sampleRate], "output": ["voice": voice]],
            "delegation": ["type": "client"]
        ]]
    }

    static func encode(_ event: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(event),
              let bytes = try? JSONSerialization.data(withJSONObject: event) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func decode(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    static func inputAudio(_ bytes: Data) -> [String: Any]? {
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        return ["type": "session.input_audio.append", "audio": bytes.base64EncodedString()]
    }

    static func outputAudio(_ event: [String: Any]) -> Data? {
        guard event["type"] as? String == "session.output_audio.delta",
              let base64 = event["delta"] as? String, let bytes = Data(base64Encoded: base64),
              !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        return bytes
    }

    static func writeFloatSamples(from bytes: Data, into output: UnsafeMutablePointer<Float>) {
        bytes.withUnsafeBytes { raw in
            let octets = raw.bindMemory(to: UInt8.self)
            for index in 0..<(octets.count / 2) {
                let value = UInt16(octets[index * 2]) | (UInt16(octets[index * 2 + 1]) << 8)
                output[index] = Float(Int16(bitPattern: value)) / 32_768
            }
        }
    }
}

private final class LiveVoiceRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A project key is only for the fixed OpenAI origin.
        completionHandler(nil)
    }
}

private final class LiveVoiceAudio {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: Double(LiveVoiceWire.sampleRate), channels: 1)!
    private var inputTap = false
    private var playbackTap = false

    func start(onInput: @escaping (Data) -> Void, onLevel: @escaping (Double) -> Void) throws -> Bool {
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(true) }
        catch { /* Continue with the hardware's default processing. */ }
        let echoCancellation = input.isVoiceProcessingEnabled
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(LiveVoiceWire.sampleRate),
                                      channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: pcm) else {
            throw CocoaError(.featureUnsupported)
        }
        converter.downmix = true
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            let frames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * pcm.sampleRate / inputFormat.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if consumed {
                    state.pointee = .noDataNow
                    return nil
                }
                consumed = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
            onInput(Data(bytes: samples, count: Int(converted.frameLength) * 2))
        }
        inputTap = true
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var power = 0.0
            for sample in UnsafeBufferPointer(start: samples, count: count) {
                power += Double(sample) * Double(sample)
            }
            onLevel(min(1, sqrt(power / Double(count)) * 3))
        }
        playbackTap = true
        engine.prepare()
        try engine.start()
        player.play()
        return echoCancellation
    }

    func stop() {
        player.stop()
        engine.stop()
        if inputTap {
            engine.inputNode.removeTap(onBus: 0)
            inputTap = false
        }
        if playbackTap {
            player.removeTap(onBus: 0)
            playbackTap = false
        }
    }

    deinit { stop() }
}

@MainActor
final class LiveVoiceTransport {
    enum Status: Equatable {
        case connecting, ready, closing, closed
        case failed(String)
    }

    var onStatus: ((Status) -> Void)?
    /// Server control, transcript, delegation and usage events. Audio is played here.
    var onEvent: (([String: Any]) -> Void)?
    /// Rendered output RMS, normalized for the display, in the range 0...1.
    var onLevel: ((Double) -> Void)?
    private(set) var status: Status = .closed
    private(set) var echoCancellationEnabled = false

    private struct Outgoing {
        let json: String
        let pcmBytes: Int
    }

    private var generation = UUID()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var audio: LiveVoiceAudio?
    private var audioObserver: NSObjectProtocol?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private var pending: [Outgoing] = []
    private var pendingPCMBytes = 0
    private var queuedPlaybackFrames = 0
    private var playbackGeneration = UUID()

    func start(apiKey: String, instructions: String, voice: String) {
        guard socket == nil else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            update(.failed("Добавь действующий ключ OpenAI API в настройках Jarvis."))
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            update(.failed("Разреши Jarvis доступ к микрофону в настройках macOS."))
            return
        }
        let voiceName = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        generation = id
        var request = URLRequest(url: LiveVoiceWire.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let client = URLSession(configuration: configuration, delegate: LiveVoiceRedirectGuard(), delegateQueue: nil)
        let task = client.webSocketTask(with: request)
        task.maximumMessageSize = 1_000_000
        session = client
        socket = task
        update(.connecting)
        guard generation == id else { return }

        task.resume()
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, self.generation == id else { return }
                    if case .string(let json) = message, let event = LiveVoiceWire.decode(json) {
                        self.handle(event, id: id)
                    }
                } catch {
                    guard let self, self.generation == id else { return }
                    self.terminate(.failed(self.connectionError(task)))
                    return
                }
            }
        }
        setDeadline(seconds: 15, id: id, message: "GPT-Live не подтвердил запуск сеанса.")
        enqueue(LiveVoiceWire.sessionStart(instructions: instructions, voice: voiceName.isEmpty ? "marin" : voiceName,
                                          eventID: "start_\(id.uuidString)"))
    }

    func send(_ event: [String: Any]) {
        guard status == .ready else { return }
        enqueue(event)
    }

    func close() {
        switch status {
        case .connecting:
            cancel()
        case .ready:
            let id = generation
            update(.closing)
            guard generation == id, status == .closing else { return }
            stopAudio()
            pending.removeAll()
            pendingPCMBytes = 0
            enqueue(["type": "session.close", "event_id": "close_\(UUID().uuidString)"])
            setDeadline(seconds: 15, id: id, message: "Соединение закрыто без подтверждения итогового использования GPT-Live.")
        case .closing, .closed, .failed:
            break
        }
    }

    /// Abort pending connection or playback immediately. A cancel has no server finalization guarantee.
    func cancel() {
        guard socket != nil else { return }
        terminate(.closed)
    }

    private func update(_ state: Status) {
        status = state
        onStatus?(state)
    }

    private func setDeadline(seconds: TimeInterval, id: UUID, message: String) {
        deadline?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == id else { return }
            self.terminate(.failed(message))
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func enqueue(_ event: [String: Any], pcmBytes: Int = 0) {
        guard let task = socket, let json = LiveVoiceWire.encode(event) else { return }
        // Slow sends must not turn live input into an ever-growing recording.
        guard pending.count < 128, pendingPCMBytes + pcmBytes <= LiveVoiceWire.sampleRate * 2 else {
            terminate(.failed("Связь с GPT-Live не успевает передавать звук."))
            return
        }
        pending.append(Outgoing(json: json, pcmBytes: pcmBytes))
        pendingPCMBytes += pcmBytes
        guard sender == nil else { return }
        let id = generation
        sender = Task { [weak self] in
            while !Task.isCancelled {
                guard let next = self?.dequeue(id: id) else { return }
                do { try await task.send(.string(next.json)) }
                catch {
                    guard let self, self.generation == id else { return }
                    self.terminate(.failed(self.connectionError(task)))
                    return
                }
            }
        }
    }

    private func dequeue(id: UUID) -> Outgoing? {
        guard generation == id else { return nil }
        guard !pending.isEmpty else { sender = nil; return nil }
        let next = pending.removeFirst()
        pendingPCMBytes -= next.pcmBytes
        return next
    }

    private func handle(_ event: [String: Any], id: UUID) {
        switch event["type"] as? String {
        case "session.started":
            guard status == .connecting else { return }
            deadline?.cancel()
            deadline = nil
            do { try startAudio(id: id) }
            catch {
                terminate(.failed("Не удалось запустить микрофон и звук GPT-Live. Проверь аудиоустройства Mac."))
                return
            }
            update(.ready)
            if generation == id { onEvent?(event) }
        case "session.output_audio.delta":
            guard status == .ready, let bytes = LiveVoiceWire.outputAudio(event) else { return }
            play(bytes, id: id)
        case "session.closed":
            onEvent?(event)
            if generation == id { terminate(.closed) }
        case "error", "transport.failed":
            let original = event["error"] as? [String: Any] ?? [:]
            let code = safeIdentifier(original["code"]) ?? "unknown_error"
            let message = safeErrorMessage(code)
            var diagnostic = ["code": code, "message": message]
            diagnostic["client_event_id"] = safeIdentifier(original["client_event_id"] ?? event["client_event_id"])
            if code.contains("moderation") || code.contains("safety") { clearPlayback() }
            onEvent?(["type": event["type"] as? String ?? "error", "error": diagnostic])
            if generation == id, status == .connecting || event["type"] as? String == "transport.failed" {
                terminate(.failed(message))
            }
        default:
            onEvent?(event)
        }
    }

    private func startAudio(id: UUID) throws {
        let device = LiveVoiceAudio()
        audio = device
        echoCancellationEnabled = try device.start(onInput: { [weak self] bytes in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.status == .ready,
                      let event = LiveVoiceWire.inputAudio(bytes) else { return }
                self.enqueue(event, pcmBytes: bytes.count)
            }
        }, onLevel: { [weak self] level in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.status == .ready else { return }
                self.onLevel?(level)
            }
        })
        audioObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: device.engine, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.status == .ready else { return }
                self.terminate(.failed("Аудиоустройство изменилось. Запусти разговор GPT-Live снова."))
            }
        }
    }

    private func play(_ bytes: Data, id: UUID) {
        guard let audio else { return }
        let frameCount = bytes.count / 2
        guard queuedPlaybackFrames + frameCount <= LiveVoiceWire.sampleRate * 4 else {
            terminate(.failed("Буфер звука GPT-Live переполнен. Запусти разговор снова."))
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        LiveVoiceWire.writeFloatSamples(from: bytes, into: samples)
        queuedPlaybackFrames += frameCount
        let playbackID = playbackGeneration
        audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.playbackGeneration == playbackID else { return }
                self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - frameCount)
                if self.queuedPlaybackFrames == 0 { self.onLevel?(0) }
            }
        }
    }

    private func clearPlayback() {
        playbackGeneration = UUID()
        queuedPlaybackFrames = 0
        if let audio {
            audio.player.stop()
            if audio.engine.isRunning { audio.player.play() }
        }
        onLevel?(0)
    }

    private func stopAudio() {
        if let audioObserver {
            NotificationCenter.default.removeObserver(audioObserver)
            self.audioObserver = nil
        }
        playbackGeneration = UUID()
        queuedPlaybackFrames = 0
        audio?.stop()
        audio = nil
        echoCancellationEnabled = false
        onLevel?(0)
    }

    private func terminate(_ finalStatus: Status) {
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        receiver?.cancel()
        receiver = nil
        sender?.cancel()
        sender = nil
        pending.removeAll()
        pendingPCMBytes = 0
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        stopAudio()
        update(finalStatus)
    }

    private func connectionError(_ task: URLSessionWebSocketTask) -> String {
        let code = (task.response as? HTTPURLResponse)?.statusCode
        switch code {
        case 401, 403: return "OpenAI отклонил доступ к GPT-Live. Проверь ключ API и доступ проекта к модели."
        case 429: return "OpenAI ограничил запрос к GPT-Live. Проверь квоту и лимиты проекта."
        default: return "Соединение с GPT-Live завершилось без подтверждения. Проверь сеть и попробуй снова."
        }
    }

    private func safeIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 120,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return value
    }

    private func safeErrorMessage(_ code: String) -> String {
        if code.contains("quota") || code.contains("rate_limit") {
            return "GPT-Live недоступен из-за лимита проекта OpenAI."
        }
        if code.contains("model") || code.contains("permission") || code.contains("api_key") {
            return "OpenAI отклонил настройки GPT-Live. Проверь ключ и доступ проекта к модели."
        }
        if code.contains("safety") || code.contains("moderation") {
            return "GPT-Live остановил текущую реплику."
        }
        return "GPT-Live отклонил команду сеанса."
    }
}
