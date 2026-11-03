import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import CardIngestCore

/// Real H.264 made by the Mac's encoder, wrapped as a camera would, as CI has no camera footage.
final class MXFClipTests: XCTestCase {
    private var folder: URL!

    private static let picture: [UInt8] = [0x06, 0x0e, 0x2b, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0d, 0x01, 0x03, 0x01, 0x15, 0x01, 0x05, 0x00]
    private static let sound: [UInt8] = [0x06, 0x0e, 0x2b, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0d, 0x01, 0x03, 0x01, 0x16, 0x04, 0x03, 0x00]
    private static let fill: [UInt8] = [0x06, 0x0e, 0x2b, 0x34, 0x01, 0x01, 0x01, 0x02, 0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00]
    private static let descriptor: [UInt8] = [0x06, 0x0e, 0x2b, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0d, 0x01, 0x01, 0x01, 0x01, 0x01, 0x28, 0x00]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MXF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Key, 4-byte BER length, value.
    private func item(_ key: [UInt8], _ value: [UInt8]) -> [UInt8] {
        let n = UInt32(value.count)
        return key + [0x83, UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + value
    }

    /// Frames per second as a descriptor set holds it, after another tag to step over.
    private func rateSet(_ top: UInt32, _ bottom: UInt32) -> [UInt8] {
        let number = { (n: UInt32) in [UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
        return [0x3c, 0x0a, 0x00, 0x02, 0xaa, 0xbb, 0x30, 0x01, 0x00, 0x08] + number(top) + number(bottom)
    }

    private func write(_ bytes: [UInt8], name: String = "clip.MXF") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Picture frames with sound and padding between them, as on a Canon card.
    private func clip(_ frames: [[UInt8]], rate: (UInt32, UInt32) = (25, 1), pictureKey: [UInt8] = picture) -> [UInt8] {
        var bytes = item(Self.descriptor, rateSet(rate.0, rate.1)) + item(Self.fill, [UInt8](repeating: 0, count: 300))
        for frame in frames {
            bytes += item(pictureKey, frame) + item(Self.sound, [1, 2, 3, 4]) + item(Self.fill, [0, 0])
        }
        return bytes
    }

    /// Whole frames from VideoToolbox's encoder, each one brightness, as Annex B with SPS and PPS in each.
    private func encodedFrames(brightness: [UInt8], width: Int = 640, height: Int = 360, keyEvery: Int = 1) throws -> [[UInt8]] {
        final class Out: @unchecked Sendable { var frames: [[UInt8]] = [] }
        let out = Out()
        var session: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                  codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                  outputCallback: nil, refcon: nil, compressionSessionOut: &session), noErr)
        let compression = try XCTUnwrap(session)
        defer { VTCompressionSessionInvalidate(compression) }
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyEvery as CFNumber)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        for (index, value) in brightness.enumerated() {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
            let buffer = try XCTUnwrap(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            VTCompressionSessionEncodeFrame(compression, imageBuffer: buffer,
                                            presentationTimeStamp: CMTime(value: Int64(index), timescale: 25),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                guard let sample, let block = CMSampleBufferGetDataBuffer(sample),
                      let format = CMSampleBufferGetFormatDescription(sample) else { return }
                var frame: [UInt8] = []
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                for set in 0..<(notSync ? 0 : 2) {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: set, parameterSetPointerOut: &pointer,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    frame += [0, 0, 0, 1] + Array(UnsafeBufferPointer(start: pointer, count: size))
                }
                var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
                var at = 0
                while at + 4 <= data.count {
                    let length = data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
                    frame += [0, 0, 0, 1] + data[(at + 4)..<(at + 4 + length)]
                    at += 4 + length
                }
                out.frames.append(frame)
            }
        }
        VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
        return out.frames
    }

    private func averageBrightness(_ image: CGImage) throws -> Double {
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
    }

    func testOnlyMXFComesHereSoOtherClipsStayWithAVFoundation() {
        XCTAssertTrue(MXFClip.handles(URL(fileURLWithPath: "/a/C0001.MXF")))
        XCTAssertTrue(MXFClip.handles(URL(fileURLWithPath: "/a/c0001.mxf")))
        for name in ["a.mov", "a.MOV", "a.mp4", "a.MP4", "a.m4v", "a.crm", "a.braw", "a.r3d", "mxf"] {
            XCTAssertFalse(MXFClip.handles(URL(fileURLWithPath: "/a/\(name)")), name)
        }
    }

    func testDecodesTheRightFrameAtTheRightSizeAndReportsItsLength() throws {
        let url = try write(clip(try encodedFrames(brightness: [30, 220, 30, 220, 120]), rate: (25, 1)))
        let clip = try MXFClip(url: url, maxPixels: 320)
        XCTAssertEqual(clip.frameCount, 5)
        XCTAssertEqual(clip.frameRate, 25)
        XCTAssertEqual(clip.duration, 0.2, accuracy: 0.0001)

        let dark = try XCTUnwrap(clip.image(frame: 0))
        XCTAssertEqual(dark.width, 320, "Scaled to what was asked for")
        XCTAssertEqual(dark.height, 180)
        let bright = try XCTUnwrap(clip.image(frame: 1))
        XCTAssertGreaterThan(try averageBrightness(bright), try averageBrightness(dark) + 50)
        // Any frame straight away, backward too.
        XCTAssertLessThan(try averageBrightness(try XCTUnwrap(clip.image(frame: 2))), try averageBrightness(bright) - 50)
        XCTAssertNil(clip.image(frame: 5))
        XCTAssertNil(clip.image(frame: -1))
    }

    func testLongGOPShowsTheCompleteFrameBeforeTheOneAskedFor() throws {
        let frames = try encodedFrames(brightness: [30, 40, 50, 220, 210, 200, 30, 40], keyEvery: 3)
        let url = try write(clip(frames, rate: (24, 1)))
        let clip = try MXFClip(url: url, maxPixels: 320)
        XCTAssertEqual(clip.frameCount, 8)
        XCTAssertFalse(clip.showsEveryFrame)
        XCTAssertEqual(clip.keyFrame(atOrBefore: 0), 0)
        XCTAssertEqual(clip.keyFrame(atOrBefore: 2), 0)
        XCTAssertEqual(clip.keyFrame(atOrBefore: 3), 3)
        XCTAssertEqual(clip.keyFrame(atOrBefore: 5), 3)
        XCTAssertEqual(clip.keyFrame(atOrBefore: 7), 6)
        XCTAssertEqual(clip.stepSeconds, 8.0 / 24 / 3, accuracy: 0.0001)
        // Stepping goes by complete frames and stops at the ends.
        XCTAssertEqual(clip.keyFrame(from: 4, by: 1), 6)
        XCTAssertEqual(clip.keyFrame(from: 4, by: -1), 0)
        XCTAssertEqual(clip.keyFrame(from: 4, by: 10), 6)
        XCTAssertEqual(clip.keyFrame(from: 4, by: -10), 0)

        let early = try averageBrightness(try XCTUnwrap(clip.image(frame: 2)))
        let later = try averageBrightness(try XCTUnwrap(clip.image(frame: 5)))
        XCTAssertGreaterThan(later, early + 50, "Frame 0's picture, then frame 3's")
        XCTAssertLessThan(try averageBrightness(try XCTUnwrap(clip.image(frame: 7))), later - 50, "Back to a dark one: frame 6's")
    }

    func testIntraStepsFrameByFrame() throws {
        let clip = try MXFClip(url: try write(clip(try encodedFrames(brightness: [10, 20, 30]))), maxPixels: 100)
        XCTAssertTrue(clip.showsEveryFrame)
        XCTAssertEqual(clip.keyFrame(from: 1, by: 1), 2)
        XCTAssertEqual(clip.keyFrame(from: 1, by: -1), 0)
    }

    func testFullSizeIsNeverEnlarged() throws {
        let url = try write(clip(try encodedFrames(brightness: [100])))
        XCTAssertEqual(try XCTUnwrap(MXFClip(url: url, maxPixels: 4000).image(frame: 0)).width, 640)
    }

    func testAClipTheSameWayThumbnailsAndTimesReachIt() async throws {
        let url = try write(clip(try encodedFrames(brightness: [10, 200, 10]), rate: (2, 1)))
        let clip = try MXFClip(url: url, maxPixels: 100)
        XCTAssertEqual(clip.index(at: -1), 0)
        XCTAssertEqual(clip.index(at: 0.5), 1)
        XCTAssertEqual(clip.index(at: 99), 2, "Past the end is the last frame")
        let thumbnail = await ThumbnailMaker.video(url, maxPixels: 100)
        XCTAssertEqual(try XCTUnwrap(thumbnail).duration ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(thumbnail?.image.width, 100)
    }

    func testFrameRateFallsBackAndReadsNTSC() throws {
        XCTAssertEqual(MXFClip.sampleRate(inSet: rateSet(30000, 1001)) ?? 0, 29.97, accuracy: 0.001)
        XCTAssertNil(MXFClip.sampleRate(inSet: rateSet(25, 0)))
        XCTAssertNil(MXFClip.sampleRate(inSet: [0x30, 0x01, 0x00]), "Cut short")
    }

    func testWhatItCannotReadIsRefusedWithoutAPicture() throws {
        let sps: [UInt8] = [0, 0, 1, 0x67, 1, 2, 3], pps: [UInt8] = [0, 0, 1, 0x68, 4]
        let idr: [UInt8] = [0, 0, 1, 0x65, 9]
        let refused: [(String, [UInt8], MXFError)] = [
            ("Not MXF", Array("just some text, long enough to read a key from".utf8), .notMXF),
            ("Nothing inside", item(Self.fill, [0]), .noPictureFrames),
            ("MPEG-2", clip([[0, 0, 1, 0xb3, 1, 2, 3]]), .notH264),
            ("One long run", clip([sps + pps + idr], pictureKey: Array(Self.picture[0..<14]) + [0x06, 0x00]), .notFrameWrapped),
            ("No complete first frame", clip([sps + pps + [0, 0, 1, 0x41, 9]]), .notH264),
        ]
        for (why, bytes, error) in refused {
            let url = try write(bytes, name: "\(why).MXF")
            XCTAssertThrowsError(try MXFClip(url: url, maxPixels: 100), why) { XCTAssertEqual($0 as? MXFError, error, why) }
        }
    }

    func testAFrameCutShortAtTheEndIsLeftOut() throws {
        let whole = clip(try encodedFrames(brightness: [50, 60]))
        let url = try write(whole + Self.picture + [0x83, 0xff, 0xff, 0xff, 1, 2, 3])
        XCTAssertEqual(try MXFClip(url: url, maxPixels: 100).frameCount, 2)
    }

    func testFindsUnitsBetweenStartCodesWithoutTheirPadding() {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x09, 0x10, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 0, 0, 1, 0x65, 7, 8, 0, 0]
        let units = bytes.withUnsafeBufferPointer(MXFClip.nalUnits)
        XCTAssertEqual(units.map { Array(bytes[$0]) }, [[0x09, 0x10], [0x67, 1, 2], [0x65, 7, 8]])
        XCTAssertEqual([UInt8]().withUnsafeBufferPointer(MXFClip.nalUnits), [])
    }
}
