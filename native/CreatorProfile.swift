import Foundation
import Security

struct CreatorProfile: Codable {
    struct Voice: Codable {
        var provider = "system"
        var voice_id = ""
    }

    static let platformNames = ["instagram", "youtube", "telegram"]
    var name = ""
    var platforms = ["instagram": false, "youtube": false, "telegram": false]
    var voice = Voice()
    var voice_key_revision: String?
    var telegram_chat_id: String?
    var youtube_channel_id: String?
    var workspace: String?
    var niche = ""
    var audience = ""
    var goal = ""
    var format = "mixed"
    var project_type = "blog"
    var assistant_provider = "auto"
    var conversation_mode = "turns"
    var onboarded = false

    var webData: [String: Any] {
        ["name": name, "platforms": platforms,
         "voice": ["provider": voice.provider, "voice_id": voice.voice_id, "has_api_key": CreatorKeychain.hasKey()],
         "telegram_chat_id": telegram_chat_id ?? "", "youtube_channel_id": youtube_channel_id ?? "",
         "workspace": workspace ?? "", "niche": niche, "audience": audience, "goal": goal,
         "format": format, "project_type": project_type, "assistant_provider": assistant_provider,
         "conversation_mode": conversation_mode, "has_openai_key": CreatorKeychain.hasKey(kind: .openAI),
         "onboarded": onboarded]
    }

    mutating func apply(_ update: [String: Any]) {
        if let name = update["name"] as? String {
            self.name = Self.cleaned(name, limit: 80)
        }
        if let flags = update["platforms"] as? [String: Any] {
            for platform in Self.platformNames {
                if let enabled = flags[platform] as? Bool { platforms[platform] = enabled }
            }
        }
        if let options = update["voice"] as? [String: Any] {
            if let provider = options["provider"] as? String, ["system", "elevenlabs", "voicestudio"].contains(provider) {
                voice.provider = provider
            }
            if let voiceID = options["voice_id"] as? String { voice.voice_id = Self.cleaned(voiceID, limit: 128) }
        }
        telegram_chat_id = Self.optionalSetting(update, field: "telegram_chat_id", current: telegram_chat_id, limit: 160)
        youtube_channel_id = Self.optionalSetting(update, field: "youtube_channel_id", current: youtube_channel_id, limit: 160)
        workspace = Self.optionalSetting(update, field: "workspace", current: workspace, limit: 4096)
        if let value = update["niche"] as? String { niche = Self.cleaned(value, limit: 300) }
        if let value = update["audience"] as? String { audience = Self.cleaned(value, limit: 600) }
        if let value = update["goal"] as? String { goal = Self.cleaned(value, limit: 600) }
        if let value = update["format"] as? String, ["talking-head", "animated", "mixed"].contains(value) { format = value }
        if let value = update["project_type"] as? String, ["blog", "business"].contains(value) { project_type = value }
        if let value = update["assistant_provider"] as? String, ["auto", "codex", "claude"].contains(value) { assistant_provider = value }
        if let value = update["conversation_mode"] as? String, ["turns", "gpt-live-1"].contains(value) { conversation_mode = value }
        if let value = update["onboarded"] as? Bool { onboarded = value }
    }

    private static func cleaned(_ value: String, limit: Int) -> String {
        let visible = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(visible).prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalSetting(_ update: [String: Any], field: String, current: String?, limit: Int) -> String? {
        guard let value = update[field] else { return current }
        if value is NSNull { return nil }
        guard let text = value as? String else { return current }
        let cleaned = cleaned(text, limit: limit)
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum CreatorStorage {
    static let root: URL = {
        if let value = ProcessInfo.processInfo.environment["JARVIS_CREATOR_HOME"], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis Creator", isDirectory: true)
    }()

    static var profileURL: URL { root.appendingPathComponent("profile.json") }
    static var statsURL: URL { root.appendingPathComponent("stats.json") }
    static var briefingMetadataURL: URL { root.appendingPathComponent("briefing.json") }

    static func briefingURL(_ metadata: [String: Any]?) -> URL? {
        guard let name = metadata?["audioFile"] as? String, name.hasPrefix("briefing-"), name.hasSuffix(".wav"),
              UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil else { return nil }
        return root.appendingPathComponent(name)
    }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func loadProfile() -> CreatorProfile {
        guard let data = try? Data(contentsOf: profileURL),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return CreatorProfile() }
        var profile = CreatorProfile()
        profile.apply(fields)
        if let revision = fields["voice_key_revision"] as? String, UUID(uuidString: revision) != nil {
            profile.voice_key_revision = revision
        }
        return profile
    }

    static func saveProfile(_ profile: CreatorProfile) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: profileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
    }

    static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum CreatorKeychain {
    enum Kind: String { case elevenLabs = "elevenlabs", openAI = "openai" }

    private static func query(_ kind: Kind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jarviscreator.local.\(kind.rawValue)",
         kSecAttrAccount as String: "api-key"]
    }

    static func hasKey(kind: Kind = .elevenLabs) -> Bool {
        var request = query(kind)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static func read(kind: Kind = .elevenLabs) -> String? {
        var request = query(kind)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, kind: Kind = .elevenLabs) throws {
        let query = query(kind)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove(kind: Kind = .elevenLabs) throws {
        let status = SecItemDelete(query(kind) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        throw CreatorError("Не удалось сохранить ключ в Связке ключей macOS (\(status)).")
    }
}

struct CreatorError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
