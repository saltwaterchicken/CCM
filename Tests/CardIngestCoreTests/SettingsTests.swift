import XCTest
@testable import CardIngestCore

final class SettingsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadOrCreateWritesDefaultsWhenMissing() throws {
        let url = tempDir.appendingPathComponent("Nested/Settings.plist")
        let settings = try SettingsStore.loadOrCreate(at: url)
        XCTAssertEqual(settings, IngestSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<?xml"), "Settings should be saved as readable XML")
    }

    func testRoundTrip() throws {
        let url = tempDir.appendingPathComponent("Settings.plist")
        var settings = IngestSettings()
        settings.folderName = "{todayyear4}-Smith Wedding-{iseq}"
        settings.nextImportNumber = 42
        settings.backupRoot = "/Volumes/Backup/Photos"
        settings.metadata.keywords = ["wedding", "Portland"]
        settings.rating.sharpnessThreshold = 42
        try SettingsStore.save(settings, to: url)
        XCTAssertEqual(try SettingsStore.load(from: url), settings)
    }

    private func writePlist(_ name: String, _ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPartialProjectFileFallsBackToDefaults() throws {
        let url = try writePlist("Project.plist", """
            <key>folderName</key><string>{todayyear4}-Camp-{iseq}</string>
            <key>rating</key><dict><key>enabled</key><false/></dict>
        """)
        let settings = try SettingsStore.load(from: url)
        XCTAssertEqual(settings.folderName, "{todayyear4}-Camp-{iseq}")
        XCTAssertEqual(settings.nextImportNumber, 1)
        XCTAssertFalse(settings.rating.enabled)
        XCTAssertEqual(settings.rating.sharpnessThreshold, RatingSettings().sharpnessThreshold)
        XCTAssertEqual(settings.renamePattern, IngestSettings().renamePattern)
        XCTAssertEqual(settings.fileTypes, FileTypes())
    }

    func testNewDefaults() throws {
        let settings = IngestSettings()
        XCTAssertEqual(settings.folderName, "{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}")
        XCTAssertEqual(settings.renamePattern, "{year4}-{month0}-{day0}-ES_{frame4}")
        XCTAssertEqual(settings.nextImportNumber, 1)
    }

    func testMilestone1SettingsFileStillLoads() throws {
        // Exactly what Milestone 1 wrote on first launch, plus a job name typed in.
        let url = try writePlist("Old.plist", """
            <key>schemaVersion</key><integer>1</integer>
            <key>jobName</key><string>Smith Wedding</string>
            <key>destinationRoot</key><string>~/Pictures/Card Ingest</string>
            <key>backupRoot</key><string>/Volumes/Backup</string>
            <key>folderPattern</key><string>{date:YYYY}/{date:YYYY-MM-DD}_{job}</string>
            <key>renamePattern</key><string>{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}</string>
            <key>checksum</key><string>xxh64</string>
        """)
        let settings = try SettingsStore.load(from: url)
        XCTAssertEqual(settings.backupRoot, "/Volumes/Backup", "Other settings are kept")
        XCTAssertEqual(settings.folderName, IngestSettings().folderName)
        XCTAssertEqual(settings.nextImportNumber, 1)
        XCTAssertEqual(settings.renamePattern, IngestSettings().renamePattern, "The old default moves to the new one")
        XCTAssertNoThrow(try settings.cardFolderName())

        // Saving drops the old keys.
        try SettingsStore.save(settings, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("jobName"))
        XCTAssertFalse(text.contains("folderPattern"))
        XCTAssertTrue(text.contains("nextImportNumber"))
    }

    func testCustomRenamePatternIsKept() throws {
        let url = try writePlist("Custom.plist", "<key>renamePattern</key><string>{filename}-{iseq}</string>")
        XCTAssertEqual(try SettingsStore.load(from: url).renamePattern, "{filename}-{iseq}")
    }

    func testImportNumberIsAtLeastOne() throws {
        let url = try writePlist("Zero.plist", "<key>nextImportNumber</key><integer>0</integer>")
        XCTAssertEqual(try SettingsStore.load(from: url).nextImportNumber, 1)
    }

    func testBrokenFileGivesReadableError() throws {
        let url = tempDir.appendingPathComponent("Broken.plist")
        try "not a plist".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SettingsStore.load(from: url)) { error in
            guard case SettingsError.unreadable = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testBackupRootEmptyMeansNoBackup() {
        XCTAssertNil(IngestSettings().backupRootURL)
        var settings = IngestSettings()
        settings.backupRoot = "  "
        XCTAssertNil(settings.backupRootURL)
        settings.backupRoot = "/Volumes/Backup"
        XCTAssertEqual(settings.backupRootURL?.path, "/Volumes/Backup")
    }

    func testBackupMustBeSeparateFromDestination() {
        var settings = IngestSettings()
        settings.destinationRoot = "/Volumes/Work/Photos"
        XCTAssertNil(settings.folderProblem, "No backup is fine")
        settings.backupRoot = "/Volumes/Backup/Photos"
        XCTAssertNil(settings.folderProblem)
        settings.backupRoot = "/Volumes/Work/Photos2"
        XCTAssertNil(settings.folderProblem, "A similar name isn't the same folder")
        settings.backupRoot = "/Volumes/Work/Photos/"
        XCTAssertNotNil(settings.folderProblem)
        settings.backupRoot = "/Volumes/Work/Photos/Backup"
        XCTAssertNotNil(settings.folderProblem)
        settings.backupRoot = "/Volumes/Work"
        XCTAssertNotNil(settings.folderProblem)
        settings.destinationRoot = "~/Pictures"
        settings.backupRoot = NSHomeDirectory() + "/Pictures"
        XCTAssertNotNil(settings.folderProblem, "~ means the home folder")
    }

    func testFileTypesMatchIgnoringCase() {
        let types = FileTypes()
        XCTAssertTrue(types.includes("IMG_0001.CR3"))
        XCTAssertTrue(types.includes("DSC_0001.nef"))
        XCTAssertTrue(types.includes("C0001.MP4"))
        XCTAssertTrue(types.includes("IMG_0001.xmp"))
        XCTAssertFalse(types.includes(".DS_Store"))
        XCTAssertFalse(types.includes("NOEXTENSION"))
        XCTAssertFalse(types.includes("readme.txt"))
    }
}
