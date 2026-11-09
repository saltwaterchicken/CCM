import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaSherpaCore

final class CalibrationTests: XCTestCase {
    private func score(face: Double? = nil, area: Double = 500, blown: Double = 0, crushed: Double = 0,
                       faceBrightness: Double = 128, areaBrightness: Double = 128) -> QualityScore {
        QualityScore(faces: face == nil ? 0 : 1, faceSharpness: face, areaSharpness: area, blown: blown, crushed: crushed,
                     faceQuality: nil, faceBrightness: face == nil ? nil : faceBrightness, faceContrast: nil,
                     areaBrightness: areaBrightness, areaContrast: 40, faceSharpnessScaled: face, facePixels: face == nil ? nil : 100,
                     measuredAt: 1600)
    }

    private func photo(_ name: String, stars: Int, _ score: QualityScore) -> ScoredShot {
        let file = CopiedFile(newName: name + ".NEF", originalPath: name, size: 1, originalModified: nil, checksum: "",
                              destinations: [URL(fileURLWithPath: "/tmp/" + name + ".NEF")], alreadyThere: true)
        return ScoredShot(shot: Shot(baseName: name, files: [file], primary: file, kind: .raw, badge: nil), stars: stars, score: score)
    }

    func testAFaceIsJudgedOnItsFaceAndTheRestOnTheirSharpestArea() {
        let limits = RatingSettings(minimumSharpnessFaces: 50, minimumSharpnessNoFaces: 30)
        XCTAssertEqual(limits.problems(score(face: 40, area: 900)), [.softFace], "A sharp background doesn't save a soft face")
        XCTAssertEqual(limits.problems(score(face: 80, area: 5)), [], "A soft background never counts against a sharp face")
        XCTAssertEqual(limits.problems(score(area: 20)), [.soft])
        XCTAssertEqual(limits.problems(score(area: 31)), [])
    }

    func testOnlyExtremeExposureIsFlagged() {
        let limits = RatingSettings()
        XCTAssertEqual(limits.problems(score(area: 500, blown: 0.72, crushed: 0.9)), [], "Camp keepers went this far")
        XCTAssertEqual(limits.problems(score(area: 500, blown: 0.85)), [.blown])
        XCTAssertEqual(limits.problems(score(area: 500, crushed: 0.97)), [.dark])
        XCTAssertEqual(limits.problems(score(area: 10, crushed: 0.99)), [.soft, .dark])
    }

    func testADimSubjectIsTooDarkWhateverTheBackground() {
        XCTAssertEqual(RatingSettings().problems(score(area: 500, areaBrightness: 5)), [], "Off unless it's set")
        let limits = RatingSettings(minimumBrightness: 40)
        XCTAssertEqual(limits.problems(score(area: 500, crushed: 0.3, areaBrightness: 25)), [.dark], "Underexposed, little pure black")
        XCTAssertEqual(limits.problems(score(face: 120, crushed: 0.9, faceBrightness: 110, areaBrightness: 10)), [],
                       "A lit face on a black stage")
        XCTAssertEqual(limits.problems(score(face: 120, faceBrightness: 20)), [.dark])
        XCTAssertEqual(limits.problems(score(area: 500, crushed: 0.97, areaBrightness: 20)), [.dark], "Listed once")
    }

    func testOldSettingsFilesDontSwitchAutoRatingOn() {
        XCTAssertFalse(RatingSettings().autoRating)
    }

    func testTheReportComparesTheLimitsWithTheCull() {
        let scored = [
            photo("A_1", stars: 1, score(face: 120)),
            photo("A_2", stars: 3, score(face: 30)), // a soft keeper, kept for the moment
            photo("A_3", stars: 0, score(face: 20)),
            photo("A_4", stars: 0, score(face: 200)), // culled for its expression, not focus
            photo("A_5", stars: -1, score(area: 10)),
            photo("A_6", stars: 0, score(area: 400, blown: 0.95)),
        ]
        let report = Calibration.report(scored, limits: RatingSettings(minimumSharpnessFaces: 50, minimumSharpnessNoFaces: 30))
        XCTAssertEqual(report.keepers, 2)
        XCTAssertEqual(report.outtakes, 4, "Rejected counts as an outtake")
        XCTAssertEqual(report.flaggedKeepers, ["a_2"])
        XCTAssertEqual(report.flaggedOuttakes, ["a_3", "a_5", "a_6"])
        XCTAssertEqual(report.problems["a_6"], [.blown])
        XCTAssertEqual(report.keeperShare, 0.5)
        XCTAssertEqual(report.outtakeShare, 0.75)
    }

    func testSuggestedLimitsFlagAboutOnePercentOfKeepers() {
        // 200 keepers with faces scoring 1...200, and 100 without scoring 101...200.
        var scored = (1...200).map { photo("F_\($0)", stars: 1, score(face: Double($0) + 0.5)) }
        scored += (101...200).map { photo("N_\($0)", stars: 1, score(area: Double($0) + 0.5)) }
        let limits = Calibration.suggested(scored, from: RatingSettings(maximumBlown: 0.7))
        XCTAssertEqual(limits.minimumSharpnessFaces, 3)
        XCTAssertEqual(limits.minimumSharpnessNoFaces, 102)
        XCTAssertEqual(limits.maximumBlown, 0.7, "Exposure is left alone")
        let report = Calibration.report(scored, limits: limits)
        XCTAssertEqual(report.flaggedKeepers.count, 3, "2 of 200 with faces, 1 of 100 without")
    }

    func testWithFewKeepersTheSuggestionFlagsNone() {
        let scored = [photo("A_1", stars: 1, score(face: 33.7)), photo("A_2", stars: 2, score(face: 90)),
                      photo("A_3", stars: 0, score(face: 10))]
        let limits = Calibration.suggested(scored, from: RatingSettings())
        XCTAssertEqual(limits.minimumSharpnessFaces, 33)
        XCTAssertEqual(limits.minimumSharpnessNoFaces, RatingSettings().minimumSharpnessNoFaces, "No keepers without faces to go on")
        XCTAssertEqual(Calibration.report(scored, limits: limits).flaggedKeepers, [])
    }

    func testScoringARatedFolderReadsItsStarsAndChangesNothing() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("CalibrationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for (name, stars) in [("S_0001", 1), ("S_0002", 0), ("S_0003", -1)] {
            try jpeg().write(to: folder.appendingPathComponent(name + ".jpg"))
            try Stars.write(stars, toXMP: folder.appendingPathComponent(name + ".xmp"))
        }
        try jpeg().write(to: folder.appendingPathComponent("S_0004.jpg")) // unrated
        try Data("not a photo".utf8).write(to: folder.appendingPathComponent("S_0005.jpg"))
        try Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("S_0006.mp4"))
        let before = try fm.contentsOfDirectory(atPath: folder.path).sorted()

        let photos = try Calibration.photos(in: folder, fileTypes: FileTypes())
        XCTAssertEqual(photos.count, 5, "The clip is left out")
        let (scored, failed) = Calibration.score(photos)
        XCTAssertEqual(scored.map(\.stars), [1, 0, -1, 0], "Unrated counts as 0")
        XCTAssertEqual(failed, ["S_0005.jpg"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), before)
    }

    func testACaptureOneSessionsRatingsAreRead() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("CalibrationTests-\(UUID().uuidString)", isDirectory: true)
        let settings = folder.appendingPathComponent("CaptureOne/Settings1670", isDirectory: true)
        try fm.createDirectory(at: settings, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try jpeg().write(to: folder.appendingPathComponent("H_0001.jpg"))
        try jpeg().write(to: folder.appendingPathComponent("H_0002.jpg"))
        // A first variant at 0 and the one Capture One shows at 3.
        try """
            <IMG><VAR><DL><E K="Basic_Rating" V="0" /></DL></VAR><VAR><DL><E K="Basic_Rating" V="3" /></DL></VAR></IMG>
            """.write(to: settings.appendingPathComponent("H_0001.jpg.cos"), atomically: true, encoding: .utf8)
        let photos = try Calibration.photos(in: folder, fileTypes: FileTypes())
        XCTAssertEqual(photos.map(\.stars), [3, nil])
    }

    private func jpeg() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }
}
