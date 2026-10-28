import XCTest
@testable import CardIngestCore

/// Keywords in .xmp sidecars: the job's on every photo as it lands, and more
/// added or taken off from the grid. Clips and the card are never touched.
final class KeywordsTests: XCTestCase {
    private var base: URL!
    private var card: URL { base.appendingPathComponent("CARD", isDirectory: true) }
    private let fm = FileManager.default
    private var settings = IngestSettings()

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("KeywordsTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        settings.destinationRoot = base.appendingPathComponent("Main").path
        settings.backupRoot = base.appendingPathComponent("Backup").path
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func put(_ path: String, _ data: Data) throws {
        let url = card.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func bytes(_ count: Int, _ seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    /// A sidecar as Lightroom writes it, with keywords, a rating and other fields to keep.
    private let lightroomSidecar = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
         xmlns:dc="http://purl.org/dc/elements/1.1/">
        <xmp:Rating>3</xmp:Rating><tiff:Make>Canon</tiff:Make>
        <dc:subject><rdf:Bag><rdf:li>Campfire</rdf:li><rdf:li>Lake</rdf:li></rdf:Bag></dc:subject>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """

    /// Plans and copies the card with the job's keywords, as the app does.
    private func importCard(keywords: [String]) throws -> (ImportPlan, LiveShots, [LandedShot]) {
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD",
                                          files: try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes),
                                          settings: settings, captureDate: { _, _ in nil })
        let shots = LiveShots(planned: plan.files, fileTypes: settings.fileTypes, keywords: keywords)
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         importNumber: plan.importNumber)
        let landed = report.files.compactMap(shots.complete)
        return (plan, shots, landed)
    }

    private func shot(_ shots: LiveShots, endingIn frame: String) throws -> Shot {
        try XCTUnwrap(shots.shots.first { $0.baseName.hasSuffix("_" + frame) })
    }

    // MARK: Typing and sidecars

    func testTypedKeywordsSplitOnCommasAndKeepEachOnce() {
        XCTAssertEqual(Keywords.parse("Camp, 2026,Summer"), ["Camp", "2026", "Summer"])
        XCTAssertEqual(Keywords.parse(" Lake ; canoe\nsunset , "), ["Lake", "canoe", "sunset"])
        XCTAssertEqual(Keywords.parse("Camp, camp, CAMP"), ["Camp"], "Case doesn't make another keyword")
        XCTAssertEqual(Keywords.parse("Camp Kenwood, Cabin 4"), ["Camp Kenwood", "Cabin 4"], "Spaces inside are kept")
        XCTAssertEqual(Keywords.parse(" , ,"), [])
        XCTAssertEqual(Keywords.merged(["Camp"], adding: ["camp", "Lake"]), ["Camp", "Lake"])
        XCTAssertEqual(Keywords.removing("LAKE", from: ["Camp", "Lake"]), ["Camp"])
    }

    func testKeywordsGoInTheSidecarBesideTheStars() throws {
        let url = base.appendingPathComponent("2026-10-28-ES_0001.xmp")
        XCTAssertEqual(Keywords.read(xmp: url), [])
        try Stars.write(2, toXMP: url, keywords: ["Camp", "Lake"])
        XCTAssertEqual(Keywords.read(xmp: url), ["Camp", "Lake"])
        XCTAssertEqual(Stars.read(xmp: url), 2)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("dc:subject"), text)
        XCTAssertTrue(text.contains("http://purl.org/dc/elements/1.1/"), text)
        // Stars alone leave the keywords as they are.
        try Stars.write(4, toXMP: url)
        XCTAssertEqual(Keywords.read(xmp: url), ["Camp", "Lake"])
        // An empty list takes them out; the stars stay.
        try Stars.write(nil, toXMP: url, keywords: [])
        XCTAssertEqual(Keywords.read(xmp: url), [])
        XCTAssertEqual(Stars.read(xmp: url), 4)
    }

    func testLightroomsKeywordsAreReadAndKept() throws {
        let url = base.appendingPathComponent("IMG_0001.xmp")
        try lightroomSidecar.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Keywords.read(xmp: url), ["Campfire", "Lake"])
        try Stars.write(nil, toXMP: url, keywords: Keywords.merged(Keywords.read(xmp: url), adding: ["Night"]))
        XCTAssertEqual(Keywords.read(xmp: url), ["Campfire", "Lake", "Night"])
        XCTAssertEqual(Stars.read(xmp: url), 3)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Canon"))
    }

    // MARK: On landing

    func testTheJobsKeywordsGoOnEveryPhotoAsItLands() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", RawXMPTests.cr3(xmp: RawXMPTests.block))
        try put("DCIM/100CANON/IMG_0001.JPG", bytes(1000, 2))
        try put("DCIM/100CANON/IMG_0002.JPG", bytes(1200, 3))
        try put("DCIM/100CANON/MVI_0005.MP4", bytes(5000, 4))
        let jpeg = try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0002.JPG"))
        let (plan, shots, landed) = try importCard(keywords: ["Camp", "2026", "Summer"])

        XCTAssertEqual(landed.map(\.keywords), [["Camp", "2026", "Summer"], ["Camp", "2026", "Summer"], []],
                       "The pair and the JPEG get them; the clip doesn't")
        XCTAssertEqual(landed.map(\.stars), [nil, nil, nil], "Keywords don't rate anything")
        XCTAssertEqual(shots.sidecarProblems, [])
        let pair = try shot(shots, endingIn: "0001"), single = try shot(shots, endingIn: "0002")
        for folder in plan.folders {
            let sidecars = try fm.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased().hasSuffix(".xmp") }.sorted()
            XCTAssertEqual(sidecars, [pair.xmpName, single.xmpName].sorted(), "None for the clip")
            XCTAssertEqual(Keywords.read(xmp: folder.appendingPathComponent(pair.xmpName)), ["Camp", "2026", "Summer"])
            // Still the RAW's digest, so Lightroom reads the sidecar.
            let text = try String(contentsOf: folder.appendingPathComponent(pair.xmpName), encoding: .utf8)
            XCTAssertTrue(text.contains(RawXMPTests.md5(RawXMPTests.block)))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(single.primary.newName)), jpeg,
                           "The JPEG itself is never written to")
        }
    }

    func testTheCardsOwnSidecarGetsTheJobsKeywordsAddedAndTheCardIsUntouched() throws {
        try put("DCIM/100CANON/IMG_0003.CR3", bytes(3000, 1))
        try put("DCIM/100CANON/IMG_0003.XMP", Data(lightroomSidecar.utf8))
        let original = try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0003.XMP"))
        let (plan, shots, landed) = try importCard(keywords: ["camp", "Summer"])
        let raw = try shot(shots, endingIn: "0003")
        XCTAssertEqual(landed.map(\.keywords), [["Campfire", "Lake", "camp", "Summer"]])
        XCTAssertEqual(landed.map(\.stars), [3])
        let copy = plan.folders[0].appendingPathComponent(raw.xmpName)
        XCTAssertEqual(Keywords.read(xmp: copy), ["Campfire", "Lake", "camp", "Summer"])
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0003.XMP")), original)
    }

    func testNoJobKeywordsWritesNothingNew() throws {
        try put("DCIM/100CANON/IMG_0002.JPG", bytes(1200, 3))
        let (plan, _, landed) = try importCard(keywords: [])
        XCTAssertEqual(landed.map(\.keywords), [[]])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: plan.folders[0].path).filter { $0.lowercased().hasSuffix(".xmp") }, [])
    }

    // MARK: From the grid

    func testAddingAndRemovingKeywordsWritesEveryDestination() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", RawXMPTests.cr3(xmp: RawXMPTests.block))
        try put("DCIM/100CANON/MVI_0005.MP4", bytes(5000, 4))
        let (plan, shots, _) = try importCard(keywords: [])
        let raw = try shot(shots, endingIn: "0001"), clip = try shot(shots, endingIn: "0005")
        try Stars.set(3, on: raw)

        try Keywords.add(["Canoe", "Lake"], to: raw)
        try Keywords.add(["lake", "Sunset"], to: raw)
        try Keywords.add(["Canoe"], to: clip)
        for folder in plan.folders {
            let sidecar = folder.appendingPathComponent(raw.xmpName)
            XCTAssertEqual(Keywords.read(xmp: sidecar), ["Canoe", "Lake", "Sunset"])
            XCTAssertEqual(Stars.read(xmp: sidecar), 3, "Stars are kept")
        }
        XCTAssertEqual(Keywords.found(for: raw), ["Canoe", "Lake", "Sunset"])
        XCTAssertEqual(Keywords.found(for: clip), [])

        try Keywords.remove(["LAKE"], from: raw)
        for folder in plan.folders {
            XCTAssertEqual(Keywords.read(xmp: folder.appendingPathComponent(raw.xmpName)), ["Canoe", "Sunset"])
            XCTAssertFalse(try fm.contentsOfDirectory(atPath: folder.path).contains(clip.baseName + ".xmp"))
        }

        // Back another day with Load Folder, the keywords are there.
        let loaded = try ImportedFolder.shots(in: plan.folders[0], backupRoot: nil, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.map(\.keywords), [["Canoe", "Sunset"], []])
    }

    func testAnInterruptedCopyStillFindsItsFolderAfterKeywordsChangedASidecar() throws {
        try put("DCIM/100CANON/IMG_0001.CR3", bytes(3000, 1))
        let (first, shots, _) = try importCard(keywords: ["Camp"])
        try Keywords.add(["Lake"], to: try shot(shots, endingIn: "0001"))
        for folder in first.folders {
            for name in try fm.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("Receipt_") {
                try fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        settings.nextImportNumber = first.importNumber
        let (again, _, landed) = try importCard(keywords: ["Camp"])
        XCTAssertEqual(again.folders, first.folders)
        XCTAssertEqual(landed.map(\.keywords), [["Camp", "Lake"]], "Nothing lost, nothing doubled")
    }
}

/// The keyword bar's view of the selection.
final class CullGridKeywordsTests: XCTestCase {
    private func shot(_ name: String) -> Shot {
        ShotList(fileTypes: FileTypes(), files: [
            CopiedFile(newName: name, originalPath: "DCIM/" + name, size: 1, originalModified: nil, checksum: "0",
                       destinations: [URL(fileURLWithPath: "/Main/" + name)], alreadyThere: false),
        ]).shots[0]
    }

    private func grid() -> CullGrid {
        var grid = CullGrid()
        grid.add(LandedShot(shot: shot("ES_0001.CR3"), stars: nil, position: 0, keywords: ["Camp"]))
        grid.add(LandedShot(shot: shot("ES_0002.CR3"), stars: nil, position: 1))
        grid.add(LandedShot(shot: shot("ES_0003.MP4"), stars: nil, position: 2))
        return grid
    }

    func testKeywordsGoOnTheSelectedPhotosOnly() {
        var grid = grid()
        XCTAssertEqual(grid.addKeywords(["Lake"]), [], "Nothing selected")
        grid.click("es_0001")
        grid.click("es_0003", shift: true)
        XCTAssertEqual(grid.selectedPhotos.map(\.id), ["es_0001", "es_0002"], "The clip takes none")
        XCTAssertEqual(grid.selectionKeywords, [SelectionKeyword(keyword: "Camp", onAll: false)])

        XCTAssertEqual(grid.addKeywords(["camp", "Lake"]).map(\.id), ["es_0001", "es_0002"])
        XCTAssertEqual(grid.keywords["es_0001"], ["Camp", "Lake"])
        XCTAssertEqual(grid.keywords["es_0002"], ["camp", "Lake"])
        XCTAssertNil(grid.keywords["es_0003"])
        XCTAssertEqual(grid.selectionKeywords, [SelectionKeyword(keyword: "Camp", onAll: true),
                                                SelectionKeyword(keyword: "Lake", onAll: true)])
        XCTAssertEqual(grid.addKeywords(["Lake"]), [], "Already there: nothing to write")
        XCTAssertEqual(grid.selected, ["es_0001", "es_0002", "es_0003"], "The selection stays for more")

        grid.click("es_0002")
        XCTAssertEqual(grid.removeKeyword("LAKE").map(\.id), ["es_0002"])
        XCTAssertEqual(grid.keywords["es_0002"], ["camp"])
        XCTAssertEqual(grid.keywords["es_0001"], ["Camp", "Lake"], "Only the selection changes")
        XCTAssertEqual(grid.removeKeyword("Camp").map(\.id), ["es_0002"])
        XCTAssertNil(grid.keywords["es_0002"])
        XCTAssertEqual(grid.removeKeyword("Camp"), [])
    }

    func testHelpFindsKeywords() {
        XCTAssertEqual(Help.search("add keywords").first?.id, "keywords")
        XCTAssertEqual(Help.search("tags").first?.id, "keywords")
    }
}
