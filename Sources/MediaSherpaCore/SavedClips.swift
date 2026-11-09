import Foundation

/// Which of a card's clips have been through Save to Clips, in `Saved Clips.csv`
/// in its folder: name, size and checksum after saving, as the receipt keeps
/// them from the card. Made as the first clip lands when a backup folder is set,
/// and only then, so cards copied before this keep working as they did: a
/// folder with no such file holds nothing back from the server.
public struct SavedClips: Equatable, Sendable {
    public static let fileName = "Saved Clips.csv"
    static let header = "File,Size (bytes),xxHash64,Saved At"

    public struct Row: Equatable, Sendable {
        public var name: String
        public var size: Int64
        public var checksum: String
        public var savedAt: String
    }

    public private(set) var rows: [Row] = []

    /// Whether the clip has been saved, by its file name in any case.
    public func contains(_ name: String) -> Bool { row(name) != nil }

    public func row(_ name: String) -> Row? {
        rows.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Nil when the card's clips aren't being held back.
    public static func load(from folder: URL) -> SavedClips? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        var saved = SavedClips()
        for line in text.components(separatedBy: "\n").dropFirst() where !line.isEmpty {
            let fields = Receipt.parseLine(line)
            guard fields.count >= 4, let size = Int64(fields[1]) else { continue }
            saved.rows.append(Row(name: fields[0], size: size, checksum: fields[2], savedAt: fields[3]))
        }
        return saved
    }

    /// From now on the card's clips wait for Save to Clips.
    public static func startHolding(in folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds or replaces a clip's row. The file keeps the date it was made, which
    /// says how long the clips have been waiting.
    public static func record(_ row: Row, in folder: URL) throws {
        var saved = load(from: folder) ?? SavedClips()
        saved.rows.removeAll { $0.name.caseInsensitiveCompare(row.name) == .orderedSame }
        saved.rows.append(row)
        let url = folder.appendingPathComponent(fileName)
        let made = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate]
        let lines = [header] + saved.rows.map { [Receipt.csv($0.name), String($0.size), $0.checksum, $0.savedAt].joined(separator: ",") }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let made { try? FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: url.path) }
    }

    /// The clips in a folder that are waiting for Save to Clips; none when its
    /// clips aren't being held back.
    public static func waiting(in folder: URL, fileTypes: FileTypes) -> [String] {
        guard let saved = load(from: folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") && fileTypes.kind(of: $0) == .video && !saved.contains($0) }.sorted()
    }

    /// A card with clips waiting, for the reminders.
    public struct Waiting: Equatable, Sendable {
        public let folder: URL
        public let clips: Int
        public let since: Date
    }

    /// Every card directly in the destination with clips waiting, oldest first.
    public static func waitingCards(in root: URL, fileTypes: FileTypes) -> [Waiting] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder -> Waiting? in
            let count = waiting(in: folder, fileTypes: fileTypes).count
            guard count > 0 else { return nil }
            let since = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(fileName).path))?[.creationDate] as? Date
            return Waiting(folder: folder, clips: count, since: since ?? Date())
        }.sorted { $0.since < $1.since }
    }
}

/// Save to Clips: once the videographer has looked through the card, writes each
/// clip's stars and keywords into it and only then sends it to the server,
/// whose copy can't be changed afterwards and is what reaches Premiere on the
/// editing Macs. A clip with nothing to add goes as it is.
public enum ClipSaver {
    public struct Outcome: Equatable, Sendable {
        public var saved = 0
        public var sent = 0
        /// Not sent: the server isn't connected. Sync With Server will send them.
        public var waitingForServer = 0
        /// Kinds that can't hold it (MXF, MTS): their sidecars are all they have.
        public var sidecarOnly = 0
        public var problems: [String] = []
    }

    public static func serverIsThere(_ root: URL) -> Bool {
        switch BackupVolume.check(root) {
        case .server, .localDrive: true
        default: false
        }
    }

    /// `root` is the backup folder, if one is set. Only reads the card's
    /// receipt and writes to the card's folder here and on the server. Stops
    /// before anything changes if the card's copy never finished, as picking it
    /// up needs its files as they came off the card.
    public static func save(_ clips: [Shot], in folder: URL, root: URL?, now: Date = Date(),
                            isThere: (URL) -> Bool = serverIsThere, progress: (Int) -> Void = { _ in }) -> Outcome {
        var outcome = Outcome()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard names.contains(where: { Receipt.isReceipt($0) }) else {
            outcome.problems.append("This card's copy hasn't finished. Finish it with Copy, then Save to Clips.")
            return outcome
        }
        let serverThere = root.map(isThere) ?? false
        let server = root?.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: now)
        for (index, clip) in clips.enumerated() {
            defer { progress(index + 1) }
            guard let local = clip.primary.destinations.first else { continue }
            do {
                let before = SavedClips.load(from: folder)?.row(local.lastPathComponent)
                let stars = Stars.found(for: clip)
                let keywords = Keywords.found(for: clip)
                if ClipMetadata.canEmbed(local.lastPathComponent) {
                    if stars != nil || !keywords.isEmpty || before != nil {
                        do {
                            try ClipMetadata.embed(stars: stars, keywords: keywords, replacingKeywords: before != nil, into: local)
                        } catch let error as ClipMetadataError {
                            // Only a layout it can't add to: the clip still has to reach the server.
                            guard case .cantWriteInto = error else { throw error }
                            outcome.sidecarOnly += 1
                            outcome.problems.append("\(local.lastPathComponent): \(error.localizedDescription) Its stars and keywords are only in its sidecar.")
                        }
                    }
                } else {
                    outcome.sidecarOnly += 1
                }
                let digest = try CardCopier.hashFile(local, name: local.lastPathComponent, progress: { _ in })
                let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
                let checksum = XXHash64.hex(digest)
                try SavedClips.record(.init(name: local.lastPathComponent, size: size, checksum: checksum, savedAt: stamp), in: folder)
                outcome.saved += 1
                guard let server else { continue }
                guard serverThere else {
                    outcome.waitingForServer += 1
                    continue
                }
                switch ServerBackup.send(local, checksum: checksum, to: server) {
                case .copied:
                    outcome.sent += 1
                case .alreadyThere:
                    break
                case .different:
                    outcome.problems.append("\(local.lastPathComponent): an earlier copy is already on the server and can't be changed. Ask the admin to delete it, then Sync.")
                case .badCopy:
                    outcome.problems.append("\(local.lastPathComponent): the server's copy didn't check out; ask the admin to delete it, then Sync.")
                case let .failed(reason):
                    outcome.problems.append("\(local.lastPathComponent): \(reason)")
                }
                let sidecar = local.deletingLastPathComponent().appendingPathComponent(clip.xmpName)
                if FileManager.default.fileExists(atPath: sidecar.path), ServerBackup.send(sidecar, checksum: nil, to: server) == .different {
                    outcome.problems.append("\(clip.xmpName): an earlier copy is already on the server and can't be changed.")
                }
            } catch {
                outcome.problems.append("\(local.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
