import Foundation

public struct Repo: Hashable, Codable, Sendable {
    public let owner: String
    public let name: String
    public var full: String { "\(owner)/\(name)" }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case missing(path: String)
    case badJSON(path: String, reason: String)
    case badRepos(path: String, entries: [String])
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .missing(let p):
            return "Cannot read config: \(p)"
        case .badJSON(let p, let r):
            return "Invalid config JSON in \(p): \(r)"
        case .badRepos(let p, let e):
            return "Invalid repo entries in \(p) (expected \"owner/name\"): \(e.joined(separator: ", "))"
        case .writeFailed(let p, let r):
            return "Could not write \(p): \(r)"
        }
    }
}

/// User-adjustable appearance and Copilot settings stored under "settings" in the config file.
public struct AppSettings: Codable, Sendable, Equatable {
    public var fontName = ""
    public var diffFontSize = 13.0
    public var uiFontSize = 13.0
    public var lineSpacing = 6.0
    public var copilotModel = "auto"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        diffFontSize = try c.decodeIfPresent(Double.self, forKey: .diffFontSize) ?? diffFontSize
        uiFontSize = try c.decodeIfPresent(Double.self, forKey: .uiFontSize) ?? uiFontSize
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? lineSpacing
        copilotModel = try c.decodeIfPresent(String.self, forKey: .copilotModel) ?? copilotModel
    }
}

private struct ReposFile: Decodable { let repos: [String] }

public struct Config: Sendable, Equatable {
    public let repos: [Repo]

    public static func path(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.config")
        return base + "/seer/config.json"
    }

    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        let p = path(env: env)
        guard FileManager.default.fileExists(atPath: p) else { return Config(repos: []) }
        guard let data = FileManager.default.contents(atPath: p) else { throw ConfigError.missing(path: p) }
        return try parse(data, path: p)
    }

    /// Repo entries as written in the file, without validation (for editing a broken config).
    public static func rawRepos(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let data = FileManager.default.contents(atPath: path(env: env)) else { return [] }
        return (try? JSONDecoder().decode(ReposFile.self, from: data))?.repos ?? []
    }

    /// Settings as written in the file; defaults when missing or unreadable (independent of repo validity).
    public static func loadSettings(env: [String: String] = ProcessInfo.processInfo.environment) -> AppSettings {
        struct Raw: Decodable { let settings: AppSettings? }
        guard let data = FileManager.default.contents(atPath: path(env: env)) else { return AppSettings() }
        return (try? JSONDecoder().decode(Raw.self, from: data))?.settings ?? AppSettings()
    }

    /// Validates `entries` and writes them, with `settings`, as the config file.
    public static func save(_ entries: [String], settings: AppSettings = AppSettings(),
                            env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        struct File: Encodable { let repos: [String]; let settings: AppSettings }
        let p = path(env: env)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(File(repos: entries, settings: settings))
        let config = try parse(data, path: p)
        do {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: p), options: .atomic)
        } catch {
            throw ConfigError.writeFailed(path: p, reason: error.localizedDescription)
        }
        return config
    }

    public static func parse(_ data: Data, path: String) throws -> Config {
        let raw: ReposFile
        do {
            raw = try JSONDecoder().decode(ReposFile.self, from: data)
        } catch {
            throw ConfigError.badJSON(path: path, reason: "\(error)")
        }
        var repos: [Repo] = []
        var bad: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        for entry in raw.repos {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) {
                repos.append(Repo(owner: String(parts[0]), name: String(parts[1])))
            } else {
                bad.append(entry)
            }
        }
        if !bad.isEmpty { throw ConfigError.badRepos(path: path, entries: bad) }
        return Config(repos: repos)
    }
}
