import XCTest
@testable import CardIngestCore

/// Choosing the card folder and import number, and naming every file.
final class ImportPlannerTests: XCTestCase {
    private var base: URL!
    private var card: URL { base.appendingPathComponent("CARD", isDirectory: true) }
    private var main: URL { base.appendingPathComponent("Main", isDirectory: true) }
    private var backup: URL { base.appendingPathComponent("Backup", isDirectory: true) }
    private let fm = FileManager.default

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // Imported 2026-10-23 09:05:03 UTC.
    private let today = Date(timeIntervalSince1970: 1_792_746_303)
    // Taken 2026-10-14 09:05:03 UTC.
    private let oct14 = Date(timeIntervalSince1970: 1_791_968_703)

    private var settings = IngestSettings()
    /// Capture dates the fake reader hands out, by file name on the card.
    private var dates: [String: Date] = [:]

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("PlannerTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        settings.destinationRoot = main.path
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func put(_ path: String, bytes: Int = 1000, seed: UInt8 = 1) throws {
        let url = card.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) &+ seed }).write(to: url)
    }

    private func scan() throws -> [CardFile] {
        try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes)
    }

    private func plan(dates: [String: Date]? = nil) throws -> ImportPlan {
        let byName = dates ?? self.dates
        return try ImportPlanner.plan(
            cardRoot: card, cardName: "CARD", files: try scan(), settings: settings,
            today: today, calendar: calendar,
            captureDate: { url, _ in byName[url.lastPathComponent] })
    }

    @discardableResult
    private func copy(_ plan: ImportPlan, cancel: Bool = false) throws -> CopyReport {
        try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                            importNumber: plan.importNumber, isCancelled: { cancel })
    }

    /// New name for each file on the card, by its path on the card.
    private func names(_ plan: ImportPlan) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.files.map { ($0.source.relativePath, $0.newName) })
    }

    // MARK: Card folder and import number

    func testFolderGoesDirectlyInTheDestinationAndBackup() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        settings.backupRoot = backup.path
        let plan = try plan()
        XCTAssertEqual(plan.importNumber, 1)
        XCTAssertEqual(plan.folders.map(\.path), [main.path + "/2026-10-23-ES001", backup.path + "/2026-10-23-ES001"])
        XCTAssertFalse(plan.repeatsEarlierImport)
    }

    func testUsesTheNextImportNumber() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        settings.nextImportNumber = 37
        XCTAssertEqual(try plan().folders.first?.lastPathComponent, "2026-10-23-ES037")
    }

    func testCounterGoesUpOnlyAfterASuccessfulCopy() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        let first = try plan()
        XCTAssertThrowsError(try copy(first, cancel: true))
        // Nothing verified, so nothing changes; trying again gets the same number.
        let retry = try plan()
        XCTAssertEqual(retry.importNumber, 1)
        XCTAssertEqual(retry.folders, first.folders)
        try copy(retry)
        XCTAssertEqual(retry.nextImportNumber(after: settings.nextImportNumber), 2)
    }

    func testCounterNeverGoesDown() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        settings.nextImportNumber = 5
        let plan = try plan()
        // The photographer raised it to 9 while this card was copying.
        XCTAssertEqual(plan.nextImportNumber(after: 9), 9)
        XCTAssertEqual(plan.nextImportNumber(after: 5), 6)
    }

    func testInterruptedCopyResumesInTheSameFolder() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1235.CR3", seed: 2)
        let first = try plan()
        // One file made it before the cable was pulled.
        let done = first.files[0]
        try fm.createDirectory(at: first.folders[0], withIntermediateDirectories: true)
        try fm.copyItem(at: card.appendingPathComponent(done.source.relativePath),
                        to: first.folders[0].appendingPathComponent(done.newName))
        let retry = try plan()
        XCTAssertEqual(retry.folders, first.folders)
        let report = try copy(retry)
        XCTAssertEqual(report.files.filter(\.alreadyThere).map(\.newName), [done.newName])
    }

    func testCopyPressedTwiceFindsTheFilesAlreadyThere() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1234.JPG", seed: 2)
        let first = try plan()
        try copy(first)
        settings.nextImportNumber = first.nextImportNumber(after: settings.nextImportNumber)
        XCTAssertEqual(settings.nextImportNumber, 2)

        let again = try plan()
        XCTAssertTrue(again.repeatsEarlierImport)
        XCTAssertEqual(again.folders, first.folders)
        XCTAssertEqual(again.importNumber, 1)
        let report = try copy(again)
        XCTAssertTrue(report.files.allSatisfy(\.alreadyThere))
        XCTAssertEqual(again.nextImportNumber(after: settings.nextImportNumber), 2, "Copying again doesn't use up a number")
    }

    func testFolderFromAnotherCardIsSkipped() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        let taken = main.appendingPathComponent("2026-10-23-ES001")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("another card's photo".utf8).write(to: taken.appendingPathComponent("2026-10-14-ES_0001.CR3"))
        let plan = try plan()
        XCTAssertEqual(plan.importNumber, 2)
        XCTAssertEqual(plan.folders.first?.lastPathComponent, "2026-10-23-ES002")
        XCTAssertEqual(plan.nextImportNumber(after: 1), 3)
    }

    func testSameNameButDifferentSizeIsAnotherCard() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        dates["IMG_1234.CR3"] = oct14
        let taken = main.appendingPathComponent("2026-10-23-ES001")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("not the same".utf8).write(to: taken.appendingPathComponent("2026-10-14-ES_1234.CR3"))
        XCTAssertEqual(try plan().importNumber, 2)
    }

    func testFolderTakenInTheBackupIsSkippedToo() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        settings.backupRoot = backup.path
        let taken = backup.appendingPathComponent("2026-10-23-ES001")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: taken.appendingPathComponent("OTHER.JPG"))
        XCTAssertEqual(try plan().folders.map(\.lastPathComponent), ["2026-10-23-ES002", "2026-10-23-ES002"])
    }

    func testEmptyFolderIsUsed() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try fm.createDirectory(at: main.appendingPathComponent("2026-10-23-ES001"), withIntermediateDirectories: true)
        XCTAssertEqual(try plan().importNumber, 1)
    }

    func testFolderWithoutISeqRefusesToMixCards() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        settings.folderName = "{todayyear4}-{todaymonth0}-{todayday0}"
        let taken = main.appendingPathComponent("2026-10-23")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: taken.appendingPathComponent("OTHER.JPG"))
        XCTAssertThrowsError(try plan()) { error in
            guard case PlanError.folderHoldsAnotherCard = error else { return XCTFail("Got \(error)") }
        }
    }

    func testTyposStopTheJobBeforeCopying() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        settings.folderName = "{todayyear4}-{jobname}"
        XCTAssertThrowsError(try plan()) { error in
            XCTAssertEqual(error as? TemplateError, .unknownToken("jobname"))
        }
        settings = IngestSettings(destinationRoot: main.path, renamePattern: "{year4}_{fram4}")
        XCTAssertThrowsError(try plan()) { error in
            XCTAssertEqual(error as? TemplateError, .unknownToken("fram4"))
        }
        XCTAssertFalse(fm.fileExists(atPath: main.path), "Nothing was created")
    }

    // MARK: File names

    func testDefaultNameUsesCaptureDateAndFrameNumber() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/101MSDCF/DSC01235.ARW")
        dates = ["IMG_1234.CR3": oct14, "DSC01235.ARW": oct14]
        XCTAssertEqual(names(try plan()), [
            "DCIM/100CANON/IMG_1234.CR3": "2026-10-14-ES_1234.CR3",
            "DCIM/101MSDCF/DSC01235.ARW": "2026-10-14-ES_1235.ARW",
        ])
    }

    func testExtensionIsKeptAsOnTheCard() throws {
        try put("DCIM/100CANON/IMG_1234.cr3")
        dates = ["IMG_1234.cr3": oct14]
        XCTAssertEqual(try plan().files.map(\.newName), ["2026-10-14-ES_1234.cr3"])
    }

    func testRawJpegAndSidecarsShareTheRawDate() throws {
        for name in ["IMG_1234.CR3", "IMG_1234.JPG", "IMG_1234.xmp", "MVI_0005.MP4", "MVI_0005.THM", "MVI_0005.WAV",
                     "GX010007.MP4", "GX010007.LRV"] {
            try put("DCIM/100CANON/" + name)
        }
        // The JPEG claims another day; the RAW wins. Sidecars have no date of their own.
        dates = ["IMG_1234.CR3": oct14, "IMG_1234.JPG": today, "IMG_1234.xmp": today,
                 "MVI_0005.MP4": oct14, "MVI_0005.THM": today, "GX010007.MP4": oct14]
        XCTAssertEqual(names(try plan()), [
            "DCIM/100CANON/IMG_1234.CR3": "2026-10-14-ES_1234.CR3",
            "DCIM/100CANON/IMG_1234.JPG": "2026-10-14-ES_1234.JPG",
            "DCIM/100CANON/IMG_1234.xmp": "2026-10-14-ES_1234.xmp",
            "DCIM/100CANON/MVI_0005.MP4": "2026-10-14-ES_0005.MP4",
            "DCIM/100CANON/MVI_0005.THM": "2026-10-14-ES_0005.THM",
            "DCIM/100CANON/MVI_0005.WAV": "2026-10-14-ES_0005.WAV",
            "DCIM/100CANON/GX010007.MP4": "2026-10-14-ES_0007.MP4",
            "DCIM/100CANON/GX010007.LRV": "2026-10-14-ES_0007.LRV",
        ])
    }

    func testJpegDateIsUsedWhenTheRawHasNone() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1234.JPG")
        dates = ["IMG_1234.JPG": oct14]
        XCTAssertEqual(Set(try plan().files.map(\.newName)), ["2026-10-14-ES_1234.CR3", "2026-10-14-ES_1234.JPG"])
    }

    func testFallsBackToModifiedDate() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1234.XMP")
        // 2026-03-05 18:00:00 UTC
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_772_733_600)],
                             ofItemAtPath: card.appendingPathComponent("DCIM/100CANON/IMG_1234.CR3").path)
        XCTAssertEqual(Set(try plan().files.map(\.newName)), ["2026-03-05-ES_1234.CR3", "2026-03-05-ES_1234.XMP"])
    }

    func testSameNameGetsANumberAndNothingIsOverwritten() throws {
        // A camera's counter rolled over: two different IMG_0001s, plus a JPEG
        // that goes with the second one.
        try put("DCIM/100CANON/IMG_0001.CR3", seed: 1)
        try put("DCIM/101CANON/IMG_0001.CR3", seed: 2)
        try put("DCIM/101CANON/IMG_0001.JPG", seed: 3)
        try put("DCIM/102CANON/IMG_0001.CR3", seed: 4)
        dates = ["IMG_0001.CR3": oct14, "IMG_0001.JPG": oct14]
        let plan = try plan()
        XCTAssertEqual(names(plan), [
            "DCIM/100CANON/IMG_0001.CR3": "2026-10-14-ES_0001.CR3",
            "DCIM/101CANON/IMG_0001.CR3": "2026-10-14-ES_0001-2.CR3",
            "DCIM/101CANON/IMG_0001.JPG": "2026-10-14-ES_0001-2.JPG",
            "DCIM/102CANON/IMG_0001.CR3": "2026-10-14-ES_0001-3.CR3",
        ])
        let report = try copy(plan)
        for file in report.files {
            XCTAssertEqual(try Data(contentsOf: plan.folders[0].appendingPathComponent(file.newName)),
                           try Data(contentsOf: card.appendingPathComponent(file.originalPath)))
        }
    }

    func testLaterPictureGetsTheNumber() throws {
        try put("DCIM/100CANON/IMG_0001.CR3")
        try put("DCIM/101CANON/IMG_0001.JPG")
        let jpegTime = oct14
        let reader: ImportPlanner.CaptureDateReader = { url, _ in
            url.pathExtension == "CR3" ? jpegTime.addingTimeInterval(60) : jpegTime
        }
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD", files: try scan(), settings: settings,
                                          today: today, calendar: calendar, captureDate: reader)
        XCTAssertEqual(names(plan), [
            "DCIM/101CANON/IMG_0001.JPG": "2026-10-14-ES_0001.JPG",
            "DCIM/100CANON/IMG_0001.CR3": "2026-10-14-ES_0001-2.CR3",
        ])
    }

    func testFilesGoFlatIntoTheCardFolder() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let plan = try plan()
        try copy(plan)
        let folder = plan.folders[0]
        let listed = try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix("Receipt_") }
        XCTAssertEqual(Set(listed), Set(plan.files.map(\.newName)))
        XCTAssertFalse(plan.files.contains { $0.newName.contains("/") })
    }

    func testReceiptShowsOriginalPathNextToNewName() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        dates = ["IMG_1234.CR3": oct14]
        let report = try copy(try plan())
        let receipt = try String(contentsOf: report.receipts[0], encoding: .utf8)
        XCTAssertTrue(receipt.hasPrefix("File,Original Path,"))
        XCTAssertTrue(receipt.contains("\n2026-10-14-ES_1234.CR3,DCIM/100CANON/IMG_1234.CR3,1000,"))
    }

    func testFileKinds() {
        let types = FileTypes()
        XCTAssertEqual(types.kind(of: "a.CR3"), .raw)
        XCTAssertEqual(types.kind(of: "a.jpg"), .photo)
        XCTAssertEqual(types.kind(of: "a.MP4"), .video)
        XCTAssertEqual(types.kind(of: "a.THM"), .sidecar)
        XCTAssertEqual(types.kind(of: "a.txt"), .other)
    }
}
