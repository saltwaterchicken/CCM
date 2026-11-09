import XCTest
@testable import MediaSherpaCore

final class PhotoLabelsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/Card")

    private func photo(_ name: String, stars: Int = 0, face: Double? = nil, area: Double = 500, blown: Double = 0,
                       crushed: Double = 0, brightness: Double = 128) -> ScoredShot {
        let score = QualityScore(faces: face == nil ? 0 : 1, faceSharpness: face, areaSharpness: area, blown: blown, crushed: crushed,
                                 faceQuality: nil, faceBrightness: face == nil ? nil : brightness, faceContrast: nil,
                                 areaBrightness: brightness, areaContrast: 40, faceSharpnessScaled: face,
                                 facePixels: face == nil ? nil : 100, measuredAt: 1600)
        let file = CopiedFile(newName: name + ".NEF", originalPath: name, size: 1, originalModified: nil, checksum: "",
                              destinations: [URL(fileURLWithPath: "/tmp/" + name + ".NEF")], alreadyThere: true)
        return ScoredShot(shot: Shot(baseName: name, files: [file], primary: file, kind: .raw, badge: nil), stars: stars, score: score)
    }

    private func labelled(_ pairs: [(ScoredShot, PhotoLabel)]) -> PhotoLabels {
        var labels = PhotoLabels()
        for (photo, label) in pairs { labels.toggle(label, for: photo, folder: folder) }
        return labels
    }

    func testALabelMovesItsLimitJustFarEnough() {
        let dark = photo("A_1", brightness: 30.4)
        let learned = Calibration.learned(from: labelled([(dark, .subjectTooDark)]), folder: folder, scored: [dark],
                                          limits: RatingSettings())
        XCTAssertEqual(learned.limits.minimumBrightness, 31)
        XCTAssertEqual(learned.limits.problems(dark.score), [.dark])
        XCTAssertEqual(learned.unmet, [])
        XCTAssertEqual(learned.limits.minimumSharpnessFaces, RatingSettings().minimumSharpnessFaces, "Other limits stay")
    }

    func testTooMuchMeasuresMoveDown() {
        let black = photo("A_1", crushed: 0.6)
        let white = photo("A_2", blown: 0.42)
        let bright = photo("A_3", brightness: 230)
        let learned = Calibration.learned(from: labelled([(black, .imageTooDark), (white, .imageTooLight), (bright, .subjectTooLight)]),
                                          folder: folder, scored: [black, white, bright], limits: RatingSettings())
        XCTAssertEqual(learned.limits.maximumCrushed, 0.59, accuracy: 0.0001)
        XCTAssertEqual(learned.limits.maximumBlown, 0.41, accuracy: 0.0001)
        XCTAssertEqual(learned.limits.maximumBrightness, 229)
        XCTAssertEqual(learned.limits.problems(black.score), [.dark])
        XCTAssertEqual(learned.limits.problems(white.score), [.blown])
        XCTAssertEqual(learned.limits.problems(bright.score), [.bright])
    }

    func testKeepersStopALimitAndSaySo() {
        let keepers = (0..<10).map { photo("K_\($0)", stars: 1, brightness: 20 + Double($0)) }
        let dark = photo("A_1", brightness: 35)
        let learned = Calibration.learned(from: labelled([(dark, .subjectTooDark)]), folder: folder, scored: keepers + [dark],
                                          limits: RatingSettings())
        XCTAssertEqual(learned.limits.minimumBrightness, 20, "As far as it goes without flagging a keeper")
        XCTAssertEqual(learned.unmet, [UnmetLabel(label: .subjectTooDark, stillPassing: 1, keepersInTheWay: 10, fineInTheWay: false)])
    }

    func testAKeeperLabelledTooDarkIsntInTheWay() {
        let keeper = photo("K_1", stars: 1, brightness: 25)
        let learned = Calibration.learned(from: labelled([(keeper, .subjectTooDark)]), folder: folder, scored: [keeper],
                                          limits: RatingSettings())
        XCTAssertEqual(learned.limits.minimumBrightness, 26)
    }

    func testLooksFineLoosensALimitAndWinsOverTheRest() {
        let fine = photo("A_1", face: 40.9)
        var learned = Calibration.learned(from: labelled([(fine, .fine)]), folder: folder, scored: [fine],
                                          limits: RatingSettings(minimumSharpnessFaces: 50))
        XCTAssertEqual(learned.limits.minimumSharpnessFaces, 40)
        XCTAssertEqual(learned.limits.problems(fine.score), [])

        let soft = photo("A_2", face: 45)
        learned = Calibration.learned(from: labelled([(fine, .fine), (soft, .faceTooSoft)]), folder: folder, scored: [fine, soft],
                                      limits: RatingSettings(minimumSharpnessFaces: 50))
        XCTAssertEqual(learned.limits.minimumSharpnessFaces, 40)
        XCTAssertEqual(learned.unmet, [UnmetLabel(label: .faceTooSoft, stillPassing: 1, keepersInTheWay: 0, fineInTheWay: true)])
    }

    func testFaceAndNoFaceLabelsKeepToTheirOwnPhotos() {
        let faceless = photo("A_1", area: 25)
        let face = photo("A_2", face: 70, area: 900)
        let learned = Calibration.learned(from: labelled([(faceless, .imageTooSoft), (face, .faceTooSoft)]), folder: folder,
                                          scored: [faceless, face], limits: RatingSettings(minimumSharpnessFaces: 50, minimumSharpnessNoFaces: 20))
        XCTAssertEqual(learned.limits.minimumSharpnessNoFaces, 26)
        XCTAssertEqual(learned.limits.minimumSharpnessFaces, 71)
        XCTAssertFalse(PhotoLabel.imageTooSoft.applies(toFace: true))
        XCTAssertFalse(PhotoLabel.faceTooSoft.applies(toFace: false))
    }

    func testLearningAgainChangesNothing() {
        let dark = photo("A_1", brightness: 30)
        let labels = labelled([(dark, .subjectTooDark)])
        let once = Calibration.learned(from: labels, folder: folder, scored: [dark], limits: RatingSettings()).limits
        XCTAssertEqual(Calibration.learned(from: labels, folder: folder, scored: [dark], limits: once).limits, once)
        XCTAssertEqual(Calibration.learned(from: PhotoLabels(), folder: folder, scored: [dark], limits: RatingSettings()).limits,
                       RatingSettings(), "No labels, no change")
    }

    func testLooksFineAndTheOthersRuleEachOtherOut() {
        let shot = photo("A_1")
        var labels = labelled([(shot, .imageTooDark), (shot, .subjectTooDark)])
        XCTAssertEqual(labels.labels(folder: folder, name: shot.id), [.imageTooDark, .subjectTooDark])
        labels.toggle(.fine, for: shot, folder: folder)
        XCTAssertEqual(labels.labels(folder: folder, name: shot.id), [.fine])
        labels.toggle(.imageTooDark, for: shot, folder: folder)
        XCTAssertEqual(labels.labels(folder: folder, name: shot.id), [.imageTooDark])
        labels.toggle(.imageTooDark, for: shot, folder: folder)
        XCTAssertEqual(labels.photos, [], "A photo with no labels left is forgotten")
    }

    func testLabelsAreKeptBesideTheSettingsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PhotoLabels.fileURL(besideSettings: dir.appendingPathComponent("Settings.plist"))
        XCTAssertEqual(url.lastPathComponent, "Calibration Labels.json")
        XCTAssertEqual(try PhotoLabels.load(from: url), PhotoLabels(), "No file yet")
        let shot = photo("A_1", face: 60, crushed: 0.3, brightness: 22)
        var labels = PhotoLabels()
        labels.toggle(.subjectTooDark, for: shot, folder: folder, now: Date(timeIntervalSince1970: 1_800_000_000))
        try labels.save(to: url)
        let read = try PhotoLabels.load(from: url)
        XCTAssertEqual(read, labels)
        XCTAssertEqual(read.photos.first?.subjectBrightness, 22)
        XCTAssertEqual(read.photos.first?.faceScore, shot.score.faceScore)
    }
}
