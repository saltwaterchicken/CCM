import XCTest
@testable import CardIngestCore

/// Bursts: three or more frames, each within a second of the one before; the
/// sharpest gets the green chip.
final class BurstsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func frame(_ id: String, _ seconds: Double, _ subject: Double?, face: Bool = true) -> Bursts.Frame {
        Bursts.Frame(id: id, taken: start + seconds, subject: subject, subjectIsFace: face)
    }

    func testTheSharpestOfABurstOfThree() {
        let frames = [frame("a", 0, 40), frame("b", 0.1, 90), frame("c", 0.2, 60)]
        XCTAssertEqual(Bursts.sharpest(frames), ["b"])
    }

    func testTwoFramesArentABurst() {
        XCTAssertEqual(Bursts.sharpest([frame("a", 0, 40), frame("b", 0.1, 90)]), [])
    }

    func testMoreThanASecondApartEndsTheBurst() {
        let frames = [frame("a", 0, 40), frame("b", 0.5, 90), frame("c", 1.5, 95),
                      frame("d", 5, 10), frame("e", 5.8, 20), frame("f", 6.6, 15)]
        XCTAssertEqual(Bursts.groups(frames).map { $0.map(\.id) }, [["a", "b", "c"], ["d", "e", "f"]])
        XCTAssertEqual(Bursts.sharpest(frames), ["c", "e"])
        // In any order: they're put in the order taken.
        XCTAssertEqual(Bursts.sharpest(frames.reversed()), ["c", "e"])
        XCTAssertEqual(Bursts.sharpest([frame("a", 0, 40), frame("b", 1.2, 90), frame("c", 2.4, 60)]), [])
    }

    func testFacesWinOverFramesWithout() {
        // The subject turned away in one frame: its sharp background doesn't count against faces.
        let frames = [frame("a", 0, 40), frame("b", 0.1, 300, face: false), frame("c", 0.2, 60)]
        XCTAssertEqual(Bursts.sharpest(frames), ["c"])
        let noFaces = [frame("a", 0, 40, face: false), frame("b", 0.1, 300, face: false), frame("c", 0.2, 60, face: false)]
        XCTAssertEqual(Bursts.sharpest(noFaces), ["b"])
    }

    func testOnlyCheckedFramesCompete() {
        XCTAssertEqual(Bursts.sharpest([frame("a", 0, nil), frame("b", 0.1, 90), frame("c", 0.2, 60)]), ["b"])
        XCTAssertEqual(Bursts.sharpest([frame("a", 0, nil), frame("b", 0.1, nil), frame("c", 0.2, 60)]), [],
                       "One checked frame has nothing to beat")
    }

    func testTheGridMarksTheSharpestAsChecksComeIn() {
        func shot(_ name: String) -> Shot {
            let file = CopiedFile(newName: name, originalPath: name, size: 1, originalModified: nil, checksum: "0",
                                  destinations: [URL(fileURLWithPath: "/Main/" + name)], alreadyThere: false)
            return Shot(baseName: (name as NSString).deletingPathExtension, files: [file], primary: file, kind: .raw, badge: nil)
        }
        var grid = CullGrid()
        grid.add(contentsOf: ["A_1.CR3", "A_2.CR3", "A_3.CR3"].enumerated().map {
            LandedShot(shot: shot($1), stars: nil, position: $0)
        })
        func check(_ subject: Double, _ seconds: Double, stars: Int? = 1) -> AutoCheck {
            AutoCheck(stars: stars, problems: stars == 0 ? [.softFace] : [], score: subject, subject: subject,
                      subjectIsFace: true, taken: start + seconds)
        }
        grid.apply(check(40, 0), to: "a_1")
        grid.apply(check(90, 0.1, stars: 0), to: "a_2")
        XCTAssertEqual(grid.burstSharpest, [], "Two frames checked so far")
        grid.apply(check(60, 0.2), to: "a_3")
        XCTAssertEqual(grid.burstSharpest, ["a_2"], "Flagged or not, the sharpest is marked")
        grid.click("a_2")
        grid.rate(3)
        XCTAssertEqual(grid.burstSharpest, ["a_2"], "Rating it doesn't change which is sharpest")
    }

    func testTheMarkerKeepsWhatBurstsNeed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xmp = folder.appendingPathComponent("A_1.xmp")
        try Stars.write(1, toXMP: xmp, extra: [
            AutoRating.checkedField: "2026-10-30T12:00:00Z", AutoRating.starsField: "1", AutoRating.scoreField: "55.0",
            AutoRating.facesField: "2", AutoRating.subjectField: "42.5",
            AutoRating.takenField: "2026-07-01T15:04:05.25Z",
        ])
        let check = try XCTUnwrap(AutoRating.check(in: xmp))
        XCTAssertEqual(check.subject, 42.5)
        XCTAssertTrue(check.subjectIsFace)
        XCTAssertEqual(try XCTUnwrap(check.taken).timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.25, accuracy: 0.001)

        // Checked before bursts: left out of them.
        let older = folder.appendingPathComponent("A_2.xmp")
        try Stars.write(1, toXMP: older, extra: [AutoRating.checkedField: "2026-10-27T12:00:00Z", AutoRating.starsField: "1",
                                                AutoRating.scoreField: "55.0", AutoRating.facesField: "0"])
        let old = try XCTUnwrap(AutoRating.check(in: older))
        XCTAssertNil(old.subject)
        XCTAssertFalse(old.subjectIsFace)
        XCTAssertNil(old.taken)
    }

    func testTheGridCanShowAnotherOrderAndTheArrowsFollowIt() {
        func shot(_ name: String) -> Shot {
            let file = CopiedFile(newName: name, originalPath: name, size: 1, originalModified: nil, checksum: "0",
                                  destinations: [URL(fileURLWithPath: "/Main/" + name)], alreadyThere: false)
            return Shot(baseName: (name as NSString).deletingPathExtension, files: [file], primary: file, kind: .raw, badge: nil)
        }
        var grid = CullGrid()
        grid.add(contentsOf: ["A_1.CR3", "A_2.CR3", "A_3.CR3", "A_4.CR3"].enumerated().map {
            LandedShot(shot: shot($1), stars: nil, position: $0)
        })
        grid.order = ["a_1": 50, "a_2": 10, "a_3": 30]
        XCTAssertEqual(grid.visible.map(\.id), ["a_2", "a_3", "a_1", "a_4"], "Lowest first; no score goes last")
        grid.click("a_3")
        grid.move(by: 1)
        XCTAssertEqual(grid.focus, "a_1", "The arrows follow the order shown")
        grid.order = nil
        XCTAssertEqual(grid.visible.map(\.id), ["a_1", "a_2", "a_3", "a_4"])
        XCTAssertEqual(grid.focus, "a_1", "The photo stays selected")
    }
}
