import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechCapture {
    private enum CaptureError: LocalizedError {
        case missingUsageDescription
        case microphonePermission
        case speechPermission
        case offlineRussianUnavailable
        case microphoneUnavailable
        case recognitionFailed
        case noSpeech

        var errorDescription: String? {
            let reason: String
            switch self {
            case .missingUsageDescription:
                reason = "Для голосового ввода откройте приложение Jarvis Creator."
            case .microphonePermission:
                reason = "Разрешите микрофон для Jarvis Creator в настройках конфиденциальности macOS."
            case .speechPermission:
                reason = "Разрешите распознавание речи для Jarvis Creator в настройках конфиденциальности macOS."
            case .offlineRussianUnavailable:
                reason = "Локальное распознавание русского языка недоступно на этом Mac."
            case .microphoneUnavailable:
                reason = "Микрофон недоступен. Проверьте выбранное устройство ввода."
            case .recognitionFailed:
                reason = "Распознавание прервалось."
            case .noSpeech:
                reason = "Не удалось разобрать речь. Попробуйте ещё раз."
            }
            return "\(reason) Можно ввести вопрос текстом."
        }
    }

    private final class Session {
        let id = UUID()
        let onTranscript: (String) -> Void
        let onEnded: (Result<String, Error>) -> Void
        var engine: AVAudioEngine?
        var recognizer: SFSpeechRecognizer?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var configurationObserver: NSObjectProtocol?
        var deadline: DispatchWorkItem?
        var transcript = ""
        var finishing = false

        init(onTranscript: @escaping (String) -> Void, onEnded: @escaping (Result<String, Error>) -> Void) {
            self.onTranscript = onTranscript
            self.onEnded = onEnded
        }

        func stopInput() {
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            if let engine {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                self.engine = nil
            }
        }

        func cleanUp() {
            deadline?.cancel()
            deadline = nil
            stopInput()
            task?.cancel()
            task = nil
            request = nil
            recognizer = nil
        }

        deinit { cleanUp() }
    }

    private var session: Session?
    private let recordingLimit: TimeInterval = 20
    private let finalResultGrace: TimeInterval = 1.2

    func start(onTranscript: @escaping (String) -> Void, onEnded: @escaping (Result<String, Error>) -> Void) {
        guard session == nil else { return }
        let current = Session(onTranscript: onTranscript, onEnded: onEnded)
        session = current
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            end(current, with: .failure(CaptureError.missingUsageDescription))
            return
        }
        let id = current.id
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorizeSpeech(id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, let current = self.session, current.id == id else { return }
                    if allowed { self.authorizeSpeech(id) }
                    else { self.end(current, with: .failure(CaptureError.microphonePermission)) }
                }
            }
        default:
            end(current, with: .failure(CaptureError.microphonePermission))
        }
    }

    func finish() {
        guard let current = session, !current.finishing else { return }
        guard let request = current.request else {
            end(current, with: .failure(CaptureError.noSpeech))
            return
        }
        current.finishing = true
        current.deadline?.cancel()
        current.stopInput()
        request.endAudio()

        let id = current.id
        let wait = DispatchWorkItem { [weak self] in
            guard let self, let active = self.session, active.id == id else { return }
            self.endWithTranscript(active, otherwise: .noSpeech)
        }
        current.deadline = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + finalResultGrace, execute: wait)
    }

    /// Drop pending callbacks and release the microphone without submitting a command.
    func cancel() {
        guard let current = session else { return }
        session = nil
        current.cleanUp()
    }

    private func authorizeSpeech(_ id: UUID) {
        guard let current = session, current.id == id else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginRecording(current)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self, let active = self.session, active.id == id else { return }
                    if status == .authorized { self.beginRecording(active) }
                    else { self.end(active, with: .failure(CaptureError.speechPermission)) }
                }
            }
        default:
            end(current, with: .failure(CaptureError.speechPermission))
        }
    }

    private func beginRecording(_ current: Session) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            end(current, with: .failure(CaptureError.offlineRussianUnavailable))
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            end(current, with: .failure(CaptureError.microphoneUnavailable))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Джарвис", "Jarvis", "Ютуб", "Инстаграм", "Телеграм", "Codex"]
        current.recognizer = recognizer
        current.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
        }
        current.engine = engine
        engine.prepare()
        do { try engine.start() }
        catch {
            end(current, with: .failure(CaptureError.microphoneUnavailable))
            return
        }

        let id = current.id
        current.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let active = self.session, active.id == id, !active.finishing else { return }
                self.endWithTranscript(active, otherwise: .microphoneUnavailable)
            }
        }
        current.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = error != nil
            DispatchQueue.main.async {
                guard let self, let active = self.session, active.id == id else { return }
                if let transcript {
                    let text = String(transcript.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, text != active.transcript {
                        active.transcript = text
                        active.onTranscript(text)
                    }
                }
                if isFinal || failed {
                    self.endWithTranscript(active, otherwise: failed ? .recognitionFailed : .noSpeech)
                }
            }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.session?.id == id else { return }
            self.finish()
        }
        current.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingLimit, execute: deadline)
    }

    private func endWithTranscript(_ current: Session, otherwise error: CaptureError) {
        end(current, with: current.transcript.isEmpty ? .failure(error) : .success(current.transcript))
    }

    private func end(_ current: Session, with result: Result<String, Error>) {
        guard session?.id == current.id else { return }
        session = nil
        current.cleanUp()
        current.onEnded(result)
    }
}
