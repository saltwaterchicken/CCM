import CryptoKit
import Foundation

/// The XMP block many cameras put inside the RAW file itself (Sony ARW, Nikon
/// NEF, DNG, Canon CR3, Fujifilm RAF ...), usually saying `xmp:Rating 0`.
///
/// Lightroom and Camera Raw only trust a sidecar over that block when the
/// sidecar's `photoshop:EmbeddedXMPDigest` matches it: the MD5 of the block,
/// as 32 uppercase hex digits. Without it they take the RAW's own rating and
/// ignore the sidecar's stars (found testing a Sony RX100 card, 2026-10-22).
/// Checked against digests Lightroom wrote for a real ARW and NEF, and in
/// Lightroom with ARW, NEF, CR3 and RAF files copied from a card (2026-10-22).
public enum RawXMP {
    /// Big enough for any real XMP block, small enough that a damaged file
    /// can't make us read hundreds of megabytes.
    static let maxBlock = 4 * 1024 * 1024

    /// The digest of the RAW's embedded XMP, or nil when it has none.
    public static func digest(of raw: URL) -> String? {
        guard let block = embeddedXMP(in: raw) else { return nil }
        return Insecure.MD5.hash(data: block).map { String(format: "%02X", $0) }.joined()
    }

    /// The embedded XMP block's bytes, exactly as stored.
    public static func embeddedXMP(in raw: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: raw) else { return nil }
        defer { try? handle.close() }
        guard let header = read(handle, at: 0, count: 16), header.count >= 8 else { return nil }
        if header[4..<8] == Data("ftyp".utf8) { return fromBoxes(handle) }
        if header == Data("FUJIFILMCCD-RAW ".utf8) { return fromRAF(handle) }
        return fromTIFF(handle, header: header)
    }

    /// TIFF-based RAWs (ARW, NEF, DNG, CR2, PEF, ORF, RW2): tag 700 in the first IFD.
    private static func fromTIFF(_ handle: FileHandle, header: Data) -> Data? {
        let little: Bool
        switch (header[0], header[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        let u16 = { (d: Data, at: Int) -> Int in
            let a = Int(d[d.startIndex + at]), b = Int(d[d.startIndex + at + 1])
            return little ? a | b << 8 : a << 8 | b
        }
        let u32 = { (d: Data, at: Int) -> Int in
            little ? u16(d, at) | u16(d, at + 2) << 16 : u16(d, at) << 16 | u16(d, at + 2)
        }
        // 42 for TIFF; Olympus and Panasonic use their own numbers.
        guard [42, 0x4F52, 0x5352, 0x55].contains(u16(header, 2)) else { return nil }
        let ifd = u32(header, 4)
        guard let countBytes = read(handle, at: ifd, count: 2), countBytes.count == 2 else { return nil }
        let count = u16(countBytes, 0)
        guard count > 0, count < 1000, let entries = read(handle, at: ifd + 2, count: count * 12),
              entries.count == count * 12 else { return nil }
        for i in 0..<count where u16(entries, i * 12) == 700 {
            // Stored as BYTE (1) or UNDEFINED (7): one byte each.
            let type = u16(entries, i * 12 + 2)
            let length = u32(entries, i * 12 + 4)
            guard type == 1 || type == 7, length > 0, length <= maxBlock else { return nil }
            if length <= 4 { return entries.subdata(in: (i * 12 + 8)..<(i * 12 + 8 + length)) }
            return read(handle, at: u32(entries, i * 12 + 8), count: length).flatMap { $0.count == length ? $0 : nil }
        }
        return nil
    }

    /// The `uuid` box Adobe's XMP spec uses in ISO media files such as CR3.
    static let xmpBoxID = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
                                0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])

    /// Canon CR3 (ISO media boxes): the XMP `uuid` box at the top level.
    private static func fromBoxes(_ handle: FileHandle) -> Data? {
        var offset = 0
        for _ in 0..<64 {
            guard let head = read(handle, at: offset, count: 32), head.count >= 8 else { return nil }
            let be = { (at: Int, bytes: Int) in head[at..<(at + bytes)].reduce(0) { $0 << 8 | Int($1) } }
            var size = be(0, 4)
            var headerSize = 8
            if size == 1 {
                guard head.count >= 16 else { return nil }
                size = be(8, 8)
                headerSize = 16
            }
            guard size >= headerSize else { return nil }
            if head[4..<8] == Data("uuid".utf8), head.count >= headerSize + 16,
               head[headerSize..<(headerSize + 16)] == xmpBoxID {
                let length = size - headerSize - 16
                guard length > 0, length <= maxBlock else { return nil }
                return read(handle, at: offset + headerSize + 16, count: length).flatMap { $0.count == length ? $0 : nil }
            }
            offset += size
        }
        return nil
    }

    /// Fujifilm RAF: the XMP section of the preview JPEG near the start of
    /// the file (its offset and length are at bytes 84 and 88).
    private static func fromRAF(_ handle: FileHandle) -> Data? {
        guard let pointers = read(handle, at: 84, count: 8), pointers.count == 8 else { return nil }
        let be = { (d: Data, at: Int) in d[(d.startIndex + at)..<(d.startIndex + at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        let start = be(pointers, 0)
        let end = start + be(pointers, 4)
        var offset = start + 2  // past the JPEG's FFD8
        let signature = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        for _ in 0..<64 {
            guard offset + 4 <= end, let marker = read(handle, at: offset, count: 4), marker.count == 4,
                  marker[marker.startIndex] == 0xFF else { return nil }
            let kind = marker[marker.startIndex + 1]
            let length = Int(marker[marker.startIndex + 2]) << 8 | Int(marker[marker.startIndex + 3])
            // The image data starts here; there's no XMP after it.
            if kind == 0xDA || length < 2 { return nil }
            if kind == 0xE1, length > signature.count + 2,
               read(handle, at: offset + 4, count: signature.count) == signature {
                let packet = length - 2 - signature.count
                return read(handle, at: offset + 4 + signature.count, count: packet).flatMap { $0.count == packet ? $0 : nil }
            }
            offset += 2 + length
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }
}
