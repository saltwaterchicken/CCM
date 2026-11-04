import Foundation

/// Copies verified local files to the server, within what the photographers'
/// accounts allow there: create new files and folders, never overwrite,
/// rename or delete (photographer, 2026-10-27; the admin deletes old work
/// before it's sent again). So each file is written once, straight under its
/// final name, then read back and checked against the card's checksum. A file
/// already there is compared, never replaced. It reads the local copy, never
/// the card, so the card can be trashed and ejected while it runs.
public enum ServerBackup {
    public enum Result: Equatable, Sendable {
        /// Written and read back matching the card.
        case copied
        /// Already on the server, matching the card.
        case alreadyThere
        /// A different file of that name is on the server; left as it is.
        case different
        /// Written but the read-back didn't match. Left on the server (it
        /// can't be deleted from this account) for the admin to remove.
        case badCopy
        /// Couldn't be written; a part-written file may be left on the server.
        case failed(String)

        public var isSafe: Bool { self == .copied || self == .alreadyThere }
    }

    /// Sends one file into the server's card folder (made if it isn't there).
    /// `checksum` is the card's xxHash64 for it, from the copy's report; nil
    /// (Sync, long after the copy) checks the server's copy against the
    /// local one as it was sent.
    public static func send(_ local: URL, checksum: String?, to folder: URL,
                            isCancelled: () -> Bool = { false }) -> Result {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(local.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed("couldn't make \(folder.lastPathComponent) on the server: \(error.localizedDescription)")
        }
        if fm.fileExists(atPath: target.path) {
            return matches(target, checksum: checksum ?? localChecksum(local)) ? .alreadyThere : .different
        }
        // O_EXCL: created now or not at all, so nothing already there is ever written to.
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { return matches(target, checksum: checksum ?? localChecksum(local)) ? .alreadyThere : .different }
            return .failed(String(cString: strerror(errno)))
        }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let reader = try FileHandle(forReadingFrom: local)
            defer { try? reader.close() }
            var hasher = XXHash64()
            while true {
                if isCancelled() { throw CopyError.cancelled }
                let more = try autoreleasepool { () throws -> Bool in
                    let chunk = try reader.read(upToCount: CardCopier.chunkSize) ?? Data()
                    if chunk.isEmpty { return false }
                    hasher.update(chunk)
                    try writer.write(contentsOf: chunk)
                    return true
                }
                if !more { break }
            }
            try writer.synchronize()
            try writer.close()
            let sent = XXHash64.hex(hasher.digest())
            guard matches(target, checksum: sent) else { return .badCopy }
            // A sidecar may have been given stars since it was verified, and goes as it is now;
            // anything else must still be exactly what came off the card.
            if let checksum, sent != checksum, !Stars.isSidecar(local.lastPathComponent) {
                return .failed("the copy on this Mac no longer matches the card, so the server's copy may be wrong")
            }
        } catch {
            try? writer.close()
            return .failed(error.localizedDescription)
        }
        // Keeping the card's date is a change to the file, which some accounts can't make; that's fine.
        if let modified = (try? fm.attributesOfItem(atPath: local.path))?[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return .copied
    }

    /// Writes a small file (the receipt) once; nil when done, else why not.
    public static func create(_ data: Data, at target: URL) -> String? {
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { return String(cString: strerror(errno)) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try writer.write(contentsOf: data)
            try writer.synchronize()
            try writer.close()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func localChecksum(_ file: URL) -> String {
        (try? CardCopier.hashFile(file, name: file.lastPathComponent, progress: { _ in })).map(XXHash64.hex) ?? ""
    }

    private static func matches(_ file: URL, checksum: String) -> Bool {
        guard let digest = try? CardCopier.hashFile(file, name: file.lastPathComponent, progress: { _ in }) else { return false }
        return XXHash64.hex(digest) == checksum
    }
}

/// One card's backup to the server, running beside the local copy: each file
/// is queued as soon as the local copy verifies it and sent one at a time, so
/// the local copy, trash and eject never wait. When the card is done the
/// server gets its own receipt, listing what reached it. Safe to call from
/// the copying thread.
public final class ServerBackupJob: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        public var queued = 0
        public var sent = 0
        /// Files already on the server, matching.
        public var alreadyThere = 0
        /// One line per file that didn't reach the server safely.
        public var problems: [String] = []
        /// The server went away part way; the rest wait for Sync With Server.
        public var wentAway = false
        /// All files handled and the receipt written (or why not).
        public var finished = false
        public var receiptProblem: String?

        public var handled: Int { sent + alreadyThere + problems.count }
    }

    public let folder: URL
    private let root: URL
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var status = Status()
    private var safe: [CopiedFile] = []
    private let changed: @Sendable (Status) -> Void

    /// - Parameters:
    ///   - folder: the card's folder on the server.
    ///   - root: the backup folder it's in, to tell when the server has gone.
    ///   - changed: told after every file, on the backup's own thread.
    public init(folder: URL, root: URL, changed: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.folder = folder
        self.root = root
        self.changed = changed
        queue.name = "Card Ingest server backup"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    public var current: Status { lock.withLock { status } }

    /// Queues a file the local copy has just verified.
    public func send(_ file: CopiedFile) {
        guard let local = file.destinations.first else { return }
        update { $0.queued += 1 }
        queue.addOperation { [self] in
            if lock.withLock({ status.wentAway }) { return update { $0.problems.append("\(file.newName): not sent") } }
            let result = ServerBackup.send(local, checksum: file.checksum, to: folder)
            switch result {
            case .copied:
                update { $0.sent += 1; safe.append(file) }
            case .alreadyThere:
                update { $0.alreadyThere += 1; safe.append(file) }
            case .different:
                update { $0.problems.append("\(file.newName): a different file of that name is already on the server; left as it is") }
            case .badCopy:
                update { $0.problems.append("\(file.newName): the server's copy didn't check out; ask the admin to delete it, then Sync") }
            case let .failed(reason):
                let gone: Bool
                switch BackupVolume.check(root) {
                case .server, .localDrive: gone = false
                default: gone = true
                }
                update {
                    $0.wentAway = $0.wentAway || gone
                    $0.problems.append(gone ? "\(file.newName): not sent, the server went away" : "\(file.newName): \(reason)")
                }
            }
        }
    }

    /// After the local copy: writes the server's receipt once everything
    /// queued has been handled, listing only what reached the server.
    public func finish(_ report: CopyReport?) {
        queue.addOperation { [self] in
            var problem: String?
            if let report {
                let reached = lock.withLock { safe }
                var server = report
                server.destinationFolders = [folder]
                server.files = report.files.filter { file in reached.contains { $0.newName == file.newName } }
                server.receipts = []
                let receipt = folder.appendingPathComponent(Receipt.fileName(for: server))
                // Already there from an earlier try at this same copy: it stays as it is.
                if !server.files.isEmpty, !lock.withLock({ status.wentAway }), !FileManager.default.fileExists(atPath: receipt.path) {
                    problem = ServerBackup.create(Data(Receipt.text(for: server).utf8), at: receipt)
                }
            }
            update {
                $0.finished = true
                $0.receiptProblem = problem
            }
        }
    }

    /// Waits for everything queued (tests).
    public func wait() { queue.waitUntilAllOperationsAreFinished() }

    private func update(_ change: (inout Status) -> Void) {
        let now = lock.withLock { () -> Status in
            change(&status)
            return status
        }
        changed(now)
    }
}
