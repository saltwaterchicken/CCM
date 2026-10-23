import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CardIngestCore

/// Reading capture dates from real files made on the fly.
final class CaptureDateTests: XCTestCase {
    private var dir: URL!
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-14 09:05:03 UTC
    private let taken = Date(timeIntervalSince1970: 1_791_968_703)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureDateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pixelImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    /// A JPEG with EXIF DateTimeOriginal, like a camera writes.
    private func jpeg(named name: String, exifDate: String?) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let exifDate { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate] }
        CGImageDestinationAddImage(dest, try pixelImage(), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testPhotoDateComesFromExif() throws {
        let url = try jpeg(named: "IMG_0001.JPG", exifDate: "2026:10:14 09:05:03")
        XCTAssertEqual(CaptureDate.read(url, kind: .photo, timeZone: utc), taken)
    }

    func testPhotoWithoutExifDateGivesNil() throws {
        let url = try jpeg(named: "IMG_0002.JPG", exifDate: nil)
        XCTAssertNil(CaptureDate.read(url, kind: .photo, timeZone: utc))
    }

    func testUnreadableFilesGiveNil() throws {
        let url = dir.appendingPathComponent("IMG_0003.CR3")
        try Data("not really a raw file".utf8).write(to: url)
        XCTAssertNil(CaptureDate.read(url, kind: .raw, timeZone: utc))
        let clip = dir.appendingPathComponent("MVI_0004.MP4")
        try Data("not really a clip".utf8).write(to: clip)
        XCTAssertNil(CaptureDate.read(clip, kind: .video, timeZone: utc))
    }

    func testVideoDateComesFromTheClip() async throws {
        let url = dir.appendingPathComponent("MVI_0005.MOV")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let created = AVMutableMetadataItem()
        created.identifier = .commonIdentifierCreationDate
        created.value = "2026-10-14T09:05:03Z" as NSString
        writer.metadata = [created]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: .zero))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")

        XCTAssertEqual(CaptureDate.read(url, kind: .video), taken)
    }

    func testSidecarsHaveNoDateOfTheirOwn() throws {
        let url = try jpeg(named: "IMG_0006.THM", exifDate: "2026:10:14 09:05:03")
        XCTAssertNil(CaptureDate.read(url, kind: .sidecar, timeZone: utc))
    }
}
