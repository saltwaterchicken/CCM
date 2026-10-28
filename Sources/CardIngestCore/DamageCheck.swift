import Foundation

/// Spots a picture or clip that was damaged on the card before it was copied,
/// for example when the battery went flat or the card came out while the
/// camera was still writing. The copy is the card's file byte for byte (the
/// checksum proves it), so this reads the copy and never the card.
///
/// It only looks at how the file is put together, never at the picture:
/// a file that stops part way through, points past its own end, or ends in a
/// long run of blank bytes. A file whose data is scrambled but still the
/// right shape gets past it. When the layout isn't one it knows, it says
/// nothing rather than guess.
public enum DamageCheck {
    /// A file ending in at least this much of one blank byte (0x00 or 0xFF)
    /// was cut short: room set aside for it on the card that was never filled.
    static let blankTail = 256 * 1024
    /// Never walk more boxes or IFDs than this, so a scrambled file can't loop.
    static let maxSteps = 256

    /// Why the file looks damaged, in plain words, or nil when it looks whole
    /// (or isn't a kind it checks). Sidecars and other small files aren't checked.
    public static func problem(at url: URL, fileTypes: FileTypes = FileTypes()) -> String? {
        let kind = fileTypes.kind(of: url.lastPathComponent)
        guard kind == .raw || kind == .photo || kind == .video,
              let file = try? Reader(url) else { return nil }
        defer { file.close() }
        if file.size == 0 { return "it's empty: the camera didn't write anything into it." }
        guard let head = file.read(at: 0, count: 16), head.count >= 8 else {
            return "it's only \(file.size) bytes long, too short to be a picture."
        }
        let b = [UInt8](head)

        if b[0] == 0xFF, b[1] == 0xD8 { return jpeg(file) }
        if b.starts(with: Array("FUJIFILM".utf8)) { return raf(file) ?? blank(file) }
        if let type = String(bytes: b[4..<8], encoding: .ascii), Self.boxTypes.contains(type) {
            return isoMedia(file, isVideo: kind == .video)
        }
        if (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return tiff(file) ?? blank(file) }
        return kind == .video ? nil : blank(file)
    }

    // MARK: - Each kind of file

    /// A JPEG's picture ends with the FF D9 marker, usually at the very end of
    /// the file, perhaps with a little padding after it.
    static func jpeg(_ file: Reader) -> String? {
        if let problem = blank(file) { return problem }
        let tailSize = Int(min(file.size, 64 * 1024))
        guard let tail = file.read(at: file.size - Int64(tailSize), count: tailSize) else { return nil }
        var end = tail.endIndex
        while end > tail.startIndex, tail[end - 1] == 0x00 || tail[end - 1] == 0xFF { end -= 1 }
        if end - tail.startIndex >= 2, tail[end - 1] == 0xD9, tail[end - 2] == 0xFF { return nil }
        // Something else after the picture (some phones add a clip there): look for
        // the marker after the picture data starts. It can't appear inside that data,
        // so the small preview's marker near the top of the file doesn't count.
        return jpegHasEnd(file) == false ? "it stops part way through: the end of the picture is missing." : nil
    }

    /// Whether the main picture's FF D9 marker is anywhere in the file; nil
    /// when the layout isn't one this knows.
    static func jpegHasEnd(_ file: Reader) -> Bool? {
        // Step over the segments before the picture data (each says how long it is).
        var offset: Int64 = 2
        var steps = 0
        while true {
            steps += 1
            guard steps < maxSteps else { return nil }
            guard let marker = file.read(at: offset, count: 4), marker.count == 4 else { return false }
            let m = [UInt8](marker)
            guard m[0] == 0xFF else { return nil }
            if m[1] == 0xFF { offset += 1; continue }
            let length = Int64(m[2]) << 8 | Int64(m[3])
            offset += 2 + length
            if m[1] == 0xDA { break }
        }
        var previous: UInt8 = 0
        while offset < file.size {
            guard let chunk = file.read(at: offset, count: 4 * 1024 * 1024), !chunk.isEmpty else { return nil }
            for byte in chunk {
                if previous == 0xFF, byte == 0xD9 { return true }
                previous = byte
            }
            offset += Int64(chunk.count)
        }
        return false
    }

    /// TIFF-based RAWs (CR2, NEF, ARW, DNG, ORF, RW2, PEF ...): every block
    /// of picture data the file lists must lie inside the file.
    static func tiff(_ file: Reader) -> String? {
        guard let head = file.read(at: 0, count: 8), head.count == 8 else { return nil }
        let little = head[head.startIndex] == 0x49
        let u16 = { (d: Data, at: Int) -> Int in
            let i = d.startIndex + at
            return little ? Int(d[i]) | Int(d[i + 1]) << 8 : Int(d[i]) << 8 | Int(d[i + 1])
        }
        let u32 = { (d: Data, at: Int) -> Int64 in
            let i = d.startIndex + at
            let v = [d[i], d[i + 1], d[i + 2], d[i + 3]].map { Int64($0) }
            return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
        }
        /// The tag's values, read from the entry or from where it points.
        func values(_ entry: Data) -> [Int64] {
            let type = u16(entry, 2), count = Int(u32(entry, 4))
            let width: Int
            switch type {
            case 3: width = 2
            case 4, 13: width = 4
            default: return []
            }
            guard count > 0, count <= 100_000 else { return [] }
            let bytes = count * width
            let data: Data
            if bytes <= 4 {
                data = entry.subdata(in: (entry.startIndex + 8)..<(entry.startIndex + 12))
            } else {
                guard let read = file.read(at: u32(entry, 8), count: bytes), read.count == bytes else { return [] }
                data = read
            }
            return (0..<count).map { width == 2 ? Int64(u16(data, $0 * 2)) : u32(data, $0 * 4) }
        }

        // The main chain of IFDs is followed to its end; the extra ones its
        // entries point to (RAW data, Exif) aren't, as some cameras leave junk there.
        var queue: [(offset: Int64, chain: Bool)] = [(u32(head, 4), true)]
        var seen: Set<Int64> = []
        var furthest: Int64 = 0
        var steps = 0
        let cutShort = "it stops part way through: part of the picture data is missing."
        while let next = queue.popLast(), steps < maxSteps {
            steps += 1
            let (offset, chain) = next
            guard offset > 0, seen.insert(offset).inserted else { continue }
            guard offset + 2 <= file.size else { return cutShort }
            guard let countData = file.read(at: offset, count: 2), countData.count == 2 else { continue }
            let count = u16(countData, 0)
            guard count > 0, count < 1000 else { continue }
            let length = count * 12 + 4
            guard offset + 2 + Int64(length) <= file.size else { return cutShort }
            guard let entries = file.read(at: offset + 2, count: length), entries.count == length else { continue }
            var tags: [Int: [Int64]] = [:]
            for i in 0..<count {
                let entry = entries.subdata(in: (entries.startIndex + i * 12)..<(entries.startIndex + i * 12 + 12))
                let tag = u16(entry, 0)
                switch tag {
                case 273, 279, 324, 325, 513, 514, 330, 34665: tags[tag] = values(entry)
                default: break
                }
            }
            // Strips, tiles and the built-in preview: where each starts and how long it is.
            for (starts, lengths) in [(273, 279), (324, 325), (513, 514)] {
                guard let s = tags[starts], let l = tags[lengths], s.count == l.count else { continue }
                for (start, size) in zip(s, l) where size > 0 { furthest = max(furthest, start + size) }
            }
            for sub in (tags[330] ?? []) + (tags[34665] ?? []) { queue.append((sub, false)) }
            if chain { queue.append((u32(entries, count * 12), true)) }
        }
        if furthest > file.size {
            return "it stops part way through: \(missing(furthest - file.size)) of the picture data is missing."
        }
        return nil
    }

    /// Fujifilm RAF: a fixed header says where the preview and the RAW data are.
    static func raf(_ file: Reader) -> String? {
        guard let header = file.read(at: 84, count: 24), header.count == 24 else {
            return "it stops part way through: the end of the picture is missing."
        }
        let be = { (at: Int) -> Int64 in
            let i = header.startIndex + at
            return Int64(header[i]) << 24 | Int64(header[i + 1]) << 16 | Int64(header[i + 2]) << 8 | Int64(header[i + 3])
        }
        // Preview, metadata, RAW data: offset then length, each.
        let furthest = stride(from: 0, to: 24, by: 8).map { be($0) + be($0 + 4) }.max() ?? 0
        if furthest > file.size {
            return "it stops part way through: \(missing(furthest - file.size)) of the picture data is missing."
        }
        return nil
    }

    /// The box types a QuickTime or MP4 style file (MOV, MP4, CR3, HEIC) starts with.
    static let boxTypes: Set<String> = ["ftyp", "moov", "mdat", "wide", "free", "skip", "pnot", "uuid"]

    /// MOV, MP4, CR3 and HEIC: boxes one after another, each saying how long it
    /// is, filling the file exactly. A clip needs its index (`moov`), which
    /// the camera writes when recording stops, so a clip cut short has none.
    static func isoMedia(_ file: Reader, isVideo: Bool) -> String? {
        var offset: Int64 = 0
        var hasIndex = false
        var steps = 0
        while offset < file.size, steps < maxSteps {
            steps += 1
            guard offset + 8 <= file.size, let header = file.read(at: offset, count: 16), header.count >= 8 else {
                return "it stops part way through: the end is missing."
            }
            let h = [UInt8](header)
            var size = Int64(h[0]) << 24 | Int64(h[1]) << 16 | Int64(h[2]) << 8 | Int64(h[3])
            let type = String(bytes: h[4..<8], encoding: .ascii) ?? ""
            if type == "moov" { hasIndex = true }
            if size == 1 {
                guard h.count == 16 else { return "it stops part way through: the end is missing." }
                size = h[8..<16].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            } else if size == 0 {
                // The last box, running to the end of the file.
                size = file.size - offset
            }
            guard size >= 8 else { return nil }
            if offset + size > file.size {
                return "it stops part way through: \(missing(offset + size - file.size)) of it is missing."
            }
            offset += size
        }
        if isVideo, !hasIndex, steps < maxSteps {
            return "the clip was never finished (it has no index), so it won't play. Recording may have stopped suddenly."
        }
        return nil
    }

    /// A file ending in a long run of one blank byte.
    static func blank(_ file: Reader) -> String? {
        let tailSize = Int(min(file.size, Int64(blankTail)))
        guard tailSize >= blankTail, let tail = file.read(at: file.size - Int64(tailSize), count: tailSize),
              let last = tail.last, last == 0x00 || last == 0xFF, tail.allSatisfy({ $0 == last }) else { return nil }
        // How far the blank run goes back, a megabyte at a time.
        var run = Int64(tailSize)
        while run < file.size {
            let step = Int(min(file.size - run, 1024 * 1024))
            guard let more = file.read(at: file.size - run - Int64(step), count: step) else { break }
            if let notBlank = more.lastIndex(where: { $0 != last }) {
                run += Int64(more.endIndex - notBlank - 1)
                break
            }
            run += Int64(step)
        }
        if run >= file.size { return "it's blank: the camera didn't write the picture into it." }
        return "the last \(missing(run)) of it is blank: the camera didn't finish writing it."
    }

    static func missing(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Reads parts of a file by position.
    final class Reader {
        let handle: FileHandle
        let size: Int64

        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            size = Int64(try handle.seekToEnd())
        }

        func read(at offset: Int64, count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset < size else { return nil }
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: count) ?? Data()
            } catch {
                return nil
            }
        }

        func close() { try? handle.close() }
    }
}
