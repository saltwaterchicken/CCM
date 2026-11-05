import Foundation

public enum SettingsError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case unwritable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason):
            return "Couldn't read the settings file at \(path): \(reason)"
        case let .unwritable(path, reason):
            return "Couldn't save the settings file at \(path): \(reason)"
        }
    }
}

/// Reads and writes settings files. The main file lives at
/// ~/Library/Application Support/Card Ingest/Settings.plist; project files can
/// live anywhere and be loaded in its place.
public enum SettingsStore {
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Card Ingest", isDirectory: true)
            .appendingPathComponent("Settings.plist")
    }

    /// `Ship/Settings.plist`, as `make-app.sh` puts it in the app. Nil without it (`swift run`).
    public static var shippedFileURL: URL? {
        Bundle.main.url(forResource: "Settings", withExtension: "plist")
    }

    /// Loads the file, or if it doesn't exist yet writes it first: as the shipped settings say,
    /// where they can be read, otherwise the defaults. A shipped topic is never taken, as it
    /// would share alerts with whoever else has this build; the tutorial makes each user their own.
    public static func loadOrCreate(at url: URL = defaultFileURL, shipped: URL? = shippedFileURL) throws -> IngestSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        var first = shipped.flatMap { try? load(from: $0) } ?? IngestSettings()
        first.notifications.topic = ""
        try save(first, to: url)
        return first
    }

    /// Why settings shouldn't ship, or nil when they're fine. `make-app.sh` stops on this,
    /// as the app would otherwise ignore a misspelled setting without saying so.
    public static func shippingProblem(_ url: URL) -> String? {
        let settings: IngestSettings
        do { settings = try load(from: url) } catch { return error.localizedDescription }
        if !settings.notifications.topic.trimmingCharacters(in: .whitespaces).isEmpty {
            return "It has a notifications topic. Empty it: each user gets their own in the tutorial."
        }
        guard let found = keys(in: try? Data(contentsOf: url)),
              let known = keys(in: try? PropertyListEncoder().encode(IngestSettings())) else { return "It isn't a settings file." }
        if let unknown = unknownKey(in: found, known: known) {
            return "\"\(unknown)\" isn't a setting, so it would be ignored. Check the spelling."
        }
        return nil
    }

    private static func keys(in data: Data?) -> [String: Any]? {
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }

    private static func unknownKey(in found: [String: Any], known: [String: Any]) -> String? {
        for (key, value) in found.sorted(by: { $0.key < $1.key }) {
            guard let expected = known[key] else { return key }
            if let inner = value as? [String: Any], let innerKnown = expected as? [String: Any],
               let unknown = unknownKey(in: inner, known: innerKnown) {
                return "\(key) › \(unknown)"
            }
        }
        return nil
    }

    public static func load(from url: URL) throws -> IngestSettings {
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListDecoder().decode(IngestSettings.self, from: data)
        } catch {
            throw SettingsError.unreadable(path: url.path, reason: describe(error))
        }
    }

    public static func save(_ settings: IngestSettings, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            throw SettingsError.unwritable(path: url.path, reason: describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if case let DecodingError.typeMismatch(_, context) = error {
            return "wrong kind of value at \(keyPath(context))"
        }
        if case let DecodingError.dataCorrupted(context) = error {
            return context.codingPath.isEmpty ? "the file isn't a valid property list" : "bad value at \(keyPath(context))"
        }
        return error.localizedDescription
    }

    private static func keyPath(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
