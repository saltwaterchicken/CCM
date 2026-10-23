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

    func testAnyRemovableDriveCountsWithoutDCIM() {
        XCTAssertEqual(CardRules.verdict(for: volume(dcim: false), protectedFolders: home), .card)
        let usbStick = volume(path: "/Volumes/USB", removable: true, ejectable: true, dcim: false)
        XCTAssertEqual(CardRules.verdict(for: usbStick, protectedFolders: home), .card)
    }

    func testStartupDriveIsIgnoredEvenWithDCIM() {
        let mac = volume(path: "/", removable: false, ejectable: false, isInternal: true, root: true)
        XCTAssertFalse(CardRules.verdict(for: mac, protectedFolders: home).isCard)
    }

    func testInternalDriveIsIgnored() {
        let drive = volume(removable: false, ejectable: false, isInternal: true)
        XCTAssertFalse(CardRules.verdict(for: drive, protectedFolders: home).isCard)
    }

    func testCardInBuiltInSDSlotCounts() {
        // The built-in SD reader reports the card as internal but removable.
        let card = volume(path: "/Volumes/NO NAME", removable: true, ejectable: true, isInternal: true, dcim: false)
        XCTAssertEqual(CardRules.verdict(for: card, protectedFolders: home), .card)
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
        let url = card.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func testFindsCameraFilesAndSkipsTheRest() throws {
        try write("DCIM/100CANON/IMG_0001.CR3", bytes: 300)
        try write("DCIM/100CANON/IMG_0001.JPG", bytes: 100)
        try write("DCIM/101CANON/MVI_0002.MP4", bytes: 500)
        try write("DCIM/101CANON/MVI_0002.THM", bytes: 10)
        try write("DCIM/100CANON/._IMG_0001.CR3", bytes: 4)   // macOS leftovers
        try write("DCIM/100CANON/.DS_Store", bytes: 4)
        try write("DCIM/100CANON/CANONMSC.CTG", bytes: 4)      // camera index file
        try write("MISC/IMG_9999.JPG", bytes: 4)                // outside DCIM still counts
        try write("MISC/SETTINGS.DAT", bytes: 4)                // not a camera file

        let files = try CardScanner.scan(cardRoot: card, fileTypes: FileTypes())
        XCTAssertEqual(files.map(\.relativePath), [
            "DCIM/100CANON/IMG_0001.CR3",
            "DCIM/100CANON/IMG_0001.JPG",
            "DCIM/101CANON/MVI_0002.MP4",
            "DCIM/101CANON/MVI_0002.THM",
            "MISC/IMG_9999.JPG",
        ])
        XCTAssertEqual(files.map(\.size), [300, 100, 500, 10, 4])
    }

    func testSonyVideoFolderKeepsClipsAndSkipsTheCamerasIndex() throws {
        try write("DCIM/100MSDCF/DSC00001.ARW", bytes: 300)
        try write("PRIVATE/M4ROOT/MEDIAPRO.XML", bytes: 40)       // the RX100's index of its clips
        try write("PRIVATE/M4ROOT/CUEUP.XML", bytes: 40)
        try write("PRIVATE/M4ROOT/STATUS.BIN", bytes: 40)
        try write("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", bytes: 40) // clip thumbnail, not a photo
        try write("PRIVATE/M4ROOT/CLIP/C0001.MP4", bytes: 500)
        try write("PRIVATE/M4ROOT/CLIP/C0001M01.XML", bytes: 50)  // the clip's own sidecar
        try write("PRIVATE/M4ROOT/SUB/C0001S03.MP4", bytes: 100)  // proxy
        try write("XDROOT/General/INDEX.XML", bytes: 40)
        try write("XDROOT/Clip/Clip0001.MXF", bytes: 600)
        try write("XDROOT/Clip/Clip0001M01.XML", bytes: 50)

        let files = try CardScanner.scan(cardRoot: card, fileTypes: FileTypes())
        XCTAssertEqual(files.map(\.relativePath), [
            "DCIM/100MSDCF/DSC00001.ARW",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            "PRIVATE/M4ROOT/CLIP/C0001M01.XML",
            "PRIVATE/M4ROOT/SUB/C0001S03.MP4",
            "XDROOT/Clip/Clip0001.MXF",
            "XDROOT/Clip/Clip0001M01.XML",
        ])
        XCTAssertTrue(CardScanner.isCameraIndex("private/m4root/mediapro.xml"), "Case doesn't matter")
        XCTAssertFalse(CardScanner.isCameraIndex("DCIM/100MSDCF/MEDIAPRO.XML"))
    }

    func testEmptyCard() throws {
        XCTAssertEqual(try CardScanner.scan(cardRoot: card, fileTypes: FileTypes()), [])
    }

    func testCardWithoutDCIM() throws {
        try FileManager.default.removeItem(at: card.appendingPathComponent("DCIM"))
        try FileManager.default.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP"), withIntermediateDirectories: true)
        try write("PRIVATE/M4ROOT/CLIP/C0001.MP4", bytes: 50)
        try FileManager.default.createDirectory(at: card.appendingPathComponent(".Trashes"), withIntermediateDirectories: true)
        try write(".Trashes/OLD.JPG", bytes: 4)
        let files = try CardScanner.scan(cardRoot: card, fileTypes: FileTypes())
        XCTAssertEqual(files.map(\.relativePath), ["PRIVATE/M4ROOT/CLIP/C0001.MP4"])
    }

    func testMissingVolumeThrows() throws {
        try FileManager.default.removeItem(at: card)
        XCTAssertThrowsError(try CardScanner.scan(cardRoot: card, fileTypes: FileTypes()))
    }
}
