import Foundation
import ImageIO

public enum ClipMetadataError: Error, LocalizedError, Equatable {
    case cantWriteInto(String)
    case mediaChanged(String)
    case didntReadBack(String)

    public var errorDescription: String? {
        switch self {
        case let .cantWriteInto(name):
            return "\(name) isn't laid out in a way the app can safely add to (the camera may not have finished it). It wasn't changed."
        case let .mediaChanged(name):
            return "Saving to \(name) would have changed its picture or sound, so it wasn't changed."
        case let .didntReadBack(name):
            return "The stars and keywords didn't read back from \(name), so it wasn't changed."
        }
    }
}

/// Stars and keywords inside a clip, where Premiere Pro reads them (a sidecar
/// reaches nothing in the video workflow). The video isn't re-saved: an XMP
/// block goes where Adobe puts it, in a top-level `uuid` box in an MP4 and in
/// `moov/udta/XMP_` in a QuickTime file, and the `mdat` holding the picture and
/// sound never moves or changes. The work is done on a copy that replaces the
/// clip only once its media is proved identical, so the clip is never left half-changed.
public enum ClipMetadata {
    static let xmpUUID = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])
    private static let padding = 2048

    private struct Box {
        let offset: UInt64
        let size: UInt64
        let header: UInt64
        let type: String
        var end: UInt64 { offset + size }
    }

    /// MP4, M4V and MOV can hold it. MXF, MTS, AVI and the rest stay on their sidecars.
    public static func canEmbed(_ name: String) -> Bool {
        ["mp4", "m4v", "mov"].contains((name as NSString).pathExtension.lowercased())
    }

    /// The stars and keywords inside a clip.
    public static func read(from url: URL) -> (stars: Int?, keywords: [String]) {
        guard let reader = try? FileHandle(forReadingFrom: url), let data = try? existingBlock(in: reader),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return (nil, []) }
        defer { try? reader.close() }
        return (Stars.rating(in: metadata), Keywords.keywords(in: metadata))
    }

    /// Writes the stars and keywords into the clip, keeping everything else in
    /// any block already there (Premiere's, say). Keywords add to those inside
    /// unless `replacingKeywords`, for a clip saved before, whose list is ours.
    /// Keeps the clip's modified date.
    public static func embed(stars: Int?, keywords: [String], replacingKeywords: Bool = false, into url: URL) throws {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(name).saving")
        try? fm.removeItem(at: temp)
        // A clone on the Mac's own drive: instant, and takes no more room.
        try fm.copyItem(at: url, to: temp)
        defer { try? fm.removeItem(at: temp) }
        let writer = try FileHandle(forUpdating: temp)
        do {
            defer { try? writer.close() }
            let boxes = try topLevel(in: writer)
            guard boxes.contains(where: { $0.type == "moov" }) else { throw ClipMetadataError.cantWriteInto(name) }
            let block = try existingBlock(in: writer)
            let wanted = try merged(block, stars: stars, keywords: keywords, replacing: replacingKeywords, name: name)
            if try isQuickTime(writer, boxes) {
                try writeQuickTime(wanted, to: writer, boxes: boxes, name: name)
            } else {
                try writeMP4(wanted.packet(atLeast: 0), to: writer, boxes: boxes)
            }
            try writer.synchronize()
        }
        guard try mediaDigest(of: temp) == mediaDigest(of: url) else { throw ClipMetadataError.mediaChanged(name) }
        let inside = read(from: temp)
        let expected = replacingKeywords ? Keywords.merged([], adding: keywords)
            : Keywords.merged(read(from: url).keywords, adding: keywords)
        guard stars.map({ $0 == inside.stars }) ?? true,
              inside.keywords.map({ $0.lowercased() }) == expected.map({ $0.lowercased() }) else {
            throw ClipMetadataError.didntReadBack(name)
        }
        if let modified = try fm.attributesOfItem(atPath: url.path)[.modificationDate] {
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: temp.path)
        }
        guard rename(temp.path, url.path) == 0 else {
            throw CopyError.writeFailed(file: name, reason: String(cString: strerror(errno)))
        }
    }

    /// A hash of the picture and sound: every `mdat`, in order.
    static func mediaDigest(of url: URL) throws -> UInt64 {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hasher = XXHash64()
        for box in try topLevel(in: reader) where box.type == "mdat" {
            try reader.seek(toOffset: box.offset + box.header)
            var left = box.size - box.header
            while left > 0 {
                let chunk = try reader.read(upToCount: Int(min(left, UInt64(CardCopier.chunkSize)))) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(chunk)
                left -= UInt64(chunk.count)
            }
        }
        return hasher.digest()
    }

    // MARK: The block

    private struct Block {
        let xml: Data

        /// With Adobe's wrapper and room to grow, as long as `atLeast` at least,
        /// so a block replacing another never leaves a gap in the file.
        func packet(atLeast minimum: Int) -> Data {
            let start = Data("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n".utf8)
            let end = Data("\n<?xpacket end=\"w\"?>".utf8)
            let room = max(ClipMetadata.padding, minimum - start.count - xml.count - end.count)
            return start + xml + Data(repeating: 0x20, count: room) + end
        }
    }

    private static func merged(_ existing: Data?, stars: Int?, keywords: [String], replacing: Bool, name: String) throws -> Block {
        var metadata = CGImageMetadataCreateMutable()
        if let existing, let parsed = CGImageMetadataCreateFromXMPData(existing as CFData),
           let copy = CGImageMetadataCreateMutableCopy(parsed) {
            metadata = copy
        }
        let words = replacing ? keywords : Keywords.merged(Keywords.keywords(in: metadata), adding: keywords)
        guard Keywords.set(words, in: metadata) else { throw ClipMetadataError.didntReadBack(name) }
        if let stars { CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(Stars.clamp(stars)) as CFString) }
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) as Data?,
              let start = data.range(of: Data("<x:xmpmeta".utf8)),
              let end = data.range(of: Data("</x:xmpmeta>".utf8)) else { throw ClipMetadataError.didntReadBack(name) }
        return Block(xml: data[start.lowerBound..<end.upperBound])
    }

    /// The XMP already in the clip, if any.
    private static func existingBlock(in file: FileHandle) throws -> Data? {
        let boxes = try topLevel(in: file)
        if let uuid = try xmpBox(in: file, boxes) {
            try file.seek(toOffset: uuid.offset + uuid.header + 16)
            return try file.read(upToCount: Int(uuid.size - uuid.header - 16))
        }
        guard let moov = boxes.first(where: { $0.type == "moov" }),
              let udta = try children(of: moov, in: file).first(where: { $0.type == "udta" }),
              let xmp = try children(of: udta, in: file).first(where: { $0.type == "XMP_" }) else { return nil }
        try file.seek(toOffset: xmp.offset + xmp.header)
        return try file.read(upToCount: Int(xmp.size - xmp.header))
    }

    // MARK: MP4

    /// At the end of the file, in place of ours if it was last; an XMP box
    /// elsewhere is blanked to `free`, moving nothing.
    private static func writeMP4(_ packet: Data, to file: FileHandle, boxes: [Box]) throws {
        var end = boxes.last?.end ?? 0
        if let old = try xmpBox(in: file, boxes) {
            if old.end == end {
                end = old.offset
            } else {
                try file.seek(toOffset: old.offset + 4)
                try file.write(contentsOf: Data("free".utf8))
            }
        }
        try file.truncate(atOffset: end)
        try file.seek(toOffset: end)
        try file.write(contentsOf: bytes(UInt32(8 + 16 + packet.count)) + Data("uuid".utf8) + xmpUUID + packet)
    }

    private static func xmpBox(in file: FileHandle, _ boxes: [Box]) throws -> Box? {
        for box in boxes where box.type == "uuid" {
            try file.seek(toOffset: box.offset + box.header)
            if try file.read(upToCount: 16) == xmpUUID { return box }
        }
        return nil
    }

    // MARK: QuickTime

    /// Into `moov/udta`. The index is rewritten where it is if it's last or the
    /// `free` space after it has room, which is why cameras leave that space;
    /// otherwise it goes to the end and its old place becomes `free`. Its
    /// offsets point into `mdat`, which doesn't move, so they stay right.
    private static func writeQuickTime(_ block: Block, to file: FileHandle, boxes: [Box], name: String) throws {
        guard let index = boxes.firstIndex(where: { $0.type == "moov" }), boxes[index].header == 8 else {
            throw ClipMetadataError.cantWriteInto(name)
        }
        let moov = boxes[index]
        try file.seek(toOffset: moov.offset)
        guard var data = try file.read(upToCount: Int(moov.size)), UInt64(data.count) == moov.size else {
            throw ClipMetadataError.cantWriteInto(name)
        }
        let start = data.startIndex
        let udta = try children(of: moov, in: file).first { $0.type == "udta" }
        if let udta, udta.header != 8 { throw ClipMetadataError.cantWriteInto(name) }
        let old = try udta.flatMap { try children(of: $0, in: file).first { $0.type == "XMP_" } }

        let packet = block.packet(atLeast: old.map { Int($0.size - $0.header) } ?? 0)
        let atom = box("XMP_", packet)
        if let old {
            let from = start + Int(old.offset - moov.offset)
            data.replaceSubrange(from..<(from + Int(old.size)), with: atom)
            setSize(&data, at: start + Int(udta!.offset - moov.offset), UInt64(atom.count) - old.size + udta!.size)
        } else if let udta {
            // After the last child: some files end the list with four zero bytes, which stay last.
            let last = try children(of: udta, in: file).last?.end ?? (udta.offset + udta.header)
            data.insert(contentsOf: atom, at: start + Int(last - moov.offset))
            setSize(&data, at: start + Int(udta.offset - moov.offset), udta.size + UInt64(atom.count))
        } else {
            data.append(box("udta", atom))
        }
        setSize(&data, at: start, UInt64(data.count))

        let growth = UInt64(data.count) - moov.size
        let next = index + 1 < boxes.count ? boxes[index + 1] : nil
        if next == nil {
            try file.seek(toOffset: moov.offset)
            try file.write(contentsOf: data)
        } else if let next, next.type == "free", next.size == growth || next.size >= growth + 8 {
            try file.seek(toOffset: moov.offset)
            try file.write(contentsOf: data)
            if next.size > growth { try file.write(contentsOf: bytes(UInt32(next.size - growth)) + Data("free".utf8)) }
        } else {
            let end = boxes.last?.end ?? moov.end
            try file.seek(toOffset: end)
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.seek(toOffset: moov.offset + 4)
            try file.write(contentsOf: Data("free".utf8))
        }
    }

    private static func isQuickTime(_ file: FileHandle, _ boxes: [Box]) throws -> Bool {
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" }) else { return true }
        try file.seek(toOffset: ftyp.offset + ftyp.header)
        return try file.read(upToCount: 4) == Data("qt  ".utf8)
    }

    // MARK: Boxes

    private static func box(_ type: String, _ payload: Data) -> Data {
        bytes(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    private static func bytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func setSize(_ data: inout Data, at offset: Int, _ size: UInt64) {
        data.replaceSubrange(offset..<(offset + 4), with: bytes(UInt32(size)))
    }

    /// Every box at the top of the file. A clip that doesn't add up exactly (a
    /// box running past the end, one with no length, stray bytes after the
    /// last) is one the camera may not have finished: nothing is written to it.
    private static func topLevel(in file: FileHandle) throws -> [Box] {
        let end = try file.seekToEnd()
        let boxes = try read(from: 0, to: end, in: file, name: "")
        guard boxes.last?.end == end else { throw ClipMetadataError.cantWriteInto("This clip") }
        return boxes
    }

    private static func children(of parent: Box, in file: FileHandle) throws -> [Box] {
        try read(from: parent.offset + parent.header, to: parent.end, in: file, name: "")
    }

    private static func read(from start: UInt64, to end: UInt64, in file: FileHandle, name: String) throws -> [Box] {
        var boxes: [Box] = []
        var at = start
        while at + 8 <= end {
            try file.seek(toOffset: at)
            guard let head = try file.read(upToCount: 8), head.count == 8 else { break }
            var size = head.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var header: UInt64 = 8
            if size == 1 {
                guard let long = try file.read(upToCount: 8), long.count == 8 else { break }
                size = long.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                header = 16
            }
            guard size >= header, at + size <= end else { break }
            let type = String(decoding: head.suffix(4), as: Unicode.ASCII.self)
            boxes.append(Box(offset: at, size: size, header: header, type: type))
            at += size
        }
        return boxes
    }
}
