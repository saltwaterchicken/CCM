import Foundation

/// What happened when a card's originals were moved to its Trash.
public struct TrashResult: Equatable, Sendable {
    public var trashed: Int
    /// One line per file left on the card, e.g. "DCIM/100CANON/IMG_1234.CR3: it changed since it was copied".
    public var failures: [String]

    public init(trashed: Int = 0, failures: [String] = []) {
        self.trashed = trashed
        self.failures = failures
    }
}

/// Clears a card by moving its originals to the card's own Trash (its hidden
/// .Trashes folder), so they stay recoverable until the card is formatted in
/// the camera. It never erases, formats or partitions anything, and only moves
/// files whose copies are safe.
public enum CardClearer {
    /// Moves one file to the Trash and says where it went.
    public typealias MoveToTrash = @Sendable (URL) throws -> URL

    public static let systemTrash: MoveToTrash = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    /// Why nothing on this volume may go to the Trash, or nil when it may.
    /// Only a camera card with a DCIM folder qualifies: any removable drive
    /// can be copied from, but a USB stick or backup drive is never cleared.
    public static func refusal(for volume: VolumeInfo, protectedFolders: [URL]) -> String? {
        if !CardRules.verdict(for: volume, protectedFolders: protectedFolders).isCard {
            return "This drive isn't a camera card, so nothing was moved to the Trash."
        }
        if !volume.hasDCIM {
            return "This drive has no DCIM folder, so it may not be a camera card. Nothing was moved to the Trash."
        }
        if volume.isReadOnly {
            return "The card is locked (check the switch on its side), so nothing was moved to the Trash."
        }
        return nil
    }

    /// The card files whose copies are safe: every file this copy verified,
    /// plus files an earlier import brought in whose copy is still in its card
    /// folder at the same size. A file whose copy was deleted stays on the card.
    public static func safelyCopied(report: CopyReport?, check: CardCheck) -> [CardFile] {
        let verified = Set(report?.files.map(\.originalPath) ?? [])
        let fm = FileManager.default
        let earlier = check.alreadyImported.filter { imported in
            let copy = imported.folder.appendingPathComponent(imported.newName)
            let size = (try? fm.attributesOfItem(atPath: copy.path)[.size]) as? Int64
            return size == imported.file.size
        }.map(\.file)
        return check.newFiles.filter { verified.contains($0.relativePath) } + earlier
    }

    /// Moves each file to the card's Trash, first checking it's still the file
    /// that was copied (same size and modified date). A file that can't be
    /// moved is left where it is and listed; the rest still go.
    public static func trash(_ files: [CardFile], cardRoot: URL,
                             moveToTrash: MoveToTrash = systemTrash) -> TrashResult {
        let fm = FileManager.default
        let root = cardRoot.standardizedFileURL.path
        var result = TrashResult()
        for file in files {
            let url = cardRoot.appendingPathComponent(file.relativePath).standardizedFileURL
            guard url.path.hasPrefix(root + "/") else {
                result.failures.append("\(file.relativePath): it isn't on the card")
                continue
            }
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? Int64) == file.size else {
                result.failures.append("\(file.relativePath): it's missing or changed since it was copied")
                continue
            }
            if let then = file.modified, let now = attributes[.modificationDate] as? Date,
               abs(now.timeIntervalSince(then)) > 2 {
                result.failures.append("\(file.relativePath): it changed since it was copied")
                continue
            }
            do {
                _ = try moveToTrash(url)
                result.trashed += 1
            } catch {
                result.failures.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }
        return result
    }
}
