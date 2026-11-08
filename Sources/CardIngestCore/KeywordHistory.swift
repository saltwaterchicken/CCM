import Foundation

/// The photographer's own keywords: every one used from the grid on this Mac,
/// newest first, offered under the grid and filled in as typed. Kept apart from
/// the settings file, which holds the job's keywords (Summer Camp, 2026), so a
/// project file never carries one photographer's names and places to another.
/// A plain text file, one keyword per line, that can be read and edited by hand:
/// ~/Library/Application Support/Media Sherpa/My Keywords.txt.
public enum KeywordHistory {
    /// How many are kept; the oldest drop off.
    public static let limit = 500

    public static var defaultFileURL: URL {
        SettingsStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("My Keywords.txt")
    }

    /// The keywords in the file, in its order, each once; none when there's no file.
    public static func load(from url: URL = defaultFileURL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Keywords.merged([], adding: lines).prefix(limit))
    }

    public static func save(_ words: [String], to url: URL = defaultFileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = words.prefix(limit).joined(separator: "\n") + (words.isEmpty ? "" : "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `history` with `words` moved or added to the front, newest first.
    public static func used(_ words: [String], in history: [String]) -> [String] {
        Array(Keywords.merged(words, adding: history).prefix(limit))
    }

    /// The first time: the file made from the lists kept before in the app's
    /// preferences (one per way of starting the app), newest first. Leaves an
    /// existing file alone. Returns what's in the file afterwards.
    @discardableResult
    public static func moveIn(_ older: [[String]], to url: URL = defaultFileURL) -> [String] {
        guard !FileManager.default.fileExists(atPath: url.path) else { return load(from: url) }
        let words = older.reduce([String]()) { Keywords.merged($0, adding: $1) }
        guard !words.isEmpty else { return [] }
        try? save(words, to: url)
        return load(from: url)
    }
}
