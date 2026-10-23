import XCTest
@testable import CardIngestCore

/// Grouping verified copies into shots (RAW+JPEG+sidecars) for the culling grid.
final class ShotsTests: XCTestCase {
    private func copied(_ name: String) -> CopiedFile {
        CopiedFile(newName: name, originalPath: "DCIM/100CANON/" + name, size: 1, originalModified: nil,
                   checksum: "0", destinations: [URL(fileURLWithPath: "/Main/" + name)], alreadyThere: false)
    }

    func testRawJpegAndSidecarsAreOneShot() {
        var list = ShotList(fileTypes: FileTypes())
        XCTAssertEqual(list.add(copied("2026-10-14-ES_1234.CR3")), 0)
        XCTAssertEqual(list.add(copied("2026-10-14-ES_1234.JPG")), 0)
        XCTAssertEqual(list.add(copied("2026-10-14-ES_1234.xmp")), 0)
        XCTAssertEqual(list.add(copied("2026-10-14-ES_1235.JPG")), 1)

        XCTAssertEqual(list.shots.count, 2)
        let pair = list.shots[0]
        XCTAssertEqual(pair.baseName, "2026-10-14-ES_1234")
        XCTAssertEqual(pair.files.count, 3)
        XCTAssertEqual(pair.primary.newName, "2026-10-14-ES_1234.CR3")
        XCTAssertEqual(pair.kind, .raw)
        XCTAssertEqual(pair.badge, "RAW+JPG")
        XCTAssertTrue(pair.isRatable)
        // The camera's own sidecar holds the stars.
        XCTAssertEqual(pair.xmpName, "2026-10-14-ES_1234.xmp")

        let single = list.shots[1]
        XCTAssertNil(single.badge)
        XCTAssertEqual(single.kind, .photo)
        XCTAssertEqual(single.xmpName, "2026-10-14-ES_1235.xmp")
    }

    func testTheRawBecomesTheTileWhicheverLandsFirst() {
        var list = ShotList(fileTypes: FileTypes())
        list.add(copied("2026-10-14-ES_1234.xmp"))
        XCTAssertEqual(list.shots[0].kind, .sidecar)
        list.add(copied("2026-10-14-ES_1234.JPG"))
        XCTAssertEqual(list.shots[0].primary.newName, "2026-10-14-ES_1234.JPG")
        list.add(copied("2026-10-14-ES_1234.CR3"))
        XCTAssertEqual(list.shots[0].primary.newName, "2026-10-14-ES_1234.CR3")
        XCTAssertEqual(list.shots[0].badge, "RAW+JPG")
    }

    func testVideosAreShotsWithoutStars() {
        let list = ShotList(fileTypes: FileTypes(), files: [copied("2026-10-14-ES_0005.MP4"), copied("2026-10-14-ES_0005.THM")])
        XCTAssertEqual(list.shots.count, 1)
        XCTAssertEqual(list.shots[0].kind, .video)
        XCTAssertNil(list.shots[0].badge, "A thumbnail sidecar isn't a second picture")
        XCTAssertFalse(list.shots[0].isRatable)
    }

    func testNamesDifferingOnlyInCaseAreTheSameShotButClashSuffixesAreNot() {
        let list = ShotList(fileTypes: FileTypes(), files: [
            copied("2026-10-14-ES_0001.CR3"), copied("2026-10-14-es_0001.jpg"),
            copied("2026-10-14-ES_0001-2.CR3"),
        ])
        XCTAssertEqual(list.shots.map(\.files.count), [2, 1])
        XCTAssertEqual(list.shots[0].badge, "RAW+JPG")
    }

    /// The fake card's files, renamed by the planner, copied, and grouped as they land.
    func testACopiedCardBecomesShotsInTheOrderTheyLand() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ShotsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let card = base.appendingPathComponent("CARD", isDirectory: true)
        for (i, path) in ["DCIM/100TEST/IMG_0001.CR3", "DCIM/100TEST/IMG_0001.JPG", "DCIM/100TEST/IMG_0004.HEIC",
                          "DCIM/100TEST/MVI_0005.MP4", "DCIM/100TEST/MVI_0005.THM",
                          "DCIM/101TEST/IMG_0001.CR3", "DCIM/101TEST/IMG_0001.JPG"].enumerated() {
            let url = card.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(i), count: 100 + i).write(to: url)
        }
        var settings = IngestSettings()
        settings.destinationRoot = base.appendingPathComponent("Main").path
        let fileTypes = settings.fileTypes
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD",
                                          files: try CardScanner.scan(cardRoot: card, fileTypes: fileTypes),
                                          settings: settings, captureDate: { _, _ in nil })

        final class Live: @unchecked Sendable {
            let lock = NSLock()
            var list: ShotList
            init(_ list: ShotList) { self.list = list }
        }
        let live = Live(ShotList(fileTypes: fileTypes))
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         fileVerified: { file in live.lock.withLock { _ = live.list.add(file) } })

        let shots = live.list.shots
        XCTAssertEqual(shots.count, 4)
        XCTAssertEqual(shots.map(\.badge), shots.map { $0.kind == .raw ? "RAW+JPG" : nil })
        XCTAssertEqual(shots.filter { $0.kind == .raw }.count, 2, "IMG_0001 and its -2 twin from 101TEST")
        XCTAssertEqual(shots.filter(\.isRatable).count, 3)
        XCTAssertEqual(shots.first { $0.kind == .video }?.files.count, 2)
        // Built live or from the finished report, the shots are the same.
        XCTAssertEqual(ShotList(fileTypes: fileTypes, files: report.files), live.list)
    }
}
