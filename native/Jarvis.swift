import AppKit
import WebKit
import AVFoundation
import CoreGraphics
import CoreAudio
import AudioToolbox

struct InputDevice {
    let id: AudioDeviceID
    let name: String
    let builtIn: Bool
}

enum InputDevices {
    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value: UInt32=0, size=UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object,&address,0,nil,&size,&value) == noErr ? value : nil
    }
    static func name(_ device: AudioDeviceID) -> String {
        var address=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device,&address,0,nil,&size,&value) == noErr,let value=value else {return "Микрофон \(device)"}
        // CoreAudio transfers ownership of kAudioObjectPropertyName to the caller.
        return value.takeRetainedValue() as String
    }
    static func all() -> [InputDevice] {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size: UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr,size>0 else {return []}
        var devices=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        let status=devices.withUnsafeMutableBufferPointer { buffer in AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,buffer.baseAddress!) }
        guard status == noErr else {return []}
        return devices.compactMap { device in
            var input=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
            var streamSize: UInt32=0
            guard AudioObjectGetPropertyDataSize(device,&input,0,nil,&streamSize) == noErr,streamSize>0 else {return nil}
            return InputDevice(id:device,name:name(device),builtIn:uint32(device,kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn)
        }
    }
    static var defaultID: AudioDeviceID {uint32(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultInputDevice) ?? 0}
}

final class ClapInput {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.leo.jarvis.clap")
    private var detector = ClapDetector()
    private var running = false
    private(set) var deviceName = ""
    private(set) var deviceID: AudioDeviceID = 0
    private(set) var routingNote = ""
    private(set) var sampleRate = 0.0
    var onClap: (() -> Void)?
    var onLevel: ((Double) -> Void)?
    func setSensitivity(_ value: Double) { queue.async { self.detector.sensitivity = max(0.5, min(3, value)) } }
    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let devices=InputDevices.all()
        let preferred=devices.first(where:{$0.builtIn && $0.name.localizedCaseInsensitiveContains("MacBook")}) ?? devices.first(where:{$0.builtIn})
        routingNote=""
        // Change only this engine's HAL input unit; never change system default devices.
        if let preferred=preferred,let unit=input.audioUnit {
            var device=preferred.id
            let status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {routingNote="Выбран системный микрофон (маршрутизация \(status))"}
        } else {routingNote="Используется системный микрофон"}
        deviceID=InputDevices.defaultID
        if let unit=input.audioUnit {
            var current: AudioDeviceID=0, size=UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&current,&size) == noErr {deviceID=current}
        }
        deviceName=devices.first(where:{$0.id == deviceID})?.name ?? InputDevices.name(deviceID)
        let format = input.outputFormat(forBus: 0)
        sampleRate=format.sampleRate
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"]) }
        queue.sync { detector.reset() }
        var analyzer = ClapFrames(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let frames = analyzer.consume(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            guard let level = frames.map(\.rms).max() else { return }
            self.queue.async {
                var hit = false
                for frame in frames { if self.detector.process(frame) { hit = true } }
                let detected = hit
                DispatchQueue.main.async {
                    self.onLevel?(level)
                    if detected { self.onClap?() }
                }
            }
        }
        do { try engine.start(); running = true }
        catch { input.removeTap(onBus: 0); throw error }
    }
    func stop() { if running { engine.stop(); engine.inputNode.removeTap(onBus: 0); running = false }; queue.async { self.detector.reset() } }
    deinit { stop() }
}

final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class Stage {
    let role: String
    let window: StageWindow
    let web: WKWebView
    let screen: NSScreen
    var normalFrame: NSRect
    var lastStateAt = 0.0
    private var sendingState = false
    private var pendingState: String?
    init(role: String, screen: NSScreen, frame: NSRect, delegate: AppDelegate, root: URL) {
        self.role = role; self.screen = screen; normalFrame = frame
        window = StageWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "JARVIS / \(role.uppercased())"
        window.backgroundColor = NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.04, alpha: 1)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let config = WKWebViewConfiguration()
        config.userContentController.add(delegate, name: "jarvis")
        let diagnostics = "window.addEventListener('error',e=>window.webkit.messageHandlers.jarvis.postMessage({action:'diagnostic',error:String(e.message||'Script error'),file:String(e.filename||''),line:e.lineno||0}));window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.jarvis.postMessage({action:'diagnostic',error:String(e.reason||'Unhandled promise')}));"
        config.userContentController.addUserScript(WKUserScript(source:diagnostics,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = delegate
        web.underPageBackgroundColor = window.backgroundColor
        window.contentView = web
        var components = URLComponents(url: root.absoluteURL.appendingPathComponent("index.html"), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "role", value: role), URLQueryItem(name: "native", value: "1")]
        web.loadFileURL(components.url!, allowingReadAccessTo: root.absoluteURL)
    }

    func sendState(_ script: String) {
        if sendingState {
            pendingState = script
            return
        }
        sendingState = true
        web.evaluateJavaScript(script) { [weak self] _, _ in
            guard let self = self else { return }
            self.sendingState = false
            if let latest = self.pendingState {
                self.pendingState = nil
                self.sendState(latest)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private struct DisplayLayout: Equatable {
        let id: UInt32
        let frame: NSRect
        let scale: CGFloat
    }

    var stages: [Stage] = []
    var canSwapDisplays: Bool { stages.contains { $0.role == "left" } && stages.contains { $0.role == "right" } }
    private var stageLayout: [DisplayLayout] = []
    var timer: Timer?
    let input = ClapInput()
    var armed = false, filming = false, swapped = false
    var micStatus = "Микрофон выключен", source = "ready", phase = "idle"
    var audioError = ""
    var startTime: Double?, voiceStarted = false, cooldownUntil = 0.0, micLevel = 0.0
    var sideRevealTime: Double?
    var sideRevealCue = 1.416
    var voice: AVAudioPlayer?, music: AVAudioPlayer?, wake: AVAudioPlayer?
    var sensitivity = 1.0
    var originalPresentation: NSApplication.PresentationOptions = []
    let commands = CreatorProcess()
    let speech = SpeechCapture()
    var profile = CreatorStorage.loadProfile()
    var statsSnapshot = CreatorStorage.readObject(CreatorStorage.statsURL)
    var profileRevision = 0
    var statsBusy = false
    var preparing = false
    var loadedBriefingFingerprint: String?
    var failedAutoPreparation: String?
    var assistantBusy = false
    var assistantHistory: [[String: String]] = []
    var listening = false
    var conversationActive = false
    var assistantEpoch = UUID()
    var assistantJob: UUID?
    var assistantAgentJob: UUID?
    var assistantTextTurn: AssistantTextTurn?
    var silenceDeadline: DispatchWorkItem?
    var finishingSpeech = false
    var lastPartialTranscript = ""
    var resumeClaps = false
    var assistantVoice: AVAudioPlayer?
    var assistantStream: StreamingSpeech?
    var assistantAudioFile: URL?
    var assistantSpokenReply: (transcript: String, reply: String)?
    var liveVoiceTransport: LiveVoiceTransport?
    var liveVoiceRunID: UUID?
    var liveVoiceClosing = false
    var liveVoiceOutputLevel = 0.0
    var liveVoiceLastOutputAt = -Double.infinity
    var liveVoiceSpeaking = false
    var liveTranscript = LiveVoiceTranscript()
    var liveTranscriptUpdate: DispatchWorkItem?
    var liveDelegationIDs: Set<String> = []
    var liveDelegations: [String: UUID] = [:]
    var liveRecommendation = false
    var webStates: [String:Any] = [:]
    var webErrors: [[String:Any]] = []
    var snapshotPhases = Set<String>()
    let fm = FileManager.default
    let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true).absoluteURL
    let qaRoot = CreatorStorage.root.appendingPathComponent("qa", isDirectory: true)
    let diagnosticsEnabled = CommandLine.arguments.contains("--qa-snapshots") || CommandLine.arguments.contains("--diagnostics")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu(); setupStages(); loadAudio()
        input.onClap = { [weak self] in
            guard let self = self, self.armed, !self.listening, !self.assistantBusy, self.assistantVoice?.isPlaying != true, self.voice?.isPlaying != true, self.music?.isPlaying != true, self.wake?.isPlaying != true else { return }
            self.start(source: "double-clap")
        }
        input.onLevel = { [weak self] level in self?.micLevel = level }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let clock = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
        NSApp.activate(ignoringOtherApps: true)
        stages.first(where: {$0.role == "core"})?.window.makeKeyAndOrderFront(nil)
        writeState()
        if CommandLine.arguments.contains("--demo") { DispatchQueue.main.asyncAfter(deadline: .now()+2) { self.start(source: "qa-demo") } }
    }

    func loadAudio() {
        audioError = ""
        sideRevealCue = 1.416
        func load(_ url: URL) -> AVAudioPlayer? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                return player
            } catch { return nil }
        }
        let assets = webRoot.appendingPathComponent("assets", isDirectory: true)
        let prepared = CreatorStorage.readObject(CreatorStorage.briefingMetadataURL)
        let fingerprint = briefingFingerprint()
        voice = nil
        if prepared?["fingerprint"] as? String == fingerprint, let file = CreatorStorage.briefingURL(prepared) {
            voice = load(file)
        }
        loadedBriefingFingerprint = voice == nil ? nil : fingerprint
        let preparedCue = voice == nil ? nil : prepared?["sideRevealSeconds"] as? Double
        if voice == nil { voice = load(assets.appendingPathComponent("narration.wav")) }
        voice?.isMeteringEnabled = true
        let timing = CreatorStorage.readObject(assets.appendingPathComponent("timing.json"))
        if let cue = preparedCue ?? (timing?["sideRevealSeconds"] as? Double),
           cue >= 0, cue < (voice?.duration ?? 0) {
            sideRevealCue = cue
        }
        music = load(assets.appendingPathComponent("music.wav"))
        music?.numberOfLoops = -1
        wake = load(assets.appendingPathComponent("wake.wav"))
    }

    private func displayLayout(_ screens: [NSScreen]) -> [DisplayLayout] {
        screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return DisplayLayout(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }

    private func coreDisplay(in screens: [NSScreen]) -> NSScreen? {
        screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }) ?? screens.first
    }

    private func sceneScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard diagnosticsEnabled, let setting = ProcessInfo.processInfo.environment["JARVIS_CREATOR_TEST_DISPLAYS"],
              let limit = Int(setting), (1...3).contains(limit), limit < screens.count,
              let core = coreDisplay(in: screens) else { return screens }
        return [core] + screens.filter { $0 !== core }.sorted { $0.frame.minX < $1.frame.minX }.prefix(limit - 1)
    }

    func setupStages() {
        if !stages.isEmpty && (conversationActive || listening || assistantBusy) { stopActiveConversation(immediate: true) }
        for stage in stages { stage.window.orderOut(nil); stage.web.configuration.userContentController.removeScriptMessageHandler(forName: "jarvis") }
        stages.removeAll()
        webStates.removeAll()
        let screens = sceneScreens()
        stageLayout = displayLayout(screens)
        guard let coreScreen = coreDisplay(in: screens) else { return }
        let externals = screens.filter { $0 !== coreScreen }.sorted { $0.frame.minX < $1.frame.minX }
        var assignments: [(String,NSScreen)] = [("core",coreScreen)]
        if externals.count >= 2 {
            assignments += [(swapped ? "right" : "left", externals[0]), (swapped ? "left" : "right", externals[1])]
        } else if let external = externals.first {
            assignments.append(("combined", external))
        }
        for (role, screen) in assignments {
            let visible = screen.visibleFrame
            let width = min(1180.0, visible.width * (screens.count == 1 ? 0.84 : 0.94))
            let height = min(780.0, visible.height * 0.88)
            let frame = NSRect(x: visible.midX-width/2, y: visible.midY-height/2, width: width, height: height)
            let stage = Stage(role: role, screen: screen, frame: frame, delegate: self, root: webRoot)
            stage.window.delegate = self
            stages.append(stage)
        }
        if filming { applyFilmingFrames() }
        updateStageVisibility()
    }

    @objc func screensChanged() {
        guard displayLayout(sceneScreens()) != stageLayout else { return }
        setupStages(); broadcast(); writeState()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        broadcast(); sendScripts(); sendTiming()
        sendProfile(to: webView); sendStats(to: webView)
        if diagnosticsEnabled { inspectWebView(webView) }
        if CommandLine.arguments.contains("--qa-snapshots") { DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { self.captureSnapshots(label:"loaded") } }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView,error:error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView,error:error) }
    func navigationFailed(_ webView: WKWebView,error: Error) {
        audioError = "Не удалось открыть интерфейс: \(error.localizedDescription)"
        webErrors.append(["error":error.localizedDescription,"url":webView.url?.absoluteString ?? ""])
        saveWebState(); broadcast(); writeState()
    }
    func inspectWebView(_ webView: WKWebView) {
        let script = "JSON.stringify({role:document.body.dataset.role||'',query:location.search,readyState:document.readyState,width:innerWidth,height:innerHeight,hasNativeHandler:!!window.jarvisNative,hasTimingHandler:!!window.jarvisLoadTiming,hasScriptsHandler:!!window.jarvisReloadScripts,scriptCards:document.querySelectorAll('.script-card').length,canvases:[...document.querySelectorAll('canvas')].map(c=>({id:c.id,width:c.width,height:c.height}))})"
        webView.evaluateJavaScript(script) { value,error in
            guard let role = self.stages.first(where: { $0.web === webView })?.role else { return }
            if let value = value as? String, let data=value.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) { self.webStates[role] = object }
            if let error=error { self.webErrors.append(["role":role,"error":error.localizedDescription]) }
            self.saveWebState()
        }
    }
    func saveWebState() {
        guard diagnosticsEnabled else { return }
        let folder=qaRoot
        try? fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let value: [String:Any] = ["views":webStates,"errors":webErrors,"updatedAt":ISO8601DateFormatter().string(from:Date())]
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:folder.appendingPathComponent("web-state.json"),options:.atomic)}
    }
    func captureSnapshots(label: String) {
        let folder=qaRoot
        try? fm.createDirectory(at:folder,withIntermediateDirectories:true)
        for stage in stages {
            inspectWebView(stage.web)
            let config=WKSnapshotConfiguration();config.snapshotWidth=1600
            stage.web.takeSnapshot(with:config) { image,error in
                if let image=image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) {try? png.write(to:folder.appendingPathComponent("native-\(stage.role)-\(label).png"),options:.atomic)}
                if let error=error {self.webErrors.append(["role":stage.role,"snapshotError":error.localizedDescription]);self.saveWebState()}
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "https://mhslabs.ru/", navigationAction.navigationType == .linkActivated,
           navigationAction.sourceFrame.isMainFrame, isBundledScene(navigationAction.sourceFrame.request.url) {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        decisionHandler(isBundledScene(url) ? .allow : .cancel)
    }

    private func isBundledScene(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        return url.isFileURL && url.lastPathComponent == "index.html"
            && url.deletingLastPathComponent().standardizedFileURL.path == webRoot.standardizedFileURL.path
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "start": start(source: "button")
        case "reset": reset()
        case "arm": setArmed((body["value"] as? Bool) ?? !armed)
        case "film": setFilming((body["value"] as? Bool) ?? !filming)
        case "quit": NSApp.terminate(nil)
        case "profile-get": profile = CreatorStorage.loadProfile(); sendProfile()
        case "profile-save":
            if let fields = body["value"] as? [String: Any] { saveProfile(fields) }
        case "profile-clear-voice-key": clearVoiceKey()
        case "profile-clear-openai-key": clearOpenAIKey()
        case "stats-refresh": refreshStats()
        case "prepare": prepareBriefing()
        case "listen-start": if liveVoiceRunID == nil { beginSpeech() }
        case "listen-stop": endSpeech()
        case "conversation-start": startChosenConversation()
        case "conversation-stop": stopActiveConversation()
        case "ask":
            guard liveVoiceRunID == nil else { return }
            if let question = body["value"] as? String { ask(["question": question]) }
            else if let input = body["value"] as? [String: Any] { ask(input) }
        case "swap": menuSwap()
        case "sensitivity": sensitivity = max(0.5,min(3,(body["value"] as? Double) ?? 1)); input.setSensitivity(sensitivity); broadcast()
        case "preview": menuPreview()
        case "diagnostic":
            if webErrors.count<30 {webErrors.append(["error":String(describing:body["error"] ?? "unknown"),"file":String(describing:body["file"] ?? ""),"line":body["line"] ?? 0]);saveWebState()}
        default: break
        }
    }

    func start(source: String, allowPreparation: Bool = true) {
        guard (phase == "idle" || phase == "done"), !conversationActive, !listening, !assistantBusy, !preparing,
              assistantVoice?.isPlaying != true, ProcessInfo.processInfo.systemUptime >= cooldownUntil else { return }
        let personalized = !profile.name.isEmpty || profile.voice.provider != "system" || profile.platforms.values.contains(true)
        let fingerprint = briefingFingerprint()
        if allowPreparation, (personalized || voice == nil), loadedBriefingFingerprint != fingerprint, failedAutoPreparation != fingerprint {
            prepareBriefing(thenStart: source)
            return
        }
        if loadedBriefingFingerprint != nil && loadedBriefingFingerprint != fingerprint { loadAudio() }
        if voice == nil { loadAudio() }
        guard voice != nil else { broadcast(); return }
        self.source = source; phase = "boot"; voiceStarted = false
        sideRevealTime = nil
        startTime = ProcessInfo.processInfo.systemUptime
        voice?.stop(); voice?.currentTime = 0
        music?.stop(); music?.currentTime = 0; music?.volume = 0; music?.play(); music?.setVolume(0.34, fadeDuration: 1.5)
        wake?.currentTime = 0; wake?.volume = 0.65; wake?.play()
        // Start with the core visible. The narration clock reveals the side panels.
        if !filming { setFilming(true) }
        updateStageVisibility()
        stages.first(where: {$0.role == "core"})?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        broadcast(); writeState()
    }

    func reset() {
        voice?.stop(); music?.stop(); wake?.stop(); voice?.currentTime = 0; music?.currentTime = 0
        phase = "idle"; startTime = nil; voiceStarted = false; cooldownUntil = ProcessInfo.processInfo.systemUptime + 2
        sideRevealTime = nil
        updateStageVisibility()
        source = "reset"; broadcast(); writeState()
    }

    @objc func tick() {
        if liveVoiceRunID != nil { tickLiveVoice() }
        let elapsed = startTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        if phase == "boot", elapsed >= 2.4 {
            music?.setVolume(0.105, fadeDuration: 0.45)
            voiceStarted = voice?.play() == true
            if voiceStarted { phase = "report" }
            else { audioError = "Не удалось запустить озвучку"; phase = "done"; cooldownUntil = ProcessInfo.processInfo.systemUptime+2 }
            broadcast()
            writeState()
        }
        if phase == "report", sideRevealTime == nil, let voice = voice,
           voice.isPlaying, voice.currentTime >= sideRevealCue {
            sideRevealTime = ProcessInfo.processInfo.systemUptime
            broadcast()
            updateStageVisibility()
            writeState()
        }
        if phase == "report", voiceStarted, elapsed >= 2.4 + (voice?.duration ?? 0) {
            phase = "done"; cooldownUntil = ProcessInfo.processInfo.systemUptime + 2
            music?.setVolume(0.27, fadeDuration: 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now()+2) { [weak self] in if self?.phase == "done" { self?.music?.setVolume(0, fadeDuration: 2) } }
            broadcast()
            writeState()
        }
        if phase == "done", elapsed >= 2.4 + (voice?.duration ?? 0) + 4.2, music?.isPlaying == true {
            music?.stop()
            cooldownUntil = ProcessInfo.processInfo.systemUptime + 2
        }
        broadcast(frameUpdate: true)
    }

    func setArmed(_ enabled: Bool) {
        if enabled && (conversationActive || listening) { resumeClaps = true; return }
        if !enabled { armed = false; input.stop(); micStatus = "Микрофон выключен"; broadcast(); writeState(); return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            micStatus = "Разреши микрофон в окне macOS"; broadcast()
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in DispatchQueue.main.async { if allowed { self?.setArmed(true) } else { self?.micStatus = "Нет доступа к микрофону"; self?.broadcast(); self?.writeState() } } }
        } else if status == .authorized {
            do { try input.start(); input.setSensitivity(sensitivity); armed = true; micStatus = "Два хлопка / \(input.deviceName)" }
            catch { armed = false; micStatus = error.localizedDescription }
            broadcast(); writeState()
        } else { micStatus = "Нет доступа. Настройки системы → Конфиденциальность → Микрофон"; broadcast(); writeState() }
    }

    func setFilming(_ enabled: Bool) {
        guard filming != enabled else { return }
        filming = enabled
        if enabled { originalPresentation = NSApp.presentationOptions; applyFilmingFrames() }
        else {
            NSApp.presentationOptions = originalPresentation
            for stage in stages {
                stage.window.styleMask = [.titled,.closable,.miniaturizable,.resizable]
                stage.window.level = .normal
                stage.window.setFrame(stage.normalFrame, display: true)
                stage.web.evaluateJavaScript("document.body.classList.remove('filming')",completionHandler:nil)
            }
        }
        updateStageVisibility()
        broadcast(); writeState()
    }

    func updateStageVisibility() {
        let showSides = sideRevealTime != nil
        for stage in stages {
            if stage.role == "core" || showSides {
                if !stage.window.isVisible { stage.window.orderFrontRegardless() }
            } else if stage.window.isVisible {
                stage.window.orderOut(nil)
            }
        }
    }

    func applyFilmingFrames() {
        NSApp.presentationOptions = [.autoHideDock,.autoHideMenuBar]
        for stage in stages {
            stage.normalFrame = stage.window.frame
            stage.window.styleMask = [.borderless]
            stage.window.level = .floating
            stage.window.setFrame(stage.screen.frame, display: true)
            stage.web.evaluateJavaScript("document.body.classList.add('filming')",completionHandler:nil)
        }
    }

    func state() -> [String:Any] {
        let speaker = assistantVoice?.isPlaying == true ? assistantVoice : phase == "report" ? voice : nil
        speaker?.updateMeters()
        let power = speaker?.averagePower(forChannel: 0) ?? -80
        let playerLevel = speaker == nil ? 0 : min(1, pow(10, Double(power)/25) * 2.8)
        let streamLevel = assistantStream?.isPlaying == true ? assistantStream?.level ?? 0 : 0
        let level = max(playerLevel, streamLevel, liveVoiceOutputLevel)
        let now = ProcessInfo.processInfo.systemUptime
        return ["type":"state","phase":phase,"elapsed":startTime.map { now - $0 } ?? 0,"sideElapsed":sideRevealTime.map { now - $0 } ?? -1,"voicePlaybackTime":voice?.currentTime ?? 0,"visibleRoles":stages.filter { $0.window.isVisible }.map { $0.role },"level":level,"armed":armed,"micStatus":micStatus,"micLevel":micLevel,"micDevice":input.deviceName,"micDeviceID":input.deviceID,"micSampleRate":input.sampleRate,"micRoutingNote":input.routingNote,"screenCount":stageLayout.count,"canSwapDisplays":canSwapDisplays,"source":source,"filming":filming,"sensitivity":sensitivity,"narrationDuration":voice?.duration ?? 0,"audioError":audioError,"statsBusy":statsBusy,"preparing":preparing,"conversationActive":conversationActive,"displayRoles":stages.map { ["role":$0.role,"display":$0.screen.localizedName] }]
    }
    func broadcast(frameUpdate: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let recipients = frameUpdate ? stages.filter { stage in
            guard stage.window.isVisible else { return false }
            let interval: Double
            if stage.role == "core" {
                if phase == "boot" || phase == "report" || assistantVoice?.isPlaying == true ||
                    assistantStream?.isPlaying == true || liveVoiceRunID != nil { interval = 0.05 }
                else { interval = armed ? 0.15 : 1 }
            } else if phase == "report", let revealedAt = sideRevealTime, now - revealedAt < 9 {
                interval = 0.1
            } else {
                interval = 1
            }
            return now - stage.lastStateAt >= interval - 0.005
        } : stages
        guard !recipients.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: state()), let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.jarvisNative && window.jarvisNative(\(json))"
        for stage in recipients {
            stage.lastStateAt = now
            stage.sendState(script)
        }
    }
    func writeState() {
        guard diagnosticsEnabled else { return }
        let folder = qaRoot
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var value = state(); value["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: value,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to: folder.appendingPathComponent("native-state.json"),options:.atomic) }
        if CommandLine.arguments.contains("--qa-snapshots"), !snapshotPhases.contains(phase) {
            let label=phase;snapshotPhases.insert(label)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {self.captureSnapshots(label:label)}
        }
    }

    func sendScripts() {
        if let scripts = CreatorStorage.readObject(webRoot.appendingPathComponent("scripts.json")) {
            send("jarvisReloadScripts", scripts)
        }
    }
    func sendTiming() {
        let file = webRoot.appendingPathComponent("assets/timing.json")
        guard let data = try? Data(contentsOf:file), let object = try? JSONSerialization.jsonObject(with:data), let serialized = try? JSONSerialization.data(withJSONObject:object), let json = String(data:serialized,encoding:.utf8) else { return }
        stages.forEach { $0.web.evaluateJavaScript("window.jarvisLoadTiming && window.jarvisLoadTiming(\(json))",completionHandler:nil) }
    }

    func buildMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(); app.submenu = appMenu; main.addItem(app)
        func item(_ title: String,_ action: Selector,_ key: String) { let item = NSMenuItem(title:title,action:action,keyEquivalent:key); item.target = self; appMenu.addItem(item) }
        item("Запустить сцену",#selector(menuStart)," ")
        item("Сбросить",#selector(menuReset),"r")
        item("Режим съёмки",#selector(menuFilm),"f")
        item("Слушать хлопки",#selector(menuArm),"m")
        item("Поменять боковые экраны",#selector(menuSwap),"s")
        item("Показать все окна",#selector(menuPreview),"p")
        item("Обновить статистику",#selector(menuRefreshStats),"u")
        item("Подготовить голосовой отчёт",#selector(menuPrepareBriefing),"g")
        item("Сохранить кадры интерфейса",#selector(menuSnapshots),"j")
        appMenu.addItem(.separator())
        item("Завершить Jarvis Creator",#selector(menuQuit),"q")
        NSApp.mainMenu = main
    }
    @objc func menuStart() { start(source:"menu") }
    @objc func menuReset() { reset() }
    @objc func menuFilm() { setFilming(!filming) }
    @objc func menuArm() { setArmed(!armed) }
    @objc func menuSwap() {
        guard canSwapDisplays else { return }
        swapped.toggle(); setupStages(); broadcast(); writeState()
    }
    @objc func menuPreview() {
        guard stages.count > 1, phase == "idle" || sideRevealTime != nil else { return }
        stages.forEach { $0.window.makeKeyAndOrderFront(nil) }
        broadcast()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(menuSwap): return canSwapDisplays
        case #selector(menuPreview): return stages.count > 1 && (phase == "idle" || sideRevealTime != nil)
        default: return true
        }
    }
    @objc func menuRefreshStats() { refreshStats() }
    @objc func menuPrepareBriefing() { prepareBriefing() }
    @objc func menuSnapshots() { captureSnapshots(label:phase) }
    @objc func menuQuit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if stages.first(where:{$0.role == "core"})?.window === sender { NSApp.terminate(nil);return false }; return true }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        input.stop()
        speech.cancel()
        silenceDeadline?.cancel()
        liveVoiceRunID = nil
        liveTranscriptUpdate?.cancel()
        liveVoiceTransport?.cancel()
        assistantStream?.cancel()
        commands.stopAll()
        voice?.stop(); music?.stop(); wake?.stop(); assistantVoice?.stop()
        if let file = assistantAudioFile { try? fm.removeItem(at: file) }
        NSApp.presentationOptions = originalPresentation
    }
}

@main
struct JarvisCreator {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--self-test") {
            let results = detectorSelfTests()
            let data = try! JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]); print(String(data:data,encoding:.utf8)!)
            exit(results.values.allSatisfy {$0} ? 0:1)
        }
        if CommandLine.arguments.contains("--screens") {
            let screens = NSScreen.screens.map { screen -> [String:Any] in
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                return ["name":screen.localizedName,"id":id,"builtin":CGDisplayIsBuiltin(id) != 0,"x":screen.frame.minX,"y":screen.frame.minY,"width":screen.frame.width,"height":screen.frame.height]
            }
            let data = try! JSONSerialization.data(withJSONObject:screens,options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!);exit(0)
        }
        if CommandLine.arguments.contains("--audio-devices") {
            let value: [String:Any] = ["defaultInput":InputDevices.defaultID,"devices":InputDevices.all().map { ["id":$0.id,"name":$0.name,"builtin":$0.builtIn] }]
            let data=try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!);exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
