import Foundation

/// Brings the server's copy of one card up to date after culling: whatever
/// the backup missed (the server was offline), the sidecars with the stars
/// and keywords, and the exported `•To Campanion` JPEGs. Within what the
/// photographers' accounts allow (create, never rename, overwrite or delete):
/// it only ever creates files. A file already on the server is never touched;
/// one that differs from this Mac's is listed, for the admin to delete if it
/// should be sent again (how re-edits have always been done). Nothing missing
/// here is ever removed there: the server is the final destination, and older
/// cards may be gone from this Mac.
public enum ServerSync {
    /// Folders inside a card folder that go up with it: Lightroom exports.
    /// "•To Campanion", "•To Campanion E", "•To Campanion K 7-25" ...
    public static let exportFolderPrefix = "•To Campanion"

    public struct Item: Equatable, Sendable {
        /// Inside the card folder, e.g. "A_0001.xmp" or "•To Campanion/A_0001.jpg".
        public let path: String
        public let local: URL
        public let server: URL
    }

    public struct Plan: Equatable, Sendable {
        public let localFolder: URL
        public let serverFolder: URL
        /// Not on the server yet: each will be created there.
        public var adds: [Item] = []
        /// Already on the server and the same.
        public var unchanged = 0
        /// On the server but different from this Mac's, and newer here: can't be updated.
        public var cantUpdate: [String] = []

        /// Counts for the summary, by kind.
        public var addedSidecars: Int { adds.count { Stars.isSidecar($0.path) } }
        public var addedExports: Int { adds.count { $0.path.contains("/") } }
        public var addedOriginals: Int { adds.count - addedSidecars - addedExports }
        public var isEmpty: Bool { adds.isEmpty }
    }

    public struct Outcome: Equatable, Sendable {
        public var added = 0
        public var alreadyThere = 0
        public var problems: [String] = []
    }

    /// Compares the card's folder here with its folder on the server. Only reads.
    public static func plan(local: URL, server: URL) throws -> Plan {
        let fm = FileManager.default
        var plan = Plan(localFolder: local, serverFolder: server)
        for path in try files(in: local) {
            let here = local.appendingPathComponent(path)
            let there = server.appendingPathComponent(path)
            guard let theirs = try? fm.attributesOfItem(atPath: there.path) else {
                plan.adds.append(Item(path: path, local: here, server: there))
                continue
            }
            // The server has its own receipt from the backup; a different one isn't a problem.
            if Receipt.isReceipt((path as NSString).lastPathComponent) {
                plan.unchanged += 1
                continue
            }
            let mine = try fm.attributesOfItem(atPath: here.path)
            let same: Bool
            if Stars.isSidecar(path) {
                same = (try? Data(contentsOf: here)) == (try? Data(contentsOf: there))
            } else {
                // Big files over the network: the same size is taken as the same file.
                same = (mine[.size] as? Int64) == (theirs[.size] as? Int64)
            }
            if same {
                plan.unchanged += 1
            } else if let newer = mine[.modificationDate] as? Date, let older = theirs[.modificationDate] as? Date,
                      newer <= older, Stars.isSidecar(path) || path.contains("/") {
                // Newer on the server: work done there is never undone from here.
                plan.unchanged += 1
            } else {
                plan.cantUpdate.append(path)
            }
        }
        return plan
    }

    /// Creates each missing file on the server, checking every one. Tells
    /// `progress` after each file.
    public static func run(_ plan: Plan, progress: (Int) -> Void = { _ in },
                           isCancelled: () -> Bool = { false }) -> Outcome {
        var outcome = Outcome()
        for (index, item) in plan.adds.enumerated() {
            if isCancelled() { break }
            switch ServerBackup.send(item.local, checksum: nil, to: item.server.deletingLastPathComponent()) {
            case .copied: outcome.added += 1
            case .alreadyThere: outcome.alreadyThere += 1
            case .different: outcome.problems.append("\(item.path): a different file appeared on the server; left as it is")
            case .badCopy: outcome.problems.append("\(item.path): the server's copy didn't check out; ask the admin to delete it, then Sync again")
            case let .failed(reason): outcome.problems.append("\(item.path): \(reason)")
            }
            progress(index + 1)
        }
        return outcome
    }

    /// The card folder's own files and its export folders' files, as paths
    /// inside it, skipping hidden files and Capture One's working folders.
    static func files(in folder: URL) throws -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        let top = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for url in top.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isFolder {
                paths.append(name)
            } else if name.lowercased().hasPrefix(exportFolderPrefix.lowercased()) {
                // /tmp and /private/tmp are the same folder: compare them the same way.
                let base = url.resolvingSymlinksInPath().path
                let inside = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let file = inside?.nextObject() as? URL {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    paths.append(name + "/" + file.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
                }
            }
        }
        return paths.sorted()
    }
}
