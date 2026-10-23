import Foundation

/// The outcome for one file.
public struct CopiedFile: Equatable, Sendable {
    /// The copy's name inside the card folder.
    public var newName: String
    /// Where it came from on the card, e.g. "DCIM/100CANON/IMG_1234.CR3".
    public var originalPath: String
    public var size: Int64
    /// xxHash64 of the original on the card, as 16 hex digits.
    public var checksum: String
    /// One entry per destination (main, then backup if set).
    public var destinations: [URL]
    /// True when it was already at the destination with the same checksum,
    /// for example after an earlier copy was interrupted.
    public var alreadyThere: Bool
}

public struct CopyReport: Sendable {
    public var cardName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var destinationFolders: [URL]
    /// The `{iseq}` this card used, when known.
    public var importNumber: Int?
    public var files: [CopiedFile]
    public var receipts: [URL]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum CopyError: Error, LocalizedError, Equatable {
    case notEnoughSpace(folder: String, needed: Int64, available: Int64)
    case readFailed(file: String, reason: String)
    case writeFailed(file: String, reason: String)
    case mismatch(file: String, destination: String)
    case differentFileAlreadyThere(file: String, destination: String)
    case cancelled

    public var errorDescription: String? {
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch self {
        case let .notEnoughSpace(folder, needed, available):
            return "Not enough space in \(folder): the card needs \(bytes(needed)) and only \(bytes(available)) is free."
        case let .readFailed(file, reason):
            return "Couldn't read \(file) from the card: \(reason)"
        case let .writeFailed(file, reason):
            return "Couldn't write \(file): \(reason)"
        case let .mismatch(file, destination):
            return "The copy of \(file) at \(destination) doesn't match the original. It may be a bad card, cable or drive."
        case let .differentFileAlreadyThere(file, destination):
            return "A different file named \(file) is already at \(destination). Nothing was overwritten."
        case .cancelled:
            return "Copying was stopped."
        }
    }
}

/// Copies a card's files to one or two destination folders, checks every copy
/// against the original with xxHash64, and writes a receipt. It only reads
/// from the card; it never changes, moves or deletes anything on it.
public enum CardCopier {
    static let chunkSize = 8 * 1024 * 1024

    /// - Parameters:
    ///   - progress: called with bytes processed so far and the total to process.
    ///   - isCancelled: checked between chunks; return true to stop.
    public static func copy(
        cardRoot: URL,
        cardName: String,
        files: [PlannedFile],
        to destinationFolders: [URL],
        importNumber: Int? = nil,
        now: Date = Date(),
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> CopyReport {
        let fm = FileManager.default
        let totalBytes = files.reduce(0) { $0 + $1.source.size }

        for folder in destinationFolders {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw CopyError.writeFailed(file: folder.path, reason: error.localizedDescription)
            }
            if let available = availableSpace(at: folder), available < totalBytes {
                throw CopyError.notEnoughSpace(folder: folder.path, needed: totalBytes, available: available)
            }
        }

        // Each byte is read once from the card and written, then read back once
        // per destination to verify.
        let workTotal = totalBytes * Int64(1 + 2 * destinationFolders.count)
        var workDone: Int64 = 0
        var results: [CopiedFile] = []

        for planned in files {
            let file = planned.source
            let source = cardRoot.appendingPathComponent(file.relativePath)
            let targets = destinationFolders.map { $0.appendingPathComponent(planned.newName) }
            var alreadyThere = true
            var pending: [(final: URL, temp: URL)] = []
            var writers: [FileHandle] = []

            do {
                defer { for w in writers { try? w.close() } }
                for target in targets {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { continue }
                    alreadyThere = false
                    let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).partial")
                    try? fm.removeItem(at: temp)
                    guard fm.createFile(atPath: temp.path, contents: nil) else {
                        throw CopyError.writeFailed(file: file.relativePath, reason: "couldn't create \(temp.path)")
                    }
                    writers.append(try FileHandle(forWritingTo: temp))
                    pending.append((target, temp))
                }

                // Read the original once, hashing it and writing it to every new copy.
                let reader: FileHandle
                do { reader = try FileHandle(forReadingFrom: source) } catch {
                    throw CopyError.readFailed(file: file.relativePath, reason: error.localizedDescription)
                }
                defer { try? reader.close() }
                var hasher = XXHash64()
                while true {
                    if isCancelled() { throw CopyError.cancelled }
                    let chunk: Data
                    do { chunk = try reader.read(upToCount: chunkSize) ?? Data() } catch {
                        throw CopyError.readFailed(file: file.relativePath, reason: error.localizedDescription)
                    }
                    if chunk.isEmpty { break }
                    hasher.update(chunk)
                    for w in writers {
                        do { try w.write(contentsOf: chunk) } catch {
                            throw CopyError.writeFailed(file: file.relativePath, reason: error.localizedDescription)
                        }
                    }
                    workDone += Int64(chunk.count) * Int64(1 + writers.count)
                    progress(workDone, workTotal)
                }
                for w in writers {
                    do {
                        try w.synchronize()
                        try w.close()
                    } catch {
                        throw CopyError.writeFailed(file: file.relativePath, reason: error.localizedDescription)
                    }
                }
                writers.removeAll()
                let checksum = hasher.digest()

                // Read every copy back from the destination and compare.
                for target in targets {
                    let written = pending.first { $0.final == target }?.temp ?? target
                    let copyChecksum = try hashFile(written, name: file.relativePath) { bytes in
                        workDone += bytes
                        progress(workDone, workTotal)
                    }
                    if copyChecksum != checksum {
                        if written == target {
                            throw CopyError.differentFileAlreadyThere(file: planned.newName, destination: target.path)
                        }
                        throw CopyError.mismatch(file: file.relativePath, destination: target.path)
                    }
                }

                // Only verified copies get their real name.
                let modified = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date
                for (final, temp) in pending {
                    do {
                        try fm.moveItem(at: temp, to: final)
                        if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: final.path) }
                    } catch {
                        throw CopyError.writeFailed(file: file.relativePath, reason: error.localizedDescription)
                    }
                }
                results.append(CopiedFile(newName: planned.newName, originalPath: file.relativePath, size: file.size,
                                          checksum: XXHash64.hex(checksum), destinations: targets,
                                          alreadyThere: alreadyThere))
            } catch {
                for (_, temp) in pending { try? fm.removeItem(at: temp) }
                throw error
            }
        }

        var report = CopyReport(cardName: cardName, startedAt: now, finishedAt: Date(),
                                destinationFolders: destinationFolders, importNumber: importNumber,
                                files: results, receipts: [])
        for folder in destinationFolders {
            report.receipts.append(try Receipt.write(report, in: folder))
        }
        return report
    }

    static func hashFile(_ url: URL, name: String, progress: (Int64) -> Void) throws -> UInt64 {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw CopyError.readFailed(file: name, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        #if canImport(Darwin)
        // Read from the drive itself, not from memory, so the check is real.
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        #endif
        var hasher = XXHash64()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: chunkSize) ?? Data() } catch {
                throw CopyError.readFailed(file: name, reason: error.localizedDescription)
            }
            if chunk.isEmpty { break }
            hasher.update(chunk)
            progress(Int64(chunk.count))
        }
        return hasher.digest()
    }

    static func availableSpace(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// The receipt: a spreadsheet-friendly CSV listing every file, its size and its
/// checksum, saved next to the copies.
public enum Receipt {
    public static func write(_ report: CopyReport, in folder: URL) throws -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let iso = ISO8601DateFormatter()
        let safeCard = NameTemplate.clean(report.cardName)
        let url = folder.appendingPathComponent("Receipt_\(safeCard)_\(stamp.string(from: report.startedAt)).csv")

        var lines = [header]
        for file in report.files {
            lines.append([csv(file.newName), csv(file.originalPath), String(file.size), file.checksum,
                          file.alreadyThere ? "yes (already there)" : "yes",
                          iso.string(from: report.finishedAt)].joined(separator: ","))
        }
        lines.append("")
        lines.append("Card,\(csv(report.cardName))")
        lines.append("Files,\(report.files.count)")
        lines.append("Total bytes,\(report.totalBytes)")
        if let number = report.importNumber { lines.append("Import number,\(number)") }
        lines.append("Started,\(iso.string(from: report.startedAt))")
        lines.append("Finished,\(iso.string(from: report.finishedAt))")
        lines.append("Copies,\(csv(report.destinationFolders.map(\.path).joined(separator: " | ")))")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CopyError.writeFailed(file: url.lastPathComponent, reason: error.localizedDescription)
        }
        return url
    }

    static let header = "File,Original Path,Size (bytes),xxHash64,Verified,Copied At"

    static func csv(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// True for a receipt's file name, optionally only one for the named card.
    static func isReceipt(_ fileName: String, card: String? = nil) -> Bool {
        let prefix = card.map { "Receipt_\(NameTemplate.clean($0))_" } ?? "Receipt_"
        return fileName.hasPrefix(prefix) && fileName.lowercased().hasSuffix(".csv")
    }

    struct Row: Hashable {
        var newName: String
        var originalPath: String
        var size: Int64
    }

    /// Reads back the files and import number from a receipt this app wrote.
    /// Nil for anything else, including Milestone 1 receipts.
    static func read(_ url: URL) -> (rows: [Row], importNumber: Int?)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == header else { return nil }
        var rows: [Row] = []
        var importNumber: Int?
        var inSummary = false
        for line in lines.dropFirst() {
            if line.isEmpty { inSummary = true; continue }
            let fields = parseLine(line)
            if inSummary {
                if fields.count == 2, fields[0] == "Import number" { importNumber = Int(fields[1]) }
            } else {
                guard fields.count >= 3, let size = Int64(fields[2]) else { return nil }
                rows.append(Row(newName: fields[0], originalPath: fields[1], size: size))
            }
        }
        return (rows, importNumber)
    }

    /// Splits one CSV line, undoing `csv(_:)`.
    static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var chars = line.makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" {
                    // A doubled quote is a quote; a single one ends the quoted part.
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," { fields.append(field); field = "" } else { field.append(next) }
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                fields.append(field)
                field = ""
            } else {
                field.append(c)
            }
        }
        fields.append(field)
        return fields
    }
}
