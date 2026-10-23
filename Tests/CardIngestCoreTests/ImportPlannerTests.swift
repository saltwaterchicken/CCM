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
        XCTAssertFalse(plan.nothingNew)
        XCTAssertNil(plan.check.message)
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

    func testCopyPressedTwiceHasNothingNew() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1234.JPG", seed: 2)
        let first = try plan()
        try copy(first)
        settings.nextImportNumber = first.nextImportNumber(after: settings.nextImportNumber)
        XCTAssertEqual(settings.nextImportNumber, 2)

        let again = try plan()
        XCTAssertTrue(again.nothingNew)
        XCTAssertEqual(again.files, [])
        XCTAssertEqual(again.check.alreadyImported.count, 2)
        XCTAssertEqual(again.check.earlierFolders.map(\.lastPathComponent), [first.folders[0].lastPathComponent])
        XCTAssertEqual(again.check.message,
                       "Already imported: all 2 files are in 2026-10-23-ES001. Nothing new to copy.")
        XCTAssertEqual(again.nextImportNumber(after: settings.nextImportNumber), 2, "Nothing new doesn't use up a number")
    }

    // MARK: Cards that were imported before

    /// Copies the card as it is now and moves the counter on, like the app does.
    private func importCard() throws -> ImportPlan {
        let plan = try plan()
        try copy(plan)
        settings.nextImportNumber = plan.nextImportNumber(after: settings.nextImportNumber)
        return plan
    }

    func testCardPutBackWithNewPhotosOnlyImportsTheNewOnes() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1234.JPG", seed: 2)
        try put("DCIM/100CANON/IMG_1235.CR3", seed: 3)
        let first = try importCard()
        // More shooting, then the same card goes back in the reader.
        try put("DCIM/100CANON/IMG_1236.CR3", seed: 4)
        try put("DCIM/100CANON/IMG_1236.JPG", seed: 5)

        let second = try plan()
        XCTAssertEqual(Set(second.files.map(\.source.relativePath)),
                       ["DCIM/100CANON/IMG_1236.CR3", "DCIM/100CANON/IMG_1236.JPG"])
        XCTAssertEqual(second.importNumber, 2)
        XCTAssertEqual(second.folders.first?.lastPathComponent, "2026-10-23-ES002")
        XCTAssertEqual(second.check.alreadyImported.count, 3)
        XCTAssertEqual(second.check.message,
                       "Partly imported before: 3 of 5 files are already in 2026-10-23-ES001. Copy brings in the 2 new files only.")
        let report = try copy(second)
        XCTAssertEqual(report.files.count, 2)
        XCTAssertFalse(report.files.contains(where: \.alreadyThere))
        // The first folder is left as it was.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: first.folders[0].path).filter { !$0.hasPrefix("Receipt_") }.count, 3)

        // Back in again: everything is in one of the two folders.
        let third = try plan()
        XCTAssertTrue(third.nothingNew)
        XCTAssertEqual(third.check.earlierFolders.map(\.lastPathComponent), ["2026-10-23-ES001", "2026-10-23-ES002"])
        XCTAssertEqual(third.check.message,
                       "Already imported: all 5 files are in 2026-10-23-ES001 and 2026-10-23-ES002. Nothing new to copy.")
    }

    func testDeletedRejectsAreNotImportedAgain() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        try put("DCIM/100CANON/IMG_1235.CR3", seed: 2)
        let first = try importCard()
        // The photographer culled one picture from the imported folder.
        try fm.removeItem(at: first.folders[0].appendingPathComponent(first.files[0].newName))
        XCTAssertTrue(try plan().nothingNew)
    }

    func testDeletingTheCardFolderAllowsImportingAgain() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        let first = try importCard()
        try fm.removeItem(at: first.folders[0])
        let again = try plan()
        XCTAssertFalse(again.nothingNew)
        XCTAssertEqual(again.files.count, 1)
        XCTAssertNil(again.check.message)
    }

    func testSameNameAndSizeTakenAtAnotherTimeIsNew() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        let path = card.appendingPathComponent("DCIM/100CANON/IMG_1234.CR3").path
        try fm.setAttributes([.modificationDate: oct14], ofItemAtPath: path)
        _ = try importCard()
        // Card formatted, camera counter reset: a different picture with the same name and size.
        try put("DCIM/100CANON/IMG_1234.CR3", seed: 9)
        try fm.setAttributes([.modificationDate: oct14.addingTimeInterval(86_400 + 7)], ofItemAtPath: path)
        let plan = try plan()
        XCTAssertFalse(plan.nothingNew)
        XCTAssertEqual(plan.importNumber, 2)
    }

    func testSameMomentAllowsCardRoundingAndTimeZones() {
        let t = oct14
        XCTAssertTrue(ImportHistory.sameMoment(t, t))
        XCTAssertTrue(ImportHistory.sameMoment(t, t.addingTimeInterval(2)), "FAT keeps 2-second times")
        XCTAssertTrue(ImportHistory.sameMoment(t, t.addingTimeInterval(-3 * 3600)), "Mac moved 3 time zones")
        XCTAssertTrue(ImportHistory.sameMoment(t, t.addingTimeInterval(5.5 * 3600 + 1)), "Half-hour zone")
        XCTAssertFalse(ImportHistory.sameMoment(t, t.addingTimeInterval(7)))
        XCTAssertFalse(ImportHistory.sameMoment(t, t.addingTimeInterval(3600 + 30)))
        XCTAssertFalse(ImportHistory.sameMoment(t, t.addingTimeInterval(3 * 86_400)))
    }

    func testReceiptWithoutModifiedDatesStillCounts() throws {
        try put("DCIM/100CANON/IMG_1234.CR3")
        let folder = main.appendingPathComponent("2026-10-22-ES001")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let receipt = """
            File,Original Path,Size (bytes),xxHash64,Verified,Copied At
            2026-10-22-ES_1234.CR3,DCIM/100CANON/IMG_1234.CR3,1000,0000000000000000,yes,2026-10-22T09:00:00Z

            Card,CARD
            Import number,1

            """
        try receipt.write(to: folder.appendingPathComponent("Receipt_CARD_2026-10-22_090000.csv"), atomically: true, encoding: .utf8)
        let plan = try plan()
        XCTAssertTrue(plan.nothingNew)
        XCTAssertEqual(plan.check.alreadyImported.first?.newName, "2026-10-22-ES_1234.CR3")
    }

    func testOtherThingsInTheDestinationAreIgnored() throws {
        // A stray file in the destination root, and a folder without a receipt.
        try fm.createDirectory(at: main.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: main.appendingPathComponent("notes.txt"))
        try put("DCIM/100CANON/IMG_1234.CR3")
        XCTAssertFalse(try plan().nothingNew)
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
