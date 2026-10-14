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

    /// Loads the file, or writes the defaults there first if it doesn't exist yet.
    public static func loadOrCreate(at url: URL = defaultFileURL) throws -> IngestSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        let defaults = IngestSettings()
        try save(defaults, to: url)
        return defaults
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
