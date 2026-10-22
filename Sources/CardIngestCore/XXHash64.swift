import Foundation

/// xxHash64 (seed 0), the fast checksum used by ingest tools such as Hedge and
/// ShotPut Pro. Feed data in any size pieces with `update`, then call `digest`.
public struct XXHash64: Sendable {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private var totalLength: UInt64 = 0
    /// Up to 31 bytes waiting for a full 32-byte stripe.
    private var buffer: [UInt8] = []

    public init() {
        v1 = Self.p1 &+ Self.p2
        v2 = Self.p2
        v3 = 0
        v4 = 0 &- Self.p1
        buffer.reserveCapacity(32)
    }

    public static func hash(_ data: Data) -> UInt64 {
        var hasher = XXHash64()
        hasher.update(data)
        return hasher.digest()
    }

    /// The checksum as 16 lowercase hex digits, as other tools print it.
    public static func hex(_ value: UInt64) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        totalLength &+= UInt64(bytes.count)
        var offset = 0

        if !buffer.isEmpty {
            let take = min(32 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            offset = take
            guard buffer.count == 32 else { return }
            buffer.withUnsafeBytes { stripe($0, at: 0) }
            buffer.removeAll(keepingCapacity: true)
        }

        while bytes.count - offset >= 32 {
            stripe(bytes, at: offset)
            offset += 32
        }

        if offset < bytes.count {
            buffer.append(contentsOf: bytes[offset...])
        }
    }

    public func digest() -> UInt64 {
        var h: UInt64
        if totalLength >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.mergeRound(h, v1)
            h = Self.mergeRound(h, v2)
            h = Self.mergeRound(h, v3)
            h = Self.mergeRound(h, v4)
        } else {
            h = Self.p5
        }
        h &+= totalLength

        buffer.withUnsafeBytes { rest in
            var i = 0
            while rest.count - i >= 8 {
                let k1 = Self.round(0, Self.read64(rest, i))
                h ^= k1
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if rest.count - i >= 4 {
                h ^= UInt64(Self.read32(rest, i)) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < rest.count {
                h ^= UInt64(rest[i]) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }

        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    private mutating func stripe(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        v1 = Self.round(v1, Self.read64(bytes, offset))
        v2 = Self.round(v2, Self.read64(bytes, offset + 8))
        v3 = Self.round(v3, Self.read64(bytes, offset + 16))
        v4 = Self.round(v4, Self.read64(bytes, offset + 24))
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    private static func mergeRound(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        (acc ^ round(0, value)) &* p1 &+ p4
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    private static func read64(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    private static func read32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
