import AppKit
import AVFoundation
import CryptoKit
import WebKit

let creatorRecommendations: Set<String> = ["mhs-labs", "leo-creator"]

final class AssistantTextTurn {
    let question: String
    let epoch: UUID
    let voiceID: String
    let key: String
    let history: [[String: String]]
    var draft = ""
    var finalReply: String?
    var provider: String?
    var recommendation: String?
    var cached = false
    var backendEnded = false
    var backendError: String?
    var voiceError: String?
    var fallbackReason: String?
    var playedAny = false
    var speaking = false
    var lastPublished = -Double.infinity
    private(set) var spokenPrefix = ""
    private(set) var clipCount = 0

    init(question: String, epoch: UUID, voiceID: String, key: String, history: [[String: String]]) {
        self.question = question
        self.epoch = epoch
        self.voiceID = voiceID
        self.key = key
        self.history = history
    }

    var reply: String { finalReply ?? draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func safeText(_ value: String) -> String {
        key.isEmpty ? value : value.replacingOccurrences(of: key, with: "скрыто")
    }

    func nextClip() -> String? {
        let text = safeText(reply)
        var source = String(text.prefix(600))
        if text.count > 600, let space = source.lastIndex(where: \.isWhitespace), space >= source.index(source.startIndex, offsetBy: 500) {
            source = String(source[..<space])
        }
        guard source.hasPrefix(spokenPrefix), clipCount < 3 else { return nil }
        let remainder = String(source.dropFirst(spokenPrefix.count))
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let end: String.Index
        if finalReply != nil {
            // A cache hit or fast response fits in one request. Finish any queued text in one clip.
            end = remainder.endIndex
        } else {
            guard clipCount < 2 else { return nil }
            let boundaries = Self.sentenceEnds(in: remainder)
            let minimum = clipCount == 0 ? 36 : 115
            let eligible = boundaries.filter { remainder.distance(from: remainder.startIndex, to: $0) >= minimum }
            guard let boundary = clipCount == 0 ? eligible.first : eligible.last else { return nil }
            end = boundary
        }
        let chunk = String(remainder[..<end])
        spokenPrefix += chunk
        clipCount += 1
        return chunk.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sentenceEnds(in text: String) -> [String.Index] {
        let abbreviations: Set<String> = ["т", "д", "е", "г", "др", "см", "руб", "кг", "мл", "млн"]
        let closingQuotes: Set<Character> = ["»", "”", "\"", ")"]
        return text.indices.compactMap { index in
            let mark = text[index]
            guard ".!?…".contains(mark) else { return nil }
            if mark == "." {
                let token = String(text[..<index].reversed().prefix(while: \.isLetter).reversed()).lowercased()
                if abbreviations.contains(token) { return nil }
            }
            var end = text.index(after: index)
            while end < text.endIndex, closingQuotes.contains(text[end]) { end = text.index(after: end) }
            guard end == text.endIndex || text[end].isWhitespace else { return nil }
            return end
        }
    }
}

extension AppDelegate {
    func send(_ handler: String, _ payload: [String: Any], to web: WKWebView? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.\(handler) && window.\(handler)(\(json))"
        for target in web.map({ [$0] }) ?? stages.map(\.web) {
            target.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func sendProfile(to web: WKWebView? = nil, saved: Bool = false, error: String? = nil) {
        var data = profile.webData
        data["saved"] = saved
        if let error = error { data["error"] = error }
        send("jarvisProfile", data, to: web)
    }

    func saveProfile(_ fields: [String: Any]) {
        var next = CreatorStorage.loadProfile()
        next.apply(fields)
        do {
            if let supplied = fields["live_api_key"] as? String {
                let key = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    guard key.utf8.count <= 2048, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                        throw CreatorError("Проверьте API-ключ OpenAI.")
                    }
                    try CreatorKeychain.save(key, kind: .openAI)
                }
            }
            if let voice = fields["voice"] as? [String: Any], let key = voice["api_key"] as? String {
                let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    guard key.utf8.count <= 2048, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                        throw CreatorError("Проверьте API-ключ ElevenLabs.")
                    }
                    try CreatorKeychain.save(key)
                    next.voice_key_revision = UUID().uuidString
                }
            }
            try CreatorStorage.saveProfile(next)
            profile = next
            profileRevision += 1
            if phase == "idle" || phase == "done", voice?.isPlaying != true, music?.isPlaying != true { loadAudio() }
            sendProfile(saved: true)
            sendStats()
            broadcast()
        } catch { sendProfile(error: error.localizedDescription) }
    }

    func clearVoiceKey() {
        do {
            try CreatorKeychain.remove()
            var next = CreatorStorage.loadProfile()
            next.voice_key_revision = nil
            try CreatorStorage.saveProfile(next)
            profile = next
            profileRevision += 1
            sendProfile(saved: true)
        } catch { sendProfile(error: error.localizedDescription) }
    }

    private func scopedStats() -> [[String: Any]] {
        let existing = statsSnapshot?["stats"] as? [[String: Any]] ?? []
        return CreatorProfile.platformNames.map { platform in
            let enabled = profile.platforms[platform] == true
            if enabled, let item = existing.first(where: { $0["platform"] as? String == platform }) { return item }
            return ["platform": platform, "connected": false,
                    "state": enabled ? "not-connected" : "disabled"]
        }
    }

    func sendStats(to web: WKWebView? = nil, error: String? = nil) {
        var snapshot: [String: Any] = ["stats": scopedStats(), "refreshing": statsBusy]
        if let asOf = statsSnapshot?["as_of"] { snapshot["as_of"] = asOf }
        if let error = error { snapshot["error"] = error }
        send("jarvisStats", snapshot, to: web)
    }

    func refreshStats() {
        guard !statsBusy else { return }
        statsBusy = true
        sendStats()
        broadcast()
        commands.run("creator.py", arguments: ["stats", "--refresh"], timeout: 90) { [weak self] result in
            guard let self = self else { return }
            self.statsBusy = false
            switch result {
            case .success(let snapshot):
                guard snapshot["stats"] is [[String: Any]] else {
                    self.sendStats(error: "Не удалось прочитать статистику."); self.broadcast(); return
                }
                self.statsSnapshot = snapshot
                self.sendStats()
            case .failure(let error): self.sendStats(error: error.localizedDescription)
            }
            self.broadcast()
        }
    }

    private func voiceOptions() -> [String: String] {
        var options = ["provider": profile.voice.provider, "voice_id": profile.voice.voice_id]
        if profile.voice.provider == "elevenlabs", let key = CreatorKeychain.read() { options["api_key"] = key }
        return options
    }

    func briefingFingerprint() -> String {
        let values: [String: Any] = ["name": profile.name, "platforms": profile.platforms,
                                     "voiceProvider": profile.voice.provider, "voiceID": profile.voice.voice_id,
                                     "keyRevision": profile.voice_key_revision ?? "", "stats": scopedStats(),
                                     "asOf": statsSnapshot?["as_of"] ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func prepareBriefing(thenStart source: String? = nil) {
        guard !preparing, !assistantBusy, !listening, !conversationActive, phase == "idle" || phase == "done" else { return }
        let fingerprint = briefingFingerprint()
        do { try CreatorStorage.prepareDirectory() }
        catch {
            send("jarvisPrepared", ["state": "error", "error": error.localizedDescription])
            if let source = source { failedAutoPreparation = fingerprint; start(source: source, allowPreparation: false) }
            return
        }
        preparing = true
        broadcast()
        send("jarvisPrepared", ["state": "preparing"])
        let output = CreatorStorage.root.appendingPathComponent("briefing-\(UUID().uuidString).wav")
        let revision = profileRevision
        let scripts = CreatorStorage.readObject(webRoot.appendingPathComponent("scripts.json"))
        let scriptCount = (scripts?["items"] as? [Any])?.count ?? 0
        let request: [String: Any] = ["name": profile.name, "stats": scopedStats(),
                                      "scripts_count": scriptCount, "voice": voiceOptions()]
        commands.run("voice.py", arguments: ["--output", output.path], input: request) { [weak self] result in
            guard let self = self else { return }
            var committed = false
            defer {
                self.preparing = false
                self.broadcast()
                if !committed { try? self.fm.removeItem(at: output) }
                if let source = source { self.start(source: source, allowPreparation: false) }
            }
            do {
                let metadata = try result.get()
                guard revision == self.profileRevision, fingerprint == self.briefingFingerprint() else {
                    throw CreatorError("Профиль или статистика изменились. Подготовьте отчёт ещё раз.")
                }
                guard let player = try? AVAudioPlayer(contentsOf: output), player.duration > 0 else {
                    throw CreatorError("Не удалось открыть подготовленный звук.")
                }
                let marker: [String: Any] = ["fingerprint": fingerprint, "audioFile": output.lastPathComponent,
                                             "sideRevealSeconds": metadata["sideRevealSeconds"] as? Double ?? 1.416]
                let data = try JSONSerialization.data(withJSONObject: marker)
                let previous = CreatorStorage.briefingURL(CreatorStorage.readObject(CreatorStorage.briefingMetadataURL))
                try data.write(to: CreatorStorage.briefingMetadataURL, options: .atomic)
                committed = true
                if let previous = previous { try? self.fm.removeItem(at: previous) }
                self.failedAutoPreparation = nil
                self.loadAudio()
                var state: [String: Any] = ["state": "ready", "durationSeconds": player.duration,
                                            "provider": metadata["provider"] as? String ?? "system"]
                if let fallback = metadata["fallbackReason"] as? String { state["fallbackReason"] = fallback }
                self.send("jarvisPrepared", state)
            } catch {
                if source != nil { self.failedAutoPreparation = fingerprint }
                self.send("jarvisPrepared", ["state": "error", "error": error.localizedDescription])
            }
        }
    }

    var assistantAvailable: Bool {
        (phase == "idle" || phase == "done") && !assistantBusy && !listening && !preparing
            && voice?.isPlaying != true && music?.isPlaying != true && assistantVoice?.isPlaying != true
    }

    func sendAssistant(_ fields: [String: Any]) {
        var state = fields
        state["conversationActive"] = conversationActive
        if state["provider"] == nil { state["provider"] = profile.assistant_provider }
        send("jarvisAssistant", state)
        if diagnosticsEnabled && state["transcript"] == nil { writeState() }
    }

    func startConversation() {
        guard !conversationActive else { return }
        guard assistantAvailable else {
            sendAssistant(["state": "error", "error": "Дождись окончания текущей озвучки или запроса."])
            return
        }
        assistantEpoch = UUID()
        conversationActive = true
        beginSpeech()
    }

    func stopConversation() {
        assistantEpoch = UUID()
        conversationActive = false
        listening = false
        finishingSpeech = false
        assistantBusy = false
        silenceDeadline?.cancel()
        silenceDeadline = nil
        speech.cancel()
        commands.cancel(assistantJob)
        assistantJob = nil
        commands.cancel(assistantAgentJob)
        assistantAgentJob = nil
        assistantTextTurn = nil
        assistantStream?.cancel()
        assistantStream = nil
        assistantVoice?.stop()
        assistantVoice = nil
        assistantSpokenReply = nil
        if let file = assistantAudioFile { try? fm.removeItem(at: file) }
        assistantAudioFile = nil
        restoreClaps()
        sendAssistant(["state": "ready"])
    }

    func restoreClaps() {
        guard resumeClaps, !conversationActive, !listening else { return }
        resumeClaps = false
        setArmed(true)
    }

    func beginSpeech() {
        guard assistantAvailable else {
            sendAssistant(["state": "error", "error": "Дождись окончания текущей озвучки или запроса."])
            return
        }
        let epoch = assistantEpoch
        listening = true
        finishingSpeech = false
        lastPartialTranscript = ""
        if armed {
            resumeClaps = true
            setArmed(false)
        }
        sendAssistant(["state": "listening"])
        speech.start(onTranscript: { [weak self] transcript in
            guard let self = self, self.assistantEpoch == epoch, self.listening, !self.finishingSpeech else { return }
            self.sendAssistant(["state": "listening", "transcript": transcript])
            guard self.conversationActive, !transcript.isEmpty, transcript != self.lastPartialTranscript else { return }
            self.lastPartialTranscript = transcript
            self.silenceDeadline?.cancel()
            let pause = DispatchWorkItem { [weak self] in
                guard let self = self, self.assistantEpoch == epoch, self.conversationActive else { return }
                self.endSpeech()
            }
            self.silenceDeadline = pause
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: pause)
        }, onEnded: { [weak self] result in
            guard let self = self, self.assistantEpoch == epoch else { return }
            self.silenceDeadline?.cancel()
            self.silenceDeadline = nil
            self.listening = false
            self.finishingSpeech = false
            switch result {
            case .success(let transcript):
                self.restoreClaps()
                self.ask(["question": transcript])
            case .failure(let error):
                self.conversationActive = false
                self.restoreClaps()
                self.sendAssistant(["state": "error", "error": error.localizedDescription])
            }
        })
    }

    func endSpeech() {
        guard listening, !finishingSpeech else { return }
        finishingSpeech = true
        silenceDeadline?.cancel()
        silenceDeadline = nil
        sendAssistant(["state": "transcribing"])
        speech.finish()
    }

    func ask(_ request: [String: Any]) {
        guard assistantAvailable else { return }
        let question = (request["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 4000 else {
            conversationActive = false
            restoreClaps()
            sendAssistant(["state": "error", "error": "Введите вопрос длиной до 4000 символов."])
            return
        }
        let history = (request["history"] as? [[String: String]] ?? assistantHistory).suffix(12).compactMap { item -> [String: String]? in
            guard let role = item["role"], ["user", "assistant"].contains(role), let text = item["content"] else { return nil }
            return ["role": role, "content": String(text.prefix(4000))]
        }
        let input: [String: Any] = ["question": question, "history": history]
        let epoch = assistantEpoch
        assistantBusy = true
        sendAssistant(["state": "thinking", "transcript": question])
        if profile.voice.provider == "elevenlabs", let key = CreatorKeychain.read(),
           StreamingSpeech.elevenLabsRequest(text: "Проверка", voiceID: profile.voice.voice_id, apiKey: key) != nil {
            let turn = AssistantTextTurn(question: question, epoch: epoch, voiceID: profile.voice.voice_id, key: key, history: history)
            startTextTurn(turn, input: input)
            return
        }
        assistantJob = commands.run("creator.py", arguments: ["ask", "--json"], input: input, timeout: 120) { [weak self] result in
            guard let self = self, self.assistantEpoch == epoch else { return }
            self.assistantJob = nil
            do {
                let payload = try result.get()
                guard payload["ok"] as? Bool == true, let reply = payload["reply"] as? String, !reply.isEmpty else {
                    throw CreatorError("Ассистент вернул пустой ответ.")
                }
                self.assistantHistory = Array((history + [["role": "user", "content": question],
                                                          ["role": "assistant", "content": reply]]).suffix(12))
                self.speakReply(String(reply.prefix(5000)), transcript: question,
                                recommendation: payload["recommendation"] as? String, epoch: epoch)
            } catch {
                self.assistantBusy = false
                self.conversationActive = false
                self.restoreClaps()
                self.sendAssistant(["state": "error", "transcript": question, "error": error.localizedDescription])
            }
        }
    }

    private func startTextTurn(_ turn: AssistantTextTurn, input: [String: Any]) {
        assistantTextTurn = turn
        assistantAgentJob = commands.runStream("creator.py", arguments: ["ask", "--stream"], input: input) { [weak self, weak turn] event in
            guard let self = self, let turn = turn, self.assistantTextTurn === turn, self.assistantEpoch == turn.epoch else { return }
            self.receiveTextEvent(event, turn: turn)
        } completion: { [weak self, weak turn] result in
            guard let self = self, let turn = turn, self.assistantTextTurn === turn, self.assistantEpoch == turn.epoch else { return }
            self.assistantAgentJob = nil
            turn.backendEnded = true
            if case .failure(let error) = result, turn.backendError == nil, turn.finalReply == nil {
                turn.backendError = error.localizedDescription
            }
            if turn.finalReply == nil, turn.backendError == nil { turn.backendError = "Ассистент не завершил ответ." }
            self.advanceTextTurn(turn)
        }
    }

    private func receiveTextEvent(_ event: [String: Any], turn: AssistantTextTurn) {
        guard turn.finalReply == nil, turn.backendError == nil else { return }
        switch event["type"] as? String {
        case "delta":
            guard let text = event["text"] as? String, !text.isEmpty else { return }
            turn.draft += text
            publishTextTurn(turn, force: false)
        case "final":
            guard event["ok"] as? Bool == true, let reply = event["reply"] as? String, !reply.isEmpty else {
                turn.backendError = "Ассистент вернул пустой ответ."
                return
            }
            turn.finalReply = reply
            turn.provider = event["provider"] as? String
            if let recommendation = event["recommendation"] as? String, creatorRecommendations.contains(recommendation) {
                turn.recommendation = recommendation
            }
            turn.cached = event["cached"] as? Bool == true
            assistantHistory = Array((turn.history + [["role": "user", "content": turn.question],
                                                       ["role": "assistant", "content": turn.safeText(reply)]]).suffix(12))
            publishTextTurn(turn)
        case "error":
            turn.backendError = (event["error"] as? String).map { String($0.prefix(1000)) } ?? "Ассистент не завершил ответ."
        default: return
        }
        advanceTextTurn(turn)
    }

    private func publishTextTurn(_ turn: AssistantTextTurn, force: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - turn.lastPublished >= 0.07 else { return }
        turn.lastPublished = now
        var state: [String: Any] = ["state": turn.speaking ? "speaking" : "streaming",
                                    "reply": turn.safeText(turn.reply), "transcript": turn.question]
        if turn.speaking {
            state["voiceProvider"] = "elevenlabs"
            state["voiceStreaming"] = true
        }
        if let provider = turn.provider { state["provider"] = provider }
        if let recommendation = turn.recommendation { state["recommendation"] = recommendation }
        if turn.cached { state["cached"] = true }
        sendAssistant(state)
    }

    private func advanceTextTurn(_ turn: AssistantTextTurn) {
        guard assistantTextTurn === turn, assistantEpoch == turn.epoch, assistantStream == nil else { return }
        if turn.backendError == nil, turn.voiceError == nil, turn.fallbackReason == nil, let text = turn.nextClip() {
            if let request = StreamingSpeech.elevenLabsRequest(text: text, voiceID: turn.voiceID, apiKey: turn.key) {
                playTextClip(request, turn: turn)
                return
            }
            turn.fallbackReason = "elevenlabs_not_configured"
        }
        guard turn.backendEnded else { return }
        assistantTextTurn = nil
        let reply = turn.safeText(turn.reply)
        if let error = turn.backendError {
            assistantBusy = false
            conversationActive = false
            restoreClaps()
            sendAssistant(["state": "error", "reply": reply, "transcript": turn.question, "error": error])
        } else if let fallback = turn.fallbackReason, !turn.playedAny {
            sendAssistant(["state": "voicing", "reply": reply, "transcript": turn.question])
            speakBufferedReply(reply, transcript: turn.question, epoch: turn.epoch, options: ["provider": "system"], fallbackReason: fallback)
        } else {
            completeAssistantReply(reply, transcript: turn.question, error: turn.voiceError)
        }
    }

    private func playTextClip(_ request: URLRequest, turn: AssistantTextTurn) {
        let stream = StreamingSpeech(request: request, onStarted: { [weak self, weak turn] in
            guard let self = self, let turn = turn, self.assistantTextTurn === turn, self.assistantEpoch == turn.epoch else { return }
            turn.playedAny = true
            turn.speaking = true
            self.publishTextTurn(turn)
        }, onFinished: { [weak self, weak turn] outcome in
            guard let self = self, let turn = turn, self.assistantTextTurn === turn, self.assistantEpoch == turn.epoch else { return }
            self.assistantStream = nil
            turn.speaking = false
            if case .failed(let afterPlayback) = outcome {
                turn.playedAny = turn.playedAny || afterPlayback
                if turn.playedAny { turn.voiceError = "Поток ElevenLabs прервался. Полный ответ остался в чате." }
                else { turn.fallbackReason = "elevenlabs_unavailable" }
            }
            self.publishTextTurn(turn)
            self.advanceTextTurn(turn)
        })
        assistantStream = stream
        stream.start()
    }

    private func speakReply(_ reply: String, transcript: String, recommendation: String?, epoch: UUID) {
        let options = voiceOptions()
        let reply = options["api_key"].flatMap { key in
            key.isEmpty ? nil : reply.replacingOccurrences(of: key, with: "скрыто")
        } ?? reply
        var voicing: [String: Any] = ["state": "voicing", "reply": reply, "transcript": transcript]
        if let recommendation, creatorRecommendations.contains(recommendation) {
            voicing["recommendation"] = recommendation
        }
        sendAssistant(voicing)
        guard options["provider"] == "elevenlabs" else {
            speakBufferedReply(reply, transcript: transcript, epoch: epoch, options: options)
            return
        }
        guard let voiceID = options["voice_id"], let key = options["api_key"],
              let request = StreamingSpeech.elevenLabsRequest(text: reply, voiceID: voiceID, apiKey: key) else {
            speakBufferedReply(reply, transcript: transcript, epoch: epoch, options: ["provider": "system"],
                               fallbackReason: "elevenlabs_not_configured")
            return
        }
        let stream = StreamingSpeech(request: request, onStarted: { [weak self] in
            guard let self = self, self.assistantEpoch == epoch else { return }
            self.sendAssistant(["state": "speaking", "reply": reply, "transcript": transcript,
                                "voiceProvider": "elevenlabs", "voiceStreaming": true])
        }, onFinished: { [weak self] outcome in
            guard let self = self, self.assistantEpoch == epoch else { return }
            self.assistantStream = nil
            switch outcome {
            case .finished:
                self.completeAssistantReply(reply, transcript: transcript)
            case .failed(afterPlayback: true):
                self.completeAssistantReply(reply, transcript: transcript,
                                            error: "Поток ElevenLabs прервался. Полный ответ остался в чате.")
            case .failed(afterPlayback: false):
                self.speakBufferedReply(reply, transcript: transcript, epoch: epoch, options: ["provider": "system"],
                                        fallbackReason: "elevenlabs_unavailable")
            }
        })
        assistantStream = stream
        stream.start()
    }

    private func speakBufferedReply(_ reply: String, transcript: String, epoch: UUID, options: [String: String],
                                    fallbackReason: String? = nil) {
        let output = fm.temporaryDirectory.appendingPathComponent("jarvis-creator-\(UUID().uuidString).wav")
        assistantJob = commands.run("voice.py", arguments: ["--output", output.path], input: ["reply": reply, "voice": options]) { [weak self] result in
            guard let self = self, self.assistantEpoch == epoch else {
                try? FileManager.default.removeItem(at: output)
                return
            }
            self.assistantJob = nil
            do {
                let metadata = try result.get()
                let audio = try AVAudioPlayer(contentsOf: output)
                audio.delegate = self
                audio.isMeteringEnabled = true
                guard audio.play() else { throw CreatorError("Не удалось воспроизвести ответ.") }
                self.assistantVoice = audio
                self.assistantAudioFile = output
                self.assistantSpokenReply = (transcript, reply)
                var speaking: [String: Any] = ["state": "speaking", "reply": reply, "transcript": transcript]
                if let provider = metadata["provider"] as? String, ["system", "elevenlabs", "voicestudio"].contains(provider) {
                    speaking["voiceProvider"] = provider
                }
                let fallbackReasons = ["elevenlabs_unavailable", "elevenlabs_not_configured", "voicestudio_unavailable",
                                       "voicestudio_not_ready", "voicestudio_invalid_voice"]
                if let reason = fallbackReason ?? (metadata["fallbackReason"] as? String), fallbackReasons.contains(reason) {
                    speaking["voiceFallbackReason"] = reason
                }
                self.sendAssistant(speaking)
            } catch {
                try? self.fm.removeItem(at: output)
                self.assistantBusy = false
                self.conversationActive = false
                self.restoreClaps()
                self.sendAssistant(["state": "ready", "reply": reply, "transcript": transcript,
                                    "voiceError": error.localizedDescription, "error": error.localizedDescription])
            }
        }
    }

    private func finishAssistantPlayback(_ playerID: ObjectIdentifier, success: Bool) {
        guard let audio = assistantVoice, ObjectIdentifier(audio) == playerID, let spoken = assistantSpokenReply else { return }
        assistantVoice = nil
        assistantSpokenReply = nil
        if let file = assistantAudioFile { try? fm.removeItem(at: file) }
        assistantAudioFile = nil
        completeAssistantReply(spoken.reply, transcript: spoken.transcript,
                               error: success ? nil : "Ответ остался в чате. Проверь выход звука перед продолжением.")
    }

    private func completeAssistantReply(_ reply: String, transcript: String, error: String? = nil) {
        assistantBusy = false
        var state: [String: Any] = ["state": "ready", "reply": reply, "transcript": transcript]
        if let error = error {
            conversationActive = false
            restoreClaps()
            state["error"] = error
        }
        sendAssistant(state)
        guard conversationActive else { return }
        let epoch = assistantEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.conversationActive, self.assistantEpoch == epoch else { return }
            self.beginSpeech()
        }
    }
}

extension AppDelegate: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in self?.finishAssistantPlayback(playerID, success: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in self?.finishAssistantPlayback(playerID, success: false) }
    }
}
