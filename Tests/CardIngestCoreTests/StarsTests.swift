import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CardIngestCore

/// Stars in .xmp sidecars: 1 star when a photo lands, kept through re-copies and trashing.
final class StarsTests: XCTestCase {
    private var base: URL!
    private var card: URL { base.appendingPathComponent("CARD", isDirectory: true) }
    private let fm = FileManager.default
    private var settings = IngestSettings()

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("StarsTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        settings.destinationRoot = base.appendingPathComponent("Main").path
        settings.backupRoot = base.appendingPathComponent("Backup").path
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    /// A sidecar like a camera or Lightroom writes, with other fields to keep.
    private func cameraSidecar(rating: Int) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/">
        <xap:Rating>\(rating)</xap:Rating><tiff:Make>Canon</tiff:Make>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    private func put(_ path: String, _ data: Data) throws {
        let url = card.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func bytes(_ count: Int, _ seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    /// A real JPEG, optionally with a rating set "in the camera".
    private func jpeg(rating: Int?) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        if let rating {
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(rating) as CFString))
        }
        CGImageDestinationAddImageAndMetadata(dest, try XCTUnwrap(context.makeImage()), metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Plans and copies the card with stars given as shots land, like the app does.
    @discardableResult
    private func importCard() throws -> (ImportPlan, CopyReport, LiveShots) {
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD",
                                          files: try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes),
                                          settings: settings, captureDate: { _, _ in nil })
        let shots = LiveShots(planned: plan.files, fileTypes: settings.fileTypes)
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         importNumber: plan.importNumber, fileVerified: shots.landed)
        settings.nextImportNumber = plan.nextImportNumber(after: settings.nextImportNumber)
        return (plan, report, shots)
    }

    private func shot(_ shots: LiveShots, endingIn frame: String) throws -> Shot {
        try XCTUnwrap(shots.shots.first { $0.baseName.hasSuffix("_" + frame) })
    }

    // MARK: Sidecars

    func testNewSidecarHoldsTheStars() throws {
        let url = base.appendingPathComponent("2026-10-14-ES_1234.xmp")
        XCTAssertNil(Stars.read(xmp: url))
        try Stars.write(1, toXMP: url)
        XCTAssertEqual(Stars.read(xmp: url), 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<xmp:Rating>1</xmp:Rating>"), text)
        XCTAssertTrue(text.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""))
        try Stars.write(4, toXMP: url)
        XCTAssertEqual(Stars.read(xmp: url), 4)
    }

    func testChangingStarsKeepsEverythingElseInTheSidecar() throws {
        let url = base.appendingPathComponent("IMG_1234.xmp")
        try cameraSidecar(rating: 3).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Stars.read(xmp: url), 3, "Read whatever prefix the camera used")
        try Stars.write(5, toXMP: url)
        XCTAssertEqual(Stars.read(xmp: url), 5)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("<tiff:Make>Canon</tiff:Make>"))
    }

    func testASidecarThatIsntXMPIsLeftAlone() throws {
        let url = base.appendingPathComponent("IMG_1234.xmp")
        try Data("not xmp at all".utf8).write(to: url)
        XCTAssertThrowsError(try Stars.write(2, toXMP: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not xmp at all")
    }

    func testStarsStayInRange() throws {
        let url = base.appendingPathComponent("a.xmp")
        try Stars.write(9, toXMP: url)
        XCTAssertEqual(Stars.read(xmp: url), 5)
        try Stars.write(-1, toXMP: url)
        XCTAssertEqual(Stars.read(xmp: url), -1, "Lightroom's rejected")
    }

    func testRatingSetInTheCamera() throws {
        let rated = base.appendingPathComponent("rated.jpg")
        try jpeg(rating: 4).write(to: rated)
        XCTAssertEqual(Stars.inCamera(rated), 4)
        let plain = base.appendingPathComponent("plain.jpg")
        try jpeg(rating: nil).write(to: plain)
        XCTAssertNil(Stars.inCamera(plain))
    }

    // MARK: On landing

    func testEveryPhotoLandsWithOneStarInEveryDestination() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", RawXMPTests.cr3(xmp: RawXMPTests.block))
        try put("DCIM/100CANON/IMG_0001.JPG", bytes(1000, 2))
        try put("DCIM/100CANON/IMG_0004.HEIC", bytes(900, 3))
        try put("DCIM/100CANON/MVI_0005.MP4", bytes(5000, 4))
        try put("DCIM/100CANON/MVI_0005.THM", bytes(100, 5))
        let (plan, _, shots) = try importCard()

        XCTAssertEqual(shots.ratings.count, 2)
        XCTAssertEqual(shots.starProblems, [])
        for folder in plan.folders {
            let names = Set(try fm.contentsOfDirectory(atPath: folder.path))
            let pair = try shot(shots, endingIn: "0001")
            XCTAssertTrue(names.contains(pair.xmpName), "One sidecar for the RAW+JPEG pair")
            XCTAssertEqual(Stars.read(xmp: folder.appendingPathComponent(pair.xmpName)), 1)
            // The RAW's digest is in its sidecar, so Lightroom reads the stars.
            let text = try String(contentsOf: folder.appendingPathComponent(pair.xmpName), encoding: .utf8)
            XCTAssertTrue(text.contains(RawXMPTests.md5(RawXMPTests.block)))
            XCTAssertEqual(Stars.read(xmp: folder.appendingPathComponent(try shot(shots, endingIn: "0004").xmpName)), 1)
            XCTAssertFalse(names.contains(try shot(shots, endingIn: "0005").xmpName), "Videos get no star")
            XCTAssertEqual(names.filter { $0.hasSuffix(".xmp") }.count, 2)
        }
    }

    func testTheCamerasSidecarAndRatingAreKept() throws {
        try put("DCIM/100CANON/IMG_0002.CR3", bytes(3000, 1))
        try put("DCIM/100CANON/IMG_0002.XMP", Data(cameraSidecar(rating: 3).utf8))
        try put("DCIM/100CANON/IMG_0003.CR3", bytes(3000, 2))
        try put("DCIM/100CANON/IMG_0003.XMP", Data(cameraSidecar(rating: 0).utf8))
        try put("DCIM/100CANON/IMG_0006.JPG", try jpeg(rating: 2))
        let original = try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0003.XMP"))
        let (plan, _, shots) = try importCard()
        let main = plan.folders[0]

        let three = try shot(shots, endingIn: "0002")
        XCTAssertEqual(three.xmpName, three.baseName + ".XMP", "The card's sidecar, not a second one")
        XCTAssertEqual(Stars.read(xmp: main.appendingPathComponent(three.xmpName)), 3)
        // The camera's 0 means "not rated", so it gets 1, keeping the camera's other fields.
        let zero = main.appendingPathComponent(try shot(shots, endingIn: "0003").xmpName)
        XCTAssertEqual(Stars.read(xmp: zero), 1)
        XCTAssertTrue(try String(contentsOf: zero, encoding: .utf8).contains("Canon"))
        XCTAssertEqual(Stars.read(xmp: main.appendingPathComponent(try shot(shots, endingIn: "0006").xmpName)), 2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: main.path).filter { $0.lowercased().hasSuffix(".xmp") }.count, 3)
        // Only the copies are written; the card's own sidecar is untouched.
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0003.XMP")), original)
    }

    // MARK: Loading an earlier import

    func testAnEarlierImportComesBackWithItsStarsAndBackup() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", bytes(3000, 1))
        try put("DCIM/100CANON/IMG_0001.JPG", bytes(1000, 2))
        try put("DCIM/100CANON/IMG_0002.CR3", bytes(3000, 3))
        try put("DCIM/100CANON/MVI_0003.MP4", bytes(5000, 4))
        let (plan, _, shots) = try importCard()
        try Stars.set(4, on: try shot(shots, endingIn: "0002"))
        let main = plan.folders[0]
        // Things that aren't shots: a stray sidecar and a note.
        try Data("x".utf8).write(to: main.appendingPathComponent("leftover.xmp"))
        try Data("x".utf8).write(to: main.appendingPathComponent("notes.txt"))

        let loaded = try ImportedFolder.shots(in: main, backupRoot: settings.backupRootURL, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.map { $0.shot.baseName.suffix(4) }, ["0001", "0002", "0003"])
        XCTAssertEqual(loaded.map(\.stars), [1, 4, nil])
        XCTAssertEqual(loaded.map(\.position), [0, 1, 2])
        XCTAssertEqual(loaded[0].shot.badge, "RAW+JPG")
        XCTAssertEqual(loaded[0].shot.primary.destinations.count, 2, "Main and backup")

        // Stars given now are saved in both, as during a Copy.
        try Stars.set(5, on: loaded[0].shot)
        for folder in plan.folders {
            XCTAssertEqual(Stars.read(xmp: folder.appendingPathComponent(loaded[0].shot.xmpName)), 5)
        }
    }

    func testAFolderWithoutABackupLoadsOnItsOwn() throws {
        settings.backupRoot = ""
        try put("DCIM/100CANON/IMG_0001.JPG", bytes(1000, 2))
        let (plan, _, _) = try importCard()
        let loaded = try ImportedFolder.shots(in: plan.folders[0], backupRoot: nil, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].shot.primary.destinations, [plan.folders[0].appendingPathComponent(loaded[0].shot.primary.newName)])
        XCTAssertThrowsError(try ImportedFolder.shots(in: base.appendingPathComponent("missing"), backupRoot: nil,
                                                      fileTypes: settings.fileTypes))
    }

    // MARK: After stars change a sidecar

    func testAnInterruptedCopyPicksUpInTheSameFolderAndKeepsTheStars() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", bytes(3000, 1))
        try put("DCIM/100CANON/IMG_0002.CR3", bytes(3000, 2))
        try put("DCIM/100CANON/IMG_0002.XMP", Data(cameraSidecar(rating: 0).utf8))
        let (first, _, shots) = try importCard()
        try Stars.set(4, on: try shot(shots, endingIn: "0001"))
        try Stars.set(5, on: try shot(shots, endingIn: "0002"))
        // As if the copy had stopped before the receipt was written.
        for folder in first.folders {
            for name in try fm.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("Receipt_") {
                try fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        settings.nextImportNumber = first.importNumber

        let (again, report, _) = try importCard()
        XCTAssertEqual(again.folders, first.folders, "The stars' sidecars don't make it look like another card")
        XCTAssertTrue(report.files.allSatisfy(\.alreadyThere))
        let main = first.folders[0]
        XCTAssertEqual(Stars.read(xmp: main.appendingPathComponent(try shot(shots, endingIn: "0001").xmpName)), 4)
        XCTAssertEqual(Stars.read(xmp: main.appendingPathComponent(try shot(shots, endingIn: "0002").xmpName)), 5)
    }

    func testACardPutBackStillClearsItsSidecarAfterStarsChangedTheCopy() throws {
        try put("DCIM/100CANON/IMG_0002.CR3", bytes(3000, 1))
        try put("DCIM/100CANON/IMG_0002.XMP", Data(cameraSidecar(rating: 0).utf8))
        _ = try importCard()
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD",
                                          files: try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes),
                                          settings: settings)
        XCTAssertTrue(plan.nothingNew)
        XCTAssertEqual(Set(CardClearer.safelyCopied(report: nil, check: plan.check).map(\.relativePath)),
                       ["DCIM/100CANON/IMG_0002.CR3", "DCIM/100CANON/IMG_0002.XMP"])
    }
}
