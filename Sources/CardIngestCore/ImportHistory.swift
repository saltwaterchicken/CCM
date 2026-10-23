import Foundation

/// A card file an earlier import already brought in, and where it went.
public struct ImportedFile: Equatable, Sendable {
    public var file: CardFile
    /// The card folder it was copied into, e.g. .../2026-10-23-ES001.
    public var folder: URL
    /// Its name there, e.g. 2026-10-14-ES_1234.CR3.
    public var newName: String
}

/// What's new on a card and what earlier imports already brought in.
public struct CardCheck: Equatable, Sendable {
    public var newFiles: [CardFile]
    public var alreadyImported: [ImportedFile]

    /// The card folders holding the files already brought in, by name.
    public var earlierFolders: [URL] {
        Array(Set(alreadyImported.map(\.folder))).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var nothingNew: Bool { newFiles.isEmpty && !alreadyImported.isEmpty }

    /// What to tell the photographer, or nil when the card is all new.
    public var message: String? {
        guard !alreadyImported.isEmpty else { return nil }
        let names = earlierFolders.map(\.lastPathComponent)
        let folders = names.count <= 2
            ? names.joined(separator: " and ")
            : "\(names[0]), \(names[1]) and \(names.count - 2) more"
        let total = newFiles.count + alreadyImported.count
        if newFiles.isEmpty {
            return "Already imported: all \(total) files are in \(folders). Nothing new to copy."
        }
        let new = newFiles.count == 1 ? "the 1 new file" : "the \(newFiles.count) new files"
        return "Partly imported before: \(alreadyImported.count) of \(total) files are already in \(folders). "
            + "Copy brings in \(new) only."
    }
}

/// Every file earlier imports brought in, read from the receipts in the
/// destination's card folders. A card file counts as already imported when a
/// receipt lists the same path on the card, size and modified date. Deleting
/// a card folder (receipt included) lets its files be imported again; deleting
/// rejected photos from it doesn't bring them back.
public struct ImportHistory: Sendable {
    private struct Key: Hashable {
        var path: String
        var size: Int64
    }

    private struct Record: Sendable {
        var folder: URL
        var newName: String
        var modified: Date?
    }

    private var records: [Key: [Record]] = [:]

    public init() {}

    /// Reads the receipts in each folder directly inside `root`.
    public static func load(from root: URL) -> ImportHistory {
        var history = ImportHistory()
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return history }
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where Receipt.isReceipt(name) {
                guard let receipt = Receipt.read(folder.appendingPathComponent(name)) else { continue }
                for row in receipt.rows {
                    history.records[Key(path: row.originalPath.lowercased(), size: row.size), default: []]
                        .append(Record(folder: folder, newName: row.newName, modified: row.modified))
                }
            }
        }
        return history
    }

    /// Splits a card's files into new ones and ones already brought in.
    public func check(_ files: [CardFile]) -> CardCheck {
        var check = CardCheck(newFiles: [], alreadyImported: [])
        for file in files {
            let earlier = records[Key(path: file.relativePath.lowercased(), size: file.size)]?.first { record in
                guard let a = record.modified, let b = file.modified else { return true }
                return Self.sameMoment(a, b)
            }
            if let earlier {
                check.alreadyImported.append(ImportedFile(file: file, folder: earlier.folder, newName: earlier.newName))
            } else {
                check.newFiles.append(file)
            }
        }
        return check
    }

    /// FAT and exFAT cards keep modified dates to 2 seconds, and FAT ones
    /// store local time, so the same file looks hours off after the Mac's time
    /// zone changes. Same moment, give or take that.
    static func sameMoment(_ a: Date, _ b: Date) -> Bool {
        let gap = abs(a.timeIntervalSince(b))
        if gap <= 2 { return true }
        guard gap <= 26 * 3600 else { return false }
        // Time zones are whole quarter hours apart.
        let offQuarter = gap.truncatingRemainder(dividingBy: 900)
        return min(offQuarter, 900 - offQuarter) <= 2
    }
}
