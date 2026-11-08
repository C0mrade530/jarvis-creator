import Foundation

final class CreatorProcess {
    private let lock = NSLock()
    private var children: [UUID: Process] = [:]

    private func pythonExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let shellPaths = (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") && $0 != "/usr/bin" }
            .map { String($0) + "/python3" }
        let framework = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(at: framework, includingPropertiesForKeys: nil)) ?? []
        let frameworkPaths = versions.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/python3").path }
        let candidates = [environment["JARVIS_CREATOR_PYTHON"]].compactMap { $0 }
            + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] + shellPaths + frameworkPaths
            + ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        guard let executable = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return URL(fileURLWithPath: executable)
    }

    @discardableResult
    func run(_ script: String, arguments: [String], input: [String: Any]? = nil,
             timeout: Double = 75, completion: @escaping (Result<[String: Any], Error>) -> Void) -> UUID? {
        launch(script, arguments: arguments, input: input, timeout: timeout, read: { handle in
            let data = handle.readDataToEndOfFile()
            return data.count <= 2_000_000 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        }) { result in
            switch result {
            case .success(let (object, status, reason)):
                if status == 0, let object = object, object["error"] == nil { completion(.success(object)) }
                else if let message = object?["error"] as? String { completion(.failure(CreatorError(String(message.prefix(1000))))) }
                else { completion(.failure(Self.processError(script, reason: reason))) }
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    @discardableResult
    func runStream(_ script: String, arguments: [String], input: [String: Any], timeout: Double = 120,
                   onEvent: @escaping ([String: Any]) -> Void,
                   completion: @escaping (Result<Void, Error>) -> Void) -> UUID? {
        launch(script, arguments: arguments, input: input, timeout: timeout, read: { handle in
            var pending = Data()
            var received = 0
            func emit(_ line: Data) throws {
                guard !line.isEmpty else { return }
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      event["type"] is String else { throw CreatorError("Поток ответа имеет неверный формат.") }
                DispatchQueue.main.async { onEvent(event) }
            }
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                received += bytes.count
                guard received <= 2_000_000 else { throw CreatorError("Ответ слишком длинный.") }
                pending.append(bytes)
                while let newline = pending.firstIndex(of: 10) {
                    try emit(Data(pending[..<newline]))
                    pending.removeSubrange(...newline)
                }
            }
            try emit(pending)
        }) { (result: Result<(Void, Int32, Process.TerminationReason), Error>) in
            switch result {
            case .success(let (_, status, reason)):
                completion(status == 0 ? .success(()) : .failure(Self.processError(script, reason: reason)))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    private static func processError(_ script: String, reason: Process.TerminationReason) -> Error {
        if reason == .uncaughtSignal { return CreatorError("Действие не завершилось вовремя.") }
        return CreatorError("Компонент \(script) вернул некорректный ответ.")
    }

    private func launch<Output>(_ script: String, arguments: [String], input: [String: Any]?, timeout: Double,
                                read: @escaping (FileHandle) throws -> Output,
                                completion: @escaping (Result<(Output, Int32, Process.TerminationReason), Error>) -> Void) -> UUID? {
        guard let root = Bundle.main.resourceURL?.absoluteURL,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/\(script)").path) else {
            completion(.failure(CreatorError("В приложении отсутствует компонент \(script).")))
            return nil
        }
        guard let executable = pythonExecutable() else {
            completion(.failure(CreatorError("Для этого действия нужен Python 3. Установите его и снова откройте приложение.")))
            return nil
        }
        let request: Data
        do { request = try input.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data() }
        catch { completion(.failure(CreatorError("Не удалось подготовить запрос."))); return nil }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = [root.appendingPathComponent("scripts/\(script)").path] + arguments
        process.currentDirectoryURL = root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["ELEVENLABS_API_KEY"] = nil
        environment["JARVIS_CREATOR_HOME"] = CreatorStorage.root.path
        let usualPaths = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        environment["PATH"] = ([environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"] + usualPaths).joined(separator: ":")
        process.environment = environment

        let id = UUID()
        do { try process.run() }
        catch { completion(.failure(CreatorError("Не удалось запустить компонент \(script)."))); return nil }
        lock.lock(); children[id] = process; lock.unlock()
        let expiration = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: expiration)

        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: request)
            try? stdin.fileHandleForWriting.close()
            let output = Result { try read(stdout.fileHandleForReading) }
            if case .failure = output, process.isRunning { process.terminate() }
            process.waitUntilExit()
            expiration.cancel()
            self.lock.lock(); self.children[id] = nil; self.lock.unlock()
            let result = output.map { ($0, process.terminationStatus, process.terminationReason) }
            DispatchQueue.main.async { completion(result) }
        }
        return id
    }

    func cancel(_ id: UUID?) {
        guard let id = id else { return }
        lock.lock(); let child = children[id]; lock.unlock()
        if child?.isRunning == true { child?.terminate() }
    }

    func stopAll() {
        lock.lock(); let running = Array(children.values); lock.unlock()
        for child in running where child.isRunning { child.terminate() }
    }
}
