import Foundation

/// Minimal config for M0. Extended in later milestones (models, speaker count, paths).
struct Config: Codable, CustomStringConvertible {
    /// Expected remote speakers on the system-audio lane (not counting You).
    var remoteSpeakerHint: Int = 2
    /// Max remote speakers to cluster toward (3–4 person meetings → you + up to 3).
    var maxRemoteSpeakers: Int = 3
    var sampleRate: Double = 16_000
    var dumpWav: Bool = false

    var description: String {
        "remoteSpeakers=\(remoteSpeakerHint)–\(maxRemoteSpeakers) sampleRate=\(Int(sampleRate))"
    }

    static func load() -> Config {
        let url = configURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return decoded
    }

    func save() throws {
        let url = Self.configURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    static func configURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/listnr", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}
