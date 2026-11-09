import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum MXFError: Error, Equatable {
    /// Not MXF at all, or starts in a way this doesn't read.
    case notMXF
    case noPictureFrames
    /// One long run of video rather than frame by frame.
    case notFrameWrapped
    /// MPEG-2 and the like.
    case notH264
    case cantDecode
}

/// Pictures from an MXF clip, which AVFoundation won't open ("This media format
/// is not supported") though the Mac can decode what's inside. MXF is only a
/// wrapper: this finds each frame in it and hands it to VideoToolbox. H.264 only.
/// Pictures only, never sound.
///
/// Only frames complete in themselves are shown, so any can come straight away.
/// That's every frame in Intra, and one in 12 (half a second) in Canon's XF-AVC
/// Long GOP, found 2026-11-03: asking for another shows the complete one before it.
/// Enough to check a clip by eye, without decoding the frames between.
///
/// Only `.mxf` comes here; every other clip stays with AVFoundation. Only reads.
public final class MXFClip: @unchecked Sendable {
    public let frameCount: Int
    public let frameRate: Double
    public var duration: Double { Double(frameCount) / frameRate }
    /// Seconds between the frames that can be shown: one frame's length in Intra.
    public var stepSeconds: Double { duration / Double(max(keyFrames.count, 1)) }
    public var showsEveryFrame: Bool { keyFrames.count == frameCount }

    private let descriptor: Int32
    private let frames: [Span]
    /// The frames complete in themselves, in order. Never empty.
    private let keyFrames: [Int]
    private let formatDescription: CMVideoFormatDescription
    private let session: VTDecompressionSession
    private let lock = NSLock()

    struct Span: Equatable {
        var offset: Int64
        var length: Int
    }

    public static func handles(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mxf"
    }

    /// - Parameter maxPixels: the longest side of the pictures made.
    public init(url: URL, maxPixels: Int) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw MXFError.notMXF }
        var opened = false
        defer { if !opened { close(descriptor) } }

        let found = try Self.readIndex(descriptor)
        guard let first = found.frames.first else { throw MXFError.noPictureFrames }
        guard let bytes = Self.read(descriptor, first) else { throw MXFError.notH264 }
        let units = bytes.withUnsafeBufferPointer(Self.nalUnits)
        guard let spsUnit = units.first(where: { bytes[$0.lowerBound] & 31 == 7 }),
              let ppsUnit = units.first(where: { bytes[$0.lowerBound] & 31 == 8 }),
              units.contains(where: { bytes[$0.lowerBound] & 31 == 5 })
        else { throw MXFError.notH264 }
        let sets = (sps: Array(bytes[spsUnit]), pps: Array(bytes[ppsUnit]))
        let keyFrames = found.frames.indices.filter { Self.isComplete(descriptor, found.frames[$0]) }
        guard !keyFrames.isEmpty else { throw MXFError.notH264 }

        var description: CMFormatDescription?
        let made = sets.sps.withUnsafeBufferPointer { sps in
            sets.pps.withUnsafeBufferPointer { pps in
                var pointers = [sps.baseAddress!, pps.baseAddress!]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard made == noErr, let description else { throw MXFError.cantDecode }

        let size = CMVideoFormatDescriptionGetDimensions(description)
        let longest = max(Int(size.width), Int(size.height))
        let scale = min(1, Double(maxPixels) / Double(max(longest, 1)))
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int((Double(size.width) * scale).rounded()),
            kCVPixelBufferHeightKey: Int((Double(size.height) * scale).rounded()),
        ]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr,
              let session
        else { throw MXFError.cantDecode }

        self.descriptor = descriptor
        frames = found.frames
        self.keyFrames = keyFrames
        frameCount = found.frames.count
        frameRate = found.rate
        formatDescription = description
        self.session = session
        opened = true
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
        close(descriptor)
    }

    /// The complete frame at or before this one.
    public func keyFrame(atOrBefore index: Int) -> Int {
        keyFrames[max(keyFramePosition(atOrBefore: index), 0)]
    }

    /// `count` complete frames on from this one, stopping at either end. One
    /// complete frame is one frame in Intra.
    public func keyFrame(from index: Int, by count: Int) -> Int {
        keyFrames[min(max(keyFramePosition(atOrBefore: index) + count, 0), keyFrames.count - 1)]
    }

    private func keyFramePosition(atOrBefore index: Int) -> Int {
        var low = 0, high = keyFrames.count
        while low < high {
            let middle = (low + high) / 2
            if keyFrames[middle] <= index { low = middle + 1 } else { high = middle }
        }
        return low - 1
    }

    /// The complete frame at or before this one; nil if outside the clip, or it
    /// can't be read or decoded.
    public func image(frame index: Int) -> CGImage? {
        guard frames.indices.contains(index),
              let bytes = Self.read(descriptor, frames[keyFrame(atOrBefore: index)]) else { return nil }
        var slices = Data(capacity: bytes.count)
        // 5 is an IDR slice; later complete frames can hold plain I slices, in 1.
        for unit in bytes.withUnsafeBufferPointer(Self.nalUnits) where [1, 5].contains(bytes[unit.lowerBound] & 31) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { slices.append(contentsOf: $0) }
            slices.append(contentsOf: bytes[unit])
        }
        guard !slices.isEmpty, let sample = sampleBuffer(slices) else { return nil }

        final class Output: @unchecked Sendable { var image: CVImageBuffer? }
        let output = Output()
        return lock.withLock {
            var flags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &flags) {
                status, _, image, _, _ in
                if status == noErr { output.image = image }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard status == noErr, let buffer = output.image else { return nil }
            var picture: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &picture)
            return picture
        }
    }

    /// The frame at a time in the clip, for a share of it or a thumbnail.
    public func index(at seconds: Double) -> Int {
        min(max(Int(seconds * frameRate), 0), frameCount - 1)
    }

    private func sampleBuffer(_ slices: Data) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: slices.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: slices.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            slices.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = slices.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    // MARK: Reading the wrapper

    /// An MXF file is a run of items: a 16-byte key, the length, then that many
    /// bytes. Walks them for the picture frames and the frame rate, jumping over
    /// everything else, so a 2 GB clip costs a read per item, not 2 GB.
    static func readIndex(_ file: Int32) throws -> (frames: [Span], rate: Double) {
        var end = Int64(0)
        var info = stat()
        if fstat(file, &info) == 0 { end = Int64(info.st_size) }

        var frames: [Span] = []
        var rate: Double?
        var pictureKey: [UInt8]?
        var offset = Int64(0)
        var head = [UInt8](repeating: 0, count: 25)
        while offset < end {
            let got = pread(file, &head, head.count, offset)
            guard got >= 17, Array(head[0..<4]) == [0x06, 0x0e, 0x2b, 0x34] else { break }
            let first = head[16]
            var headLength = 17
            var length = Int64(first)
            if first >= 0x80 {
                let count = Int(first & 0x7f)
                guard (1...8).contains(count), got >= 17 + count else { break }
                length = head[17..<(17 + count)].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
                headLength += count
            }
            guard length >= 0 else { break }
            let valueAt = offset + Int64(headLength)

            if isPictureItem(head) {
                // Frame by frame is 0x05; only the first picture track.
                guard head[14] == 0x05 else { throw MXFError.notFrameWrapped }
                let key = Array(head[0..<16])
                if pictureKey == nil { pictureKey = key }
                if key == pictureKey, valueAt + length <= end {
                    frames.append(Span(offset: valueAt, length: Int(length)))
                }
            } else if rate == nil, isPictureDescriptor(head), length < 65536,
                      let set = read(file, Span(offset: valueAt, length: Int(length))) {
                rate = sampleRate(inSet: set)
            }
            offset = valueAt + length
        }
        if offset == 0 { throw MXFError.notMXF }
        return (frames, rate ?? 30000.0 / 1001.0)
    }

    private static func isPictureItem(_ key: [UInt8]) -> Bool {
        Array(key[4..<7]) == [0x01, 0x02, 0x01] && Array(key[8..<12]) == [0x0d, 0x01, 0x03, 0x01] && key[12] == 0x15
    }

    /// The header's descriptions of the picture: generic, CDCI, RGBA or MPEG.
    private static func isPictureDescriptor(_ key: [UInt8]) -> Bool {
        Array(key[4..<7]) == [0x02, 0x53, 0x01] && Array(key[8..<14]) == [0x0d, 0x01, 0x01, 0x01, 0x01, 0x01]
            && [0x27, 0x28, 0x29, 0x51].contains(key[14])
    }

    /// Tag 3001 in a set of 2-byte tag, 2-byte length, value: frames per second as a fraction.
    static func sampleRate(inSet set: [UInt8]) -> Double? {
        var at = 0
        while at + 4 <= set.count {
            let tag = Int(set[at]) << 8 | Int(set[at + 1])
            let length = Int(set[at + 2]) << 8 | Int(set[at + 3])
            at += 4
            if tag == 0x3001, length == 8, at + 8 <= set.count {
                let number = { (from: Int) in set[from..<(from + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
                let (top, bottom) = (number(at), number(at + 4))
                return top > 0 && bottom > 0 ? Double(top) / Double(bottom) : nil
            }
            at += length
        }
        return nil
    }

    /// Whether a frame starts with the unit that begins a complete one: its
    /// parameter sets, or an IDR slice. Looks only at the start of the frame.
    private static func isComplete(_ file: Int32, _ span: Span) -> Bool {
        guard let start = read(file, Span(offset: span.offset, length: min(span.length, 512))) else { return false }
        return start.withUnsafeBufferPointer(nalUnits).contains { start[$0.lowerBound] & 31 == 7 || start[$0.lowerBound] & 31 == 5 }
    }

    private static func read(_ file: Int32, _ span: Span) -> [UInt8]? {
        guard span.length > 0 else { return nil }
        let bytes = [UInt8](unsafeUninitializedCapacity: span.length) { buffer, count in
            count = max(pread(file, buffer.baseAddress, span.length, span.offset), 0)
        }
        return bytes.count == span.length ? bytes : nil
    }

    /// Where each H.264 unit lies between its 00 00 01 start codes, without the
    /// zeros padding its end. Never empty ranges.
    static func nalUnits(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var starts: [Int] = []
        var at = 0
        while at + 3 < bytes.count {
            if bytes[at + 2] > 1 {
                at += 3
            } else if bytes[at] == 0, bytes[at + 1] == 0, bytes[at + 2] == 1 {
                starts.append(at + 3)
                at += 3
            } else {
                at += 1
            }
        }
        return starts.enumerated().compactMap { index, start in
            var end = index + 1 < starts.count ? starts[index + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            return end > start ? start..<end : nil
        }
    }
}
