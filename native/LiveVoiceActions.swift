import AppKit
import AVFoundation
import Foundation

struct LiveVoiceTranscript {
    struct Turn {
        let role: String
        var content: String
        let start: Int
        var end: Int

        var message: [String: String] { ["role": role, "content": content] }
    }

    private var fragments: [Turn] = []
    private(set) var lastUserFragmentAt = -Double.infinity

    mutating func append(_ event: [String: Any], receivedAt: Double) -> Bool {
        let role: String
        switch event["type"] as? String {
        case "session.input_transcript.delta": role = "user"
        case "session.output_transcript.delta": role = "assistant"
        default: return false
        }
        guard let delta = event["delta"] as? String, !delta.isEmpty,
              let start = event["start_ms"] as? Int, let end = event["end_ms"] as? Int,
              start >= 0, end >= start, end < 100_000_000 else { return false }
        fragments.append(Turn(role: role, content: String(delta.prefix(1200)), start: start, end: end))
        if fragments.count > 480 { fragments.removeFirst(fragments.count - 480) }
        if role == "user" { lastUserFragmentAt = receivedAt }
        return true
    }

    func turns(upTo offset: Int = .max) -> [Turn] {
        // The two speakers have independent audio timelines and can overlap.
        var lanes: [String: [Turn]] = [:]
        for fragment in fragments.filter({ $0.start <= offset }).sorted(by: { $0.start < $1.start }) {
            var lane = lanes[fragment.role, default: []]
            if let last = lane.indices.last, fragment.start <= lane[last].end + 950 {
                lane[last].content += fragment.content
                lane[last].end = max(lane[last].end, fragment.end)
            } else {
                lane.append(fragment)
            }
            lanes[fragment.role] = lane
        }
        return lanes.values.flatMap { $0 }.sorted { ($0.start, $0.role) < ($1.start, $1.role) }
    }

    func request(at offset: Int) -> [String: Any]? {
        let context = turns(upTo: offset + 1200)
        guard let index = context.lastIndex(where: { $0.role == "user" && $0.end + 15_000 >= offset }) else { return nil }
        let question = context[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return nil }
        let history = context.prefix(index).suffix(6).map {
            ["role": $0.role, "content": String($0.content.suffix(1600))]
        }
        return ["question": String(question.suffix(2800)), "history": history]
    }
}

extension AppDelegate {
    func startChosenConversation() {
        if profile.conversation_mode == "gpt-live-1" { startLiveVoice() }
        else { startConversation() }
    }

    func stopActiveConversation(immediate: Bool = false) {
        if liveVoiceRunID != nil { stopLiveVoice(immediate: immediate) }
        else { stopConversation() }
    }

    func clearOpenAIKey() {
        do {
            try CreatorKeychain.remove(kind: .openAI)
            sendProfile(saved: true)
        } catch { sendProfile(error: error.localizedDescription) }
    }

    private func startLiveVoice() {
        guard !conversationActive else { return }
        guard assistantAvailable else {
            sendAssistant(["state": "error", "error": "Дождись окончания текущей озвучки или запроса."])
            return
        }
        guard let key = CreatorKeychain.read(kind: .openAI), !key.isEmpty else {
            sendAssistant(["state": "error", "error": "Добавь API-ключ OpenAI в настройках голоса Jarvis."])
            return
        }
        let runID = UUID()
        liveVoiceRunID = runID
        liveVoiceClosing = false
        liveTranscript = LiveVoiceTranscript()
        liveRecommendation = ""
        liveVoiceOutputLevel = 0
        liveDelegationIDs.removeAll()
        sendLiveTranscript()
        conversationActive = true
        if armed {
            resumeClaps = true
            setArmed(false)
        }
        sendAssistant(["state": "connecting", "voiceProvider": "gpt-live-1", "liveMode": true])
        broadcast()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            connectLiveVoice(apiKey: key, runID: runID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                Task { @MainActor in
                    guard let self = self, self.liveVoiceRunID == runID else { return }
                    if allowed { self.connectLiveVoice(apiKey: key, runID: runID) }
                    else { self.finishLiveVoice(error: "Разреши доступ к микрофону в настройках macOS.") }
                }
            }
        default:
            finishLiveVoice(error: "Разреши доступ к микрофону в настройках macOS.")
        }
    }

    private func connectLiveVoice(apiKey: String, runID: UUID) {
        let transport = LiveVoiceTransport()
        liveVoiceTransport = transport
        transport.onStatus = { [weak self] status in
            guard let self = self, self.liveVoiceRunID == runID else { return }
            switch status {
            case .connecting: break
            case .ready:
                self.sendAssistant(["state": "listening", "voiceProvider": "gpt-live-1", "liveMode": true])
            case .closing:
                self.sendAssistant(["state": "closing", "voiceProvider": "gpt-live-1", "liveMode": true])
            case .closed:
                self.finishLiveVoice()
            case .failed(let reason):
                self.finishLiveVoice(error: reason)
            }
        }
        transport.onEvent = { [weak self] event in
            guard let self = self, self.liveVoiceRunID == runID, !self.liveVoiceClosing else { return }
            self.receiveLiveVoiceEvent(event, runID: runID)
        }
        transport.onLevel = { [weak self] rms in
            guard let self = self, self.liveVoiceRunID == runID, !self.liveVoiceClosing else { return }
            self.liveVoiceOutputLevel = min(1, max(0, rms * 3.2))
            self.updateLiveVoiceActivity()
        }
        transport.start(apiKey: apiKey, instructions: """
            Ты Jarvis Creator, голосовой помощник русскоязычного автора контента. Говори по-русски,
            естественно и коротко. Слушай поправки и уступай, когда собеседник перебивает.
            Приветствия и простые уточнения отвечай сам. Вопросы, которым нужны данные аккаунтов,
            идеи и планы для проекта, монтаж, публикация, организация съёмок вживую, продюсирование Reels,
            автоматизация на ИИ, воронки, автоответы, MHS Labs или Telegram Лео,
            передавай выбранному в приложении помощнику через клиентское делегирование.
            Не придумывай данные и не утверждай, что выполнил действие без подтверждённого результата.
            Вопросы про MHS Labs и контакт Лео делегируй, чтобы Jarvis мог показать ссылку в чате.
            Не говори, что ссылка показана, пока не получишь подтверждение от помощника.
            """, voice: "marin")
    }

    private func updateLiveVoiceActivity() {
        guard liveVoiceTransport != nil, !liveVoiceClosing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if liveVoiceOutputLevel > 0.018 { liveVoiceLastOutputAt = now }
        let speaking = now - liveVoiceLastOutputAt < 0.22
        guard speaking != liveVoiceSpeaking else { return }
        liveVoiceSpeaking = speaking
        let next = speaking ? "speaking" : liveDelegations.isEmpty ? "listening" : "thinking"
        sendAssistant(["state": next, "voiceProvider": "gpt-live-1", "liveMode": true])
    }

    private func receiveLiveVoiceEvent(_ event: [String: Any], runID: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        if liveTranscript.append(event, receivedAt: now) {
            guard liveTranscriptUpdate == nil else { return }
            let update = DispatchWorkItem { [weak self] in
                guard let self = self, self.liveVoiceRunID == runID else { return }
                self.liveTranscriptUpdate = nil
                self.sendLiveTranscript()
            }
            liveTranscriptUpdate = update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: update)
            return
        }

        guard event["type"] as? String == "session.delegation.created",
              let delegation = event["delegation"] as? [String: Any],
              delegation["target"] as? String == "client",
              let id = delegation["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let offset = event["offset_ms"] as? Int, (0..<100_000_000).contains(offset),
              liveDelegationIDs.count < 160, liveDelegationIDs.insert(id).inserted else { return }

        // Transcripts may arrive just after the delegation event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.runLiveDelegation(id: id, offset: offset, runID: runID, retries: 2)
        }
    }

    private func runLiveDelegation(id: String, offset: Int, runID: UUID, retries: Int) {
        guard liveVoiceRunID == runID, !liveVoiceClosing, let transport = liveVoiceTransport else { return }
        guard liveDelegations.count < 2 else {
            sendLiveResult("Два запроса уже в работе. Дождись ответа и повтори следующий вопрос.", id: id, through: transport)
            return
        }
        let request = liveTranscript.request(at: offset)
        if retries > 0, request == nil || ProcessInfo.processInfo.systemUptime - liveTranscript.lastUserFragmentAt < 0.38 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.runLiveDelegation(id: id, offset: offset, runID: runID, retries: retries - 1)
            }
            return
        }
        guard let request = request else {
            sendLiveResult("Попроси повторить вопрос. Я не разобрал реплику целиком.", id: id, through: transport)
            return
        }

        if !liveVoiceSpeaking { sendAssistant(["state": "thinking", "voiceProvider": "gpt-live-1", "liveMode": true]) }
        let job = commands.run("creator.py", arguments: ["ask", "--json"], input: request, timeout: 100) { [weak self, weak transport] result in
            guard let self = self, let transport = transport, self.liveVoiceRunID == runID, !self.liveVoiceClosing else { return }
            self.liveDelegations.removeValue(forKey: id)
            if !self.liveVoiceSpeaking && self.liveDelegations.isEmpty {
                self.sendAssistant(["state": "listening", "voiceProvider": "gpt-live-1", "liveMode": true])
            }
            guard let answer = try? result.get(), answer["ok"] as? Bool == true,
                  let reply = answer["reply"] as? String, !reply.isEmpty else {
                self.sendLiveResult("Помощник не ответил. Проверь вход в Codex или Claude Code и повтори вопрос.", id: id, through: transport)
                return
            }
            if let recommendation = answer["recommendation"] as? String, creatorRecommendations.contains(recommendation) {
                self.liveRecommendation = recommendation
                self.sendLiveTranscript()
            }
            self.sendLiveResult(reply, id: id, through: transport)
        }
        if let job = job { liveDelegations[id] = job }
    }

    private func sendLiveResult(_ content: String, id: String, through transport: LiveVoiceTransport) {
        transport.send(["type": "session.commentary.append", "event_id": "jarvis_\(UUID().uuidString)",
                        "delegation_id": id, "content": String(content.prefix(1100))])
    }

    private func sendLiveTranscript() {
        let turns = liveTranscript.turns().suffix(8).map {
            ["role": $0.role, "content": String($0.content.suffix(1500))]
        }
        send("jarvisLiveTranscript", ["turns": turns, "recommendation": liveRecommendation])
    }

    private func stopLiveVoice(immediate: Bool) {
        guard liveVoiceRunID != nil else { return }
        for job in liveDelegations.values { commands.cancel(job) }
        liveDelegations.removeAll()
        if immediate || liveVoiceTransport == nil {
            finishLiveVoice()
            return
        }
        guard !liveVoiceClosing else { return }
        liveVoiceClosing = true
        liveVoiceTransport?.close()
    }

    private func finishLiveVoice(error: String? = nil) {
        guard liveVoiceRunID != nil else { return }
        liveVoiceRunID = nil
        liveVoiceClosing = false
        liveVoiceOutputLevel = 0
        liveVoiceLastOutputAt = -.infinity
        liveVoiceSpeaking = false
        liveTranscriptUpdate?.cancel()
        liveTranscriptUpdate = nil
        for job in liveDelegations.values { commands.cancel(job) }
        liveDelegations.removeAll()
        let transport = liveVoiceTransport
        liveVoiceTransport = nil
        transport?.cancel()
        conversationActive = false
        restoreClaps()
        sendLiveTranscript()
        var state: [String: Any] = ["state": error == nil ? "ready" : "error", "liveMode": true]
        if let error = error { state["error"] = error }
        sendAssistant(state)
        broadcast()
    }

    func tickLiveVoice() {
        updateLiveVoiceActivity()
    }
}
