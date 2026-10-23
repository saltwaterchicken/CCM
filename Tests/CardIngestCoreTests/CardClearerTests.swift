import XCTest
@testable import CardIngestCore

/// Moving a card's originals to its Trash, only once their copies are safe.
final class CardClearerTests: XCTestCase {
    private var base: URL!
    private var card: URL { base.appendingPathComponent("CARD", isDirectory: true) }
    private var main: URL { base.appendingPathComponent("Main", isDirectory: true) }
    /// Stands in for the card's .Trashes, so tests never touch the real Trash.
    private var trashFolder: URL { base.appendingPathComponent("Trash", isDirectory: true) }
    private let fm = FileManager.default
    private var settings = IngestSettings()

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ClearerTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
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

    private func importCard() throws -> (ImportPlan, CopyReport?) {
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD", files: try scan(), settings: settings,
                                          captureDate: { _, _ in nil })
        guard !plan.nothingNew else { return (plan, nil) }
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         importNumber: plan.importNumber)
        settings.nextImportNumber = plan.nextImportNumber(after: settings.nextImportNumber)
        return (plan, report)
    }

    private var fakeTrash: CardClearer.MoveToTrash {
        let folder = trashFolder
        return { url in
            let target = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    private func volume(removable: Bool = true, dcim: Bool = true, readOnly: Bool = false) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true), name: "EOS_DIGITAL",
                   isRemovable: removable, isEjectable: removable, isInternal: false, isLocal: true,
                   isRootFileSystem: false, hasDCIM: dcim, isReadOnly: readOnly)
    }

    func testOnlyACameraCardWithDCIMThatIsntLockedIsCleared() {
        XCTAssertNil(CardClearer.refusal(for: volume(), protectedFolders: []))
        XCTAssertNotNil(CardClearer.refusal(for: volume(removable: false), protectedFolders: []))
        XCTAssertEqual(CardClearer.refusal(for: volume(dcim: false), protectedFolders: []),
                       "This drive has no DCIM folder, so it may not be a camera card. Nothing was moved to the Trash.")
        XCTAssertEqual(CardClearer.refusal(for: volume(readOnly: true), protectedFolders: []),
                       "The card is locked (check the switch on its side), so nothing was moved to the Trash.")
        XCTAssertNotNil(CardClearer.refusal(
            for: volume(), protectedFolders: [URL(fileURLWithPath: "/Volumes/EOS_DIGITAL/Backup")]))
    }

    func testVerifiedFilesGoToTheTrashAndEverythingElseStays() throws {
        try put("DCIM/100CANON/IMG_0001.CR3")
        try put("DCIM/100CANON/IMG_0001.JPG", seed: 2)
        try put("MISC/SETTINGS.DAT", seed: 3)
        let (plan, report) = try importCard()
        let safe = CardClearer.safelyCopied(report: report, check: plan.check)
        XCTAssertEqual(Set(safe.map(\.relativePath)), ["DCIM/100CANON/IMG_0001.CR3", "DCIM/100CANON/IMG_0001.JPG"])

        let result = CardClearer.trash(safe, cardRoot: card, moveToTrash: fakeTrash)
        XCTAssertEqual(result, TrashResult(trashed: 2))
        XCTAssertFalse(fm.fileExists(atPath: card.appendingPathComponent("DCIM/100CANON/IMG_0001.CR3").path))
        // Not a camera file, so never copied and never trashed. Folders stay too.
        XCTAssertTrue(fm.fileExists(atPath: card.appendingPathComponent("MISC/SETTINGS.DAT").path))
        XCTAssertTrue(fm.fileExists(atPath: card.appendingPathComponent("DCIM/100CANON").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: trashFolder.path).count, 2)
        // The copies are untouched.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: plan.folders[0].path).filter { !$0.hasPrefix("Receipt_") }.count, 2)
    }

    func testCardPutBackClearsEarlierImportsOnlyWhileTheirCopiesAreThere() throws {
        try put("DCIM/100CANON/IMG_0001.CR3")
        try put("DCIM/100CANON/IMG_0002.CR3", seed: 2)
        let (first, _) = try importCard()
        // A reject culled from the imported folder: its original stays on the card.
        let culled = try XCTUnwrap(first.files.first { $0.source.relativePath.hasSuffix("IMG_0002.CR3") })
        try fm.removeItem(at: first.folders[0].appendingPathComponent(culled.newName))
        try put("DCIM/100CANON/IMG_0003.CR3", seed: 3)

        let (second, report) = try importCard()
        XCTAssertEqual(second.files.map(\.source.relativePath), ["DCIM/100CANON/IMG_0003.CR3"])
        let safe = CardClearer.safelyCopied(report: report, check: second.check)
        XCTAssertEqual(Set(safe.map(\.relativePath)), ["DCIM/100CANON/IMG_0001.CR3", "DCIM/100CANON/IMG_0003.CR3"])
    }

    func testNothingNewStillClearsWhatEarlierImportsBroughtIn() throws {
        try put("DCIM/100CANON/IMG_0001.CR3")
        _ = try importCard()
        let (again, report) = try importCard()
        XCTAssertTrue(again.nothingNew)
        XCTAssertNil(report)
        XCTAssertEqual(CardClearer.safelyCopied(report: nil, check: again.check).map(\.relativePath),
                       ["DCIM/100CANON/IMG_0001.CR3"])
    }

    func testAFileThatChangedOrVanishedIsLeftAlone() throws {
        try put("DCIM/100CANON/IMG_0001.CR3")
        try put("DCIM/100CANON/IMG_0002.CR3", seed: 2)
        try put("DCIM/100CANON/IMG_0003.CR3", seed: 3)
        let files = try scan()
        try put("DCIM/100CANON/IMG_0002.CR3", bytes: 2000, seed: 2)
        try fm.removeItem(at: card.appendingPathComponent("DCIM/100CANON/IMG_0003.CR3"))
        let outside = CardFile(relativePath: "../Main/x.CR3", size: 1000)

        let result = CardClearer.trash(files + [outside], cardRoot: card, moveToTrash: fakeTrash)
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.failures, [
            "DCIM/100CANON/IMG_0002.CR3: it's missing or changed since it was copied",
            "DCIM/100CANON/IMG_0003.CR3: it's missing or changed since it was copied",
            "../Main/x.CR3: it isn't on the card",
        ])
        XCTAssertTrue(fm.fileExists(atPath: card.appendingPathComponent("DCIM/100CANON/IMG_0002.CR3").path))
    }

    func testAFailedMoveIsListedAndTheRestStillGo() throws {
        try put("DCIM/100CANON/IMG_0001.CR3")
        try put("DCIM/100CANON/IMG_0002.CR3", seed: 2)
        let move = fakeTrash
        let result = CardClearer.trash(try scan(), cardRoot: card, moveToTrash: { url in
            if url.lastPathComponent == "IMG_0001.CR3" { throw CocoaError(.fileWriteNoPermission) }
            return try move(url)
        })
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].hasPrefix("DCIM/100CANON/IMG_0001.CR3: "))
    }

    func testEjectAndTrashSettingsDefaultOnAndLoadFromOldFiles() throws {
        let settings = IngestSettings()
        XCTAssertTrue(settings.trashAfterVerify)
        XCTAssertTrue(settings.ejectWhenDone)
        XCTAssertEqual(settings.confirmTrashForFirstCards, 3)
        let data = try PropertyListEncoder().encode(["destinationRoot": "~/Pictures/Card Ingest"])
        XCTAssertTrue(try PropertyListDecoder().decode(IngestSettings.self, from: data).ejectWhenDone)
    }
}
