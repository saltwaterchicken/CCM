import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CardIngestCore

/// Tiles for the grid: from RAW previews, JPEGs and clips, made a few at a time and cached.
final class ThumbnailsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// A JPEG like a camera's: full size, with a tiny thumbnail built in.
    private func jpeg(_ name: String, width: Int = 1200, height: Int = 800, orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: true,
                                           kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(dest, try image(width: width, height: height), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// A two-second clip.
    private func clip(_ name: String) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    private func shot(_ urls: URL...) -> Shot {
        let list = ShotList(fileTypes: FileTypes(), files: urls.map { url in
            CopiedFile(newName: url.lastPathComponent, originalPath: "DCIM/" + url.lastPathComponent, size: 1,
                       originalModified: nil, checksum: "0", destinations: [url], alreadyThere: false)
        })
        return list.shots[0]
    }

    // MARK: Making them

    func testAJPEGsTinyBuiltInThumbnailIsntUsed() throws {
        let url = try jpeg("2026-10-14-ES_0001.JPG")
        // What the camera built in is far smaller than a tile...
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let builtIn = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(
            source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary))
        XCTAssertLessThan(max(builtIn.width, builtIn.height), 400)
        // ...so the tile is drawn from the full image.
        let tile = try XCTUnwrap(ThumbnailMaker.photo(url, maxPixels: 400))
        XCTAssertEqual(tile.width, 400)
        XCTAssertEqual(tile.height, 267)
    }

    func testASmallPhotoIsntBlownUp() throws {
        let tile = try XCTUnwrap(ThumbnailMaker.photo(try jpeg("small.JPG", width: 300, height: 200), maxPixels: 400))
        XCTAssertEqual([tile.width, tile.height], [300, 200])
    }

    func testPortraitPhotosStandUp() throws {
        // Orientation 6: the camera was turned; the pixels are stored on their side.
        let tile = try XCTUnwrap(ThumbnailMaker.photo(try jpeg("turned.JPG", orientation: 6), maxPixels: 400))
        XCTAssertEqual([tile.width, tile.height], [267, 400])
    }

    func testAnUnreadableRawFallsBackToItsJPEG() async throws {
        let raw = dir.appendingPathComponent("2026-10-14-ES_0002.CR3")
        try Data("a RAW from a camera this Mac doesn't know".utf8).write(to: raw)
        let pair = shot(raw, try jpeg("2026-10-14-ES_0002.JPG"))
        XCTAssertEqual(pair.primary.newName, "2026-10-14-ES_0002.CR3")
        let tile = await ThumbnailMaker.make(for: pair, maxPixels: 400)
        XCTAssertEqual(tile?.image.width, 400)
        XCTAssertNil(tile?.duration)
    }

    func testAClipGivesAFrameAndItsLength() async throws {
        let tile = await ThumbnailMaker.make(for: shot(try await clip("2026-10-14-ES_0005.MOV")), maxPixels: 160)
        let made = try XCTUnwrap(tile)
        XCTAssertEqual(made.image.width, 160)
        XCTAssertEqual(made.image.height, 90)
        XCTAssertEqual(try XCTUnwrap(made.duration), 2, accuracy: 0.1)
    }

    func testAClipThatWontOpenUsesItsTHM() async throws {
        let mov = dir.appendingPathComponent("2026-10-14-ES_0006.MP4")
        try Data("broken clip".utf8).write(to: mov)
        let thm = try jpeg("2026-10-14-ES_0006.JPG", width: 160, height: 120)
        let renamed = dir.appendingPathComponent("2026-10-14-ES_0006.THM")
        try FileManager.default.moveItem(at: thm, to: renamed)
        let tile = await ThumbnailMaker.make(for: shot(mov, renamed), maxPixels: 400)
        XCTAssertEqual(tile?.image.width, 160)
    }

    func testNothingReadableGivesNoTile() async throws {
        let raw = dir.appendingPathComponent("x.ARW")
        try Data("nope".utf8).write(to: raw)
        let none = await ThumbnailMaker.make(for: shot(raw), maxPixels: 400)
        XCTAssertNil(none)
    }

    // MARK: The larger view

    func testActualPixelsIsTheWholePhotoTurnedUpright() throws {
        let photo = shot(try jpeg("2026-10-14-ES_0007.JPG", width: 1800, height: 1200, orientation: 6))
        let full = try XCTUnwrap(LargeImage.actualPixels(photo))
        XCTAssertEqual([full.width, full.height], [1200, 1800])
    }

    func testActualPixelsFallsBackToThePairsJPEGAndSkipsClips() async throws {
        let raw = dir.appendingPathComponent("2026-10-14-ES_0008.CR3")
        try Data("unknown raw".utf8).write(to: raw)
        let pair = shot(raw, try jpeg("2026-10-14-ES_0008.JPG", width: 1500, height: 1000))
        XCTAssertEqual(LargeImage.actualPixels(pair)?.width, 1500)
        let movie = shot(try await clip("2026-10-14-ES_0009.MOV"))
        XCTAssertNil(LargeImage.actualPixels(movie))
    }

    func testFitFillsTheWindowWithoutGoingPastThePhoto() async throws {
        let photo = shot(try jpeg("2026-10-14-ES_0010.JPG", width: 3000, height: 2000))
        let big = await LargeImage.fit(photo, maxPixels: 2400)
        XCTAssertEqual(big?.image.width, 2400)
    }

    // MARK: The cache

    /// Counts how often a thumbnail is really made, and how many at once.
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var made = 0
        var now = 0
        var most = 0
        func start() { lock.withLock { made += 1; now += 1; most = max(most, now) } }
        func end() { lock.withLock { now -= 1 } }
    }

    private func countingCache(_ counter: Counter, byteLimit: Int = 1 << 30, concurrent: Int = 3) throws -> ThumbnailCache {
        let tile = Thumbnail(image: try image(width: 100, height: 100))
        return ThumbnailCache(maxPixels: 100, byteLimit: byteLimit, concurrent: concurrent) { _, _ in
            counter.start()
            try? await Task.sleep(nanoseconds: 20_000_000)
            counter.end()
            return tile
        }
    }

    private func shots(_ count: Int) -> [Shot] {
        (0..<count).map { shot(dir.appendingPathComponent(String(format: "2026-10-14-ES_%04d.JPG", $0))) }
    }

    func testAThumbnailIsMadeOnceAndThenCached() async throws {
        let counter = Counter()
        let cache = try countingCache(counter)
        let one = shots(1)[0]
        let empty = await cache.cached(one)
        XCTAssertNil(empty)
        // Two tiles asking at the same moment share one.
        async let a = cache.thumbnail(for: one)
        async let b = cache.thumbnail(for: one)
        let (first, second) = await (a, b)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        _ = await cache.thumbnail(for: one)
        XCTAssertEqual(counter.made, 1)
        let hit = await cache.cached(one)
        XCTAssertNotNil(hit)
    }

    func testOnlyAFewAreMadeAtOnce() async throws {
        let counter = Counter()
        let cache = try countingCache(counter, concurrent: 3)
        await withTaskGroup(of: Void.self) { group in
            for one in shots(12) { group.addTask { _ = await cache.thumbnail(for: one) } }
        }
        XCTAssertEqual(counter.made, 12)
        XCTAssertLessThanOrEqual(counter.most, 3)
        XCTAssertGreaterThan(counter.most, 1)
    }

    func testTheLeastRecentlyShownGoFirstWhenFull() async throws {
        let counter = Counter()
        let tileBytes = try image(width: 100, height: 100).bytesPerRow * 100
        let cache = try countingCache(counter, byteLimit: tileBytes * 3)
        let all = shots(4)
        for one in all.prefix(3) { _ = await cache.thumbnail(for: one) }
        _ = await cache.thumbnail(for: all[0])  // shown again, so it stays
        _ = await cache.thumbnail(for: all[3])
        let kept = await [cache.cached(all[0]), cache.cached(all[1]), cache.cached(all[2]), cache.cached(all[3])]
        XCTAssertEqual(kept.map { $0 != nil }, [true, false, true, true])
        let held = await cache.storedBytes
        XCTAssertLessThanOrEqual(held, tileBytes * 3)
    }

    func testATileScrolledAwayBeforeItsTurnIsntMade() async throws {
        let counter = Counter()
        let cache = try countingCache(counter, concurrent: 1)
        let all = shots(3)
        let busy = Task { _ = await cache.thumbnail(for: all[0]) }
        try await Task.sleep(nanoseconds: 5_000_000)
        let gone = Task { await cache.thumbnail(for: all[1]) }
        gone.cancel()
        let result = await gone.value
        _ = await busy.value
        XCTAssertNil(result)
        XCTAssertEqual(counter.made, 1)
    }
}
