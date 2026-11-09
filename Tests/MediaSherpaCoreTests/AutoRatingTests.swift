import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaSherpaCore

final class AutoRatingTests: XCTestCase {
    private let fm = FileManager.default
    private var folder: URL!
    private var backup: URL!
    private let limits = RatingSettings()

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("AutoRatingTests-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("2026-07-11-ES001", isDirectory: true)
        backup = base.appendingPathComponent("Backup/2026-07-11-ES001", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: folder.deletingLastPathComponent())
    }

    /// Fine grey detail, in focus or blurred, saved as a TIFF or a JPEG. (A TIFF named .DNG would
    /// stand for a RAW, but ImageIO won't draw one; the RAW path is the same apart from the digest.)
    private func picture(soft: Bool, rating: Int? = nil, type: UTType = .tiff) throws -> Data {
        let width = 1200, height = 800
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in pixels.indices {
            var b = UInt64((i / width / 4) * 1000 + (i % width) / 4) &* 0x9E3779B97F4A7C15
            b ^= b >> 29
            pixels[i] = UInt8(40 + Int(b % 176))
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        var image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        if soft {
            let input = CIImage(cgImage: image)
            image = try XCTUnwrap(CIContext().createCGImage(input.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: input.extent),
                                                            from: input.extent))
        }
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        if let rating {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(rating) as CFString)
        }
        CGImageDestinationAddImageAndMetadata(dest, image, metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// A shot copied to the folder and the backup, as a Copy leaves it.
    private func shot(_ name: String, _ data: Data, sidecar: Bool = true) throws -> Shot {
        var destinations: [URL] = []
        for place in [folder!, backup!] {
            let url = place.appendingPathComponent(name)
            try data.write(to: url)
            destinations.append(url)
        }
        let file = CopiedFile(newName: name, originalPath: name, size: Int64(data.count), originalModified: nil,
                              checksum: "", destinations: destinations, alreadyThere: false)
        var list = ShotList(fileTypes: FileTypes())
        let index = list.add(file)
        let shot = list.shots[index]
        if sidecar { try Stars.giveSidecar(to: shot) }
        return shot
    }

    private func sidecars(_ shot: Shot) -> [URL] { Stars.sidecars(of: shot) }

    func testASharpPhotoGetsOneStarAndTheMarkerInEverySidecar() throws {
        let sharp = try shot("A_0001.TIF", picture(soft: false))
        let check = try XCTUnwrap(AutoRating.rate(sharp, limits: limits))
        XCTAssertEqual(check.stars, 1)
        XCTAssertEqual(check.problems, [])
        for sidecar in sidecars(sharp) {
            XCTAssertEqual(Stars.read(xmp: sidecar), 1, "Lightroom sees the star")
            XCTAssertEqual(AutoRating.check(in: sidecar), check)
            XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains(AutoRating.namespace))
        }
        XCTAssertEqual(AutoRating.check(of: sharp), check)
    }

    func testASoftPhotoStaysAtZeroWithItsReason() throws {
        let soft = try shot("A_0002.TIF", picture(soft: true))
        let check = try XCTUnwrap(AutoRating.rate(soft, limits: limits))
        XCTAssertEqual(check.stars, 0)
        XCTAssertEqual(check.problems, [.soft])
        XCTAssertTrue(check.isFlagged)
        XCTAssertLessThan(check.score, limits.minimumSharpnessNoFaces)
        XCTAssertEqual(Stars.read(xmp: sidecars(soft)[1]), 0, "In the backup too")
    }

    func testAPhotoThatAlreadyHasStarsIsLeftAlone() throws {
        let rated = try shot("A_0003.TIF", picture(soft: true))
        try Stars.set(3, on: rated)
        let before = try Data(contentsOf: sidecars(rated)[0])
        XCTAssertNil(try AutoRating.rate(rated, limits: limits))
        XCTAssertEqual(try Data(contentsOf: sidecars(rated)[0]), before)

        let handZero = try shot("A_0004.TIF", picture(soft: false))
        try Stars.set(0, on: handZero)
        XCTAssertNil(try AutoRating.rate(handZero, limits: limits), "A 0 given by hand is theirs too")

        let inCamera = try shot("A_0005.TIF", picture(soft: true, rating: 2))
        XCTAssertNil(try AutoRating.rate(inCamera, limits: limits), "Rated in the camera")
        XCTAssertEqual(Stars.found(for: inCamera), 2)
        XCTAssertFalse(fm.fileExists(atPath: sidecars(inCamera)[0].path), "Nothing written")
    }

    func testAPhotoIsCheckedOnlyOnce() throws {
        let photo = try shot("A_0006.TIF", picture(soft: true))
        XCTAssertNotNil(try AutoRating.rate(photo, limits: limits))
        XCTAssertNil(try AutoRating.rate(photo, limits: RatingSettings(minimumSharpnessNoFaces: 1)), "Not checked again")
        XCTAssertEqual(Stars.read(xmp: sidecars(photo)[0]), 0)
    }

    func testRatingItLaterMakesTheStarsTheirsHereOrInAnotherApp() throws {
        let here = try shot("A_0007.TIF", picture(soft: true))
        try AutoRating.rate(here, limits: limits)
        try Stars.set(2, on: here)
        let mine = try XCTUnwrap(AutoRating.check(of: here))
        XCTAssertNil(mine.stars, "Rated by hand in the grid")
        XCTAssertEqual(mine.problems, [.soft], "The reason stays, for the record")
        XCTAssertFalse(mine.isFlagged)

        let lightroom = try shot("A_0008.TIF", picture(soft: true))
        try AutoRating.rate(lightroom, limits: limits)
        // Lightroom changes the rating and leaves fields it doesn't know.
        try Stars.write(3, toXMP: sidecars(lightroom)[0])
        XCTAssertNil(try XCTUnwrap(AutoRating.check(in: sidecars(lightroom)[0])).stars)
    }

    func testAJPEGOnItsOwnGetsASidecarAndClipsNothing() throws {
        let jpeg = try shot("A_0009.JPG", picture(soft: false, type: .jpeg), sidecar: false)
        XCTAssertEqual(try AutoRating.rate(jpeg, limits: limits)?.stars, 1)
        XCTAssertEqual(Stars.read(xmp: sidecars(jpeg)[0]), 1)
        let clip = try shot("A_0010.MP4", Data(repeating: 1, count: 100), sidecar: false)
        XCTAssertNil(try AutoRating.rate(clip, limits: limits))
    }

    func testAnUnreadablePhotoThrowsInsteadOfPassing() throws {
        let broken = try shot("A_0011.TIF", Data("not a photo".utf8))
        XCTAssertThrowsError(try AutoRating.rate(broken, limits: limits))
        XCTAssertNil(AutoRating.check(of: broken))
    }

    func testLoadingTheFolderBringsBackTheChecksForTheGrid() throws {
        let sharp = try shot("A_0001.TIF", picture(soft: false))
        let soft = try shot("A_0002.TIF", picture(soft: true))
        let unchecked = try shot("A_0003.TIF", picture(soft: true))
        try AutoRating.rate(sharp, limits: limits)
        try AutoRating.rate(soft, limits: limits)

        let loaded = try ImportedFolder.shots(in: folder, backupRoot: backup.deletingLastPathComponent(), fileTypes: FileTypes())
        XCTAssertEqual(loaded.map(\.stars), [1, 0, nil])
        XCTAssertEqual(loaded.map { $0.check?.stars }, [1, 0, nil])
        var grid = CullGrid()
        loaded.forEach { grid.add($0) }
        XCTAssertEqual(grid.flaggedByApp, 1)
        XCTAssertEqual(grid.unchecked.map(\.id), [unchecked.id])
        grid.filter = .appFlagged
        XCTAssertEqual(grid.visible.map(\.id), [soft.id])
        // Calibration leaves out photos still at the app's own stars.
        XCTAssertEqual(try Calibration.photos(in: folder, fileTypes: FileTypes()).map(\.shot.id), [unchecked.id])
    }

    func testCalibratingTheCardJustReviewedShowsThePhotosRescuedFromTheFlags() throws {
        let sharp = try shot("A_0001.TIF", picture(soft: false))
        let rescued = try shot("A_0002.TIF", picture(soft: true))
        let left = try shot("A_0003.TIF", picture(soft: true))
        for photo in [sharp, rescued, left] { try AutoRating.rate(photo, limits: limits) }
        // Reviewing "Flagged by app": one of the two is a keeper after all.
        try Stars.set(2, on: rescued)

        XCTAssertEqual(try Calibration.photos(in: folder, fileTypes: FileTypes()).map(\.shot.id), [rescued.id],
                       "On its own, a folder counts only the photographer's stars")
        let card = try Calibration.photos(in: folder, fileTypes: FileTypes(), includingAppStars: true)
        XCTAssertEqual(card.map(\.stars), [1, 2, 0], "The app's stars count where they were left")
        let scored = Calibration.score(card).scored
        XCTAssertEqual(scored.map(\.rescued), [false, true, false])
        let now = Calibration.report(scored, limits: limits)
        XCTAssertEqual(now.rescued, [rescued.id])
        XCTAssertEqual(now.rescuedStillFlagged, [rescued.id])
        XCTAssertEqual(Calibration.report(scored, limits: RatingSettings(minimumSharpnessNoFaces: 1)).rescuedStillFlagged, [])
    }

    func testTheGridKeepsAHandRatingOverALateCheck() throws {
        let one = try shot("A_0001.TIF", picture(soft: true))
        let two = try shot("A_0002.TIF", picture(soft: true))
        var grid = CullGrid()
        grid.add(LandedShot(shot: one, stars: nil, position: 0))
        grid.add(LandedShot(shot: two, stars: nil, position: 1))
        let flagged = AutoCheck(stars: 0, problems: [.soft], score: 10)

        XCTAssertTrue(grid.apply(flagged, to: one.id))
        XCTAssertEqual(grid.stars[one.id], 0)
        // Rated by hand before its check came back: the check is dropped.
        grid.click(two.id)
        grid.rate(3)
        XCTAssertFalse(grid.apply(flagged, to: two.id))
        XCTAssertEqual(grid.stars[two.id], 3)
        XCTAssertEqual(grid.flaggedByApp, 1)

        // Reviewing the flagged ones: rating one takes it out of the view.
        grid.filter = .appFlagged
        grid.click(one.id)
        grid.rate(1)
        XCTAssertEqual(grid.flaggedByApp, 0)
        XCTAssertEqual(grid.visible, [])
        XCTAssertNil(grid.checks[one.id]?.stars)
    }
}
