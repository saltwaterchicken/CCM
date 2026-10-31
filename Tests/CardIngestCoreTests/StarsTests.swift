import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CardIngestCore

/// Stars in .xmp sidecars, kept through re-copies and trashing. Nothing is written when a
/// shot lands: it shows the stars it came with (card sidecar or camera), or none.
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
        try image(UTType.jpeg, rating: rating)
    }

    /// A real TIFF, which ImageIO reads as it does a DNG: a RAW with a rating inside.
    private func dng(rating: Int?) throws -> Data {
        try image(UTType.tiff, rating: rating)
    }

    private func image(_ type: UTType, rating: Int?) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        if let rating {
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(rating) as CFString))
        }
        CGImageDestinationAddImageAndMetadata(dest, try XCTUnwrap(context.makeImage()), metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Plans and copies the card, handing shots to the grid as they land, like the app does.
    @discardableResult
    private func importCard() throws -> (ImportPlan, CopyReport, LiveShots) {
        try importCardShowing().0
    }

    /// Also what the grid was given, in the order shots landed.
    private func importCardShowing() throws -> ((ImportPlan, CopyReport, LiveShots), [LandedShot]) {
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD",
                                          files: try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes),
                                          settings: settings, captureDate: { _, _ in nil })
        let shots = LiveShots(planned: plan.files, fileTypes: settings.fileTypes)
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         importNumber: plan.importNumber)
        // As the app hands each verified copy over.
        let landed = report.files.compactMap(shots.complete)
        settings.nextImportNumber = plan.nextImportNumber(after: settings.nextImportNumber)
        return ((plan, report, shots), landed)
    }

    private func xmpNames(in folder: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased().hasSuffix(".xmp") }.sorted()
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

    func testEveryRAWGetsAnUnratedSidecarWhenItLands() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", RawXMPTests.cr3(xmp: RawXMPTests.block))
        try put("DCIM/100CANON/IMG_0001.JPG", bytes(1000, 2))
        try put("DCIM/100CANON/IMG_0002.CR3", RawXMPTests.cr3(xmp: RawXMPTests.block))
        try put("DCIM/100CANON/IMG_0004.HEIC", bytes(900, 3))
        try put("DCIM/100CANON/MVI_0005.MP4", bytes(5000, 4))
        try put("DCIM/100CANON/MVI_0005.THM", bytes(100, 5))
        let ((plan, _, shots), landed) = try importCardShowing()

        XCTAssertEqual(landed.count, 4)
        XCTAssertEqual(landed.map(\.stars), [nil, nil, nil, nil], "Unrated until the photographer or the checks rate them")
        XCTAssertEqual(shots.sidecarProblems, [])
        let raws = [try shot(shots, endingIn: "0001"), try shot(shots, endingIn: "0002")]
        for folder in plan.folders {
            // One per RAW (the pair shares its RAW's); none for the HEIC or the clip.
            XCTAssertEqual(try xmpNames(in: folder), raws.map(\.xmpName).sorted())
            for raw in raws {
                let sidecar = folder.appendingPathComponent(raw.xmpName)
                XCTAssertNil(Stars.read(xmp: sidecar), "No rating in it")
                // The RAW's digest is there, so Lightroom trusts the sidecar once it's rated.
                XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains(RawXMPTests.md5(RawXMPTests.block)))
            }
        }
    }

    func testAClipsStarsGoInItsOwnSidecarAndLoadFolderReadsThem() throws {
        try put("DCIM/100CANON/MVI_0005.MP4", bytes(5000, 4))
        let movie = try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/MVI_0005.MP4"))
        let (plan, _, shots) = try importCard()
        let clip = try shot(shots, endingIn: "0005")
        XCTAssertNil(Stars.found(for: clip), "Unrated until the photographer rates it")
        try Stars.set(4, on: clip)
        XCTAssertEqual(Stars.found(for: clip), 4)
        for folder in plan.folders {
            XCTAssertEqual(try xmpNames(in: folder), [clip.baseName + ".xmp"])
            XCTAssertEqual(Stars.read(xmp: folder.appendingPathComponent(clip.xmpName)), 4)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(clip.primary.newName)), movie,
                           "The clip itself is never written to")
        }
        let loaded = try ImportedFolder.shots(in: plan.folders[0], backupRoot: nil, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.map(\.stars), [4])
    }

    func testRatingTheShotWritesItsSidecarWithTheRAWsDigest() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", RawXMPTests.cr3(xmp: RawXMPTests.block))
        try put("DCIM/100CANON/IMG_0001.JPG", bytes(1000, 2))
        let (plan, _, shots) = try importCard()
        let pair = try shot(shots, endingIn: "0001")
        try Stars.set(3, on: pair)
        for folder in plan.folders {
            XCTAssertEqual(try xmpNames(in: folder), [pair.xmpName], "One sidecar for the RAW+JPEG pair")
            XCTAssertEqual(Stars.read(xmp: folder.appendingPathComponent(pair.xmpName)), 3)
            // The RAW's digest is in its sidecar, so Lightroom reads the stars.
            let text = try String(contentsOf: folder.appendingPathComponent(pair.xmpName), encoding: .utf8)
            XCTAssertTrue(text.contains(RawXMPTests.md5(RawXMPTests.block)))
        }
    }

    func testARatingSetInTheCameraShowsAndTheCamerasZeroMeansUnrated() throws {
        try put("DCIM/100CANON/IMG_0001.DNG", try dng(rating: 3))
        try put("DCIM/100CANON/IMG_0002.DNG", try dng(rating: 0))
        let ((plan, _, _), landed) = try importCardShowing()
        XCTAssertEqual(landed.map(\.stars), [3, nil])
        // Copied into the sidecar too, so Lightroom keeps the camera's stars once it trusts the sidecar.
        let sidecars = try xmpNames(in: plan.folders[0])
        XCTAssertEqual(sidecars.count, 2)
        XCTAssertEqual(sidecars.map { Stars.read(xmp: plan.folders[0].appendingPathComponent($0)) }, [3, nil])
        // Loading the folder later agrees: inside a RAW only the camera writes, so its 0 is unrated.
        let loaded = try ImportedFolder.shots(in: plan.folders[0], backupRoot: nil, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.map(\.stars), [3, nil])
    }

    func testTheCamerasSidecarAndRatingAreKept() throws {
        try put("DCIM/100CANON/IMG_0002.CR3", bytes(3000, 1))
        try put("DCIM/100CANON/IMG_0002.XMP", Data(cameraSidecar(rating: 3).utf8))
        try put("DCIM/100CANON/IMG_0003.CR3", bytes(3000, 2))
        try put("DCIM/100CANON/IMG_0003.XMP", Data(cameraSidecar(rating: 0).utf8))
        try put("DCIM/100CANON/IMG_0006.JPG", try jpeg(rating: 2))
        let original = try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0003.XMP"))
        let ((plan, _, shots), landed) = try importCardShowing()
        let main = plan.folders[0]

        // The camera's 0 means "not rated".
        XCTAssertEqual(landed.map(\.stars), [3, nil, 2])
        let three = try shot(shots, endingIn: "0002")
        XCTAssertEqual(three.xmpName, three.baseName + ".XMP", "The card's sidecar, not a second one")
        XCTAssertEqual(Stars.read(xmp: main.appendingPathComponent(three.xmpName)), 3)
        // Copied as it is: nothing written into it when it lands.
        let zero = main.appendingPathComponent(try shot(shots, endingIn: "0003").xmpName)
        XCTAssertEqual(try Data(contentsOf: zero), original)
        XCTAssertEqual(try xmpNames(in: main).count, 2, "Only the card's two sidecars")
        // Rating it later keeps the camera's other fields, and the card's own sidecar is untouched.
        try Stars.set(4, on: try shot(shots, endingIn: "0003"))
        XCTAssertEqual(Stars.read(xmp: zero), 4)
        XCTAssertTrue(try String(contentsOf: zero, encoding: .utf8).contains("Canon"))
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0003.XMP")), original)
    }

    func testAJPEGWithNoRAWLandsUntouchedShowingItsOwnRating() throws {
        try put("DCIM/100CANON/IMG_0001.JPG", try jpeg(rating: 3))
        try put("DCIM/100CANON/IMG_0002.JPG", try jpeg(rating: 0))
        try put("DCIM/100CANON/IMG_0003.HEIC", bytes(900, 3))
        let original = try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0001.JPG"))
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD",
                                          files: try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes),
                                          settings: settings, captureDate: { _, _ in nil })
        let live = LiveShots(planned: plan.files, fileTypes: settings.fileTypes)
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         importNumber: plan.importNumber)
        // As the app hands each verified copy over.
        let landed = report.files.compactMap(live.complete)

        // The camera's 0 means "not rated", as for RAWs.
        XCTAssertEqual(landed.map(\.stars), [3, nil, nil])
        for folder in plan.folders {
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased().hasSuffix(".xmp") }, [])
            let copy = folder.appendingPathComponent(report.files[0].newName)
            XCTAssertEqual(try Data(contentsOf: copy), original, "The copy is exactly the card's file")
        }
    }

    // MARK: Loading an earlier import

    func testLoadingAFolderReadsTheRatingInsideAJPEGWithNoSidecar() throws {
        let folder = base.appendingPathComponent("Exported", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg(rating: 1).write(to: folder.appendingPathComponent("A_0001.jpg"))
        try jpeg(rating: 0).write(to: folder.appendingPathComponent("A_0002.jpg"))
        try jpeg(rating: nil).write(to: folder.appendingPathComponent("A_0003.jpg"))
        try jpeg(rating: 2).write(to: folder.appendingPathComponent("A_0004.jpg"))
        try Stars.write(5, toXMP: folder.appendingPathComponent("A_0004.xmp"))
        // A RAW+JPEG pair goes by its sidecar only, never the JPEG.
        try bytes(3000, 1).write(to: folder.appendingPathComponent("A_0005.CR3"))
        try jpeg(rating: 4).write(to: folder.appendingPathComponent("A_0005.jpg"))
        let before = try Data(contentsOf: folder.appendingPathComponent("A_0001.jpg"))

        let loaded = try ImportedFolder.shots(in: folder, backupRoot: nil, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.map(\.stars), [1, 0, nil, 5, nil], "As saved: a sidecar wins, 0 stays 0")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("A_0001.jpg")), before, "Only read")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".xmp") }, ["A_0004.xmp"])
    }

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
        XCTAssertEqual(loaded.map(\.stars), [nil, 4, nil], "Only the shot given stars has any")
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
