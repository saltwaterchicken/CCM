import XCTest
@testable import CardIngestCore

final class CardRulesTests: XCTestCase {
    private func volume(
        path: String = "/Volumes/EOS_DIGITAL", removable: Bool = true, ejectable: Bool = true,
        isInternal: Bool = false, local: Bool = true, root: Bool = false, dcim: Bool = true
    ) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: path, isDirectory: true), name: (path as NSString).lastPathComponent,
                   isRemovable: removable, isEjectable: ejectable, isInternal: isInternal,
                   isLocal: local, isRootFileSystem: root, hasDCIM: dcim)
    }

    private let home = [URL(fileURLWithPath: "/Users/me/Pictures/Card Ingest")]

    func testSDCardIsACard() {
        XCTAssertEqual(CardRules.verdict(for: volume(), protectedFolders: home), .card)
    }

    func testDiskImageCountsBecauseItIsEjectable() {
        let fake = volume(path: "/Volumes/FAKECARD", removable: false, ejectable: true)
        XCTAssertEqual(CardRules.verdict(for: fake, protectedFolders: home), .card)
    }

    func testNoDCIMIsIgnored() {
        XCTAssertFalse(CardRules.verdict(for: volume(dcim: false), protectedFolders: home).isCard)
    }

    func testStartupDriveIsIgnoredEvenWithDCIM() {
        let mac = volume(path: "/", removable: false, ejectable: false, isInternal: true, root: true)
        XCTAssertFalse(CardRules.verdict(for: mac, protectedFolders: home).isCard)
    }

    func testInternalDriveIsIgnored() {
        XCTAssertFalse(CardRules.verdict(for: volume(isInternal: true), protectedFolders: home).isCard)
    }

    func testNetworkVolumeIsIgnored() {
        XCTAssertFalse(CardRules.verdict(for: volume(local: false), protectedFolders: home).isCard)
    }

    func testFixedDriveIsIgnored() {
        XCTAssertFalse(CardRules.verdict(for: volume(removable: false, ejectable: false), protectedFolders: home).isCard)
    }

    func testDriveHoldingTheDestinationOrBackupIsIgnored() {
        let backup = volume(path: "/Volumes/Backup", removable: false, ejectable: true)
        let folders = home + [URL(fileURLWithPath: "/Volumes/Backup/Photos")]
        XCTAssertFalse(CardRules.verdict(for: backup, protectedFolders: folders).isCard)
        // A similarly named volume is not affected.
        let other = volume(path: "/Volumes/Back")
        XCTAssertTrue(CardRules.verdict(for: other, protectedFolders: folders).isCard)
    }
}

final class CardScannerTests: XCTestCase {
    private var card: URL!

    override func setUpWithError() throws {
        card = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeCard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/100CANON"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/101CANON"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("MISC"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: card)
    }

    private func write(_ path: String, bytes: Int) throws {
        try Data(repeating: 7, count: bytes).write(to: card.appendingPathComponent(path))
    }

    func testFindsCameraFilesAndSkipsTheRest() throws {
        try write("DCIM/100CANON/IMG_0001.CR3", bytes: 300)
        try write("DCIM/100CANON/IMG_0001.JPG", bytes: 100)
        try write("DCIM/101CANON/MVI_0002.MP4", bytes: 500)
        try write("DCIM/101CANON/MVI_0002.THM", bytes: 10)
        try write("DCIM/100CANON/._IMG_0001.CR3", bytes: 4)   // macOS leftovers
        try write("DCIM/100CANON/.DS_Store", bytes: 4)
        try write("DCIM/100CANON/CANONMSC.CTG", bytes: 4)      // camera index file
        try write("MISC/IMG_9999.JPG", bytes: 4)                // outside DCIM

        let files = try CardScanner.scan(cardRoot: card, fileTypes: FileTypes())
        XCTAssertEqual(files.map(\.relativePath), [
            "DCIM/100CANON/IMG_0001.CR3",
            "DCIM/100CANON/IMG_0001.JPG",
            "DCIM/101CANON/MVI_0002.MP4",
            "DCIM/101CANON/MVI_0002.THM",
        ])
        XCTAssertEqual(files.map(\.size), [300, 100, 500, 10])
    }

    func testEmptyCard() throws {
        XCTAssertEqual(try CardScanner.scan(cardRoot: card, fileTypes: FileTypes()), [])
    }

    func testMissingDCIMThrows() throws {
        try FileManager.default.removeItem(at: card.appendingPathComponent("DCIM"))
        XCTAssertThrowsError(try CardScanner.scan(cardRoot: card, fileTypes: FileTypes()))
    }
}
