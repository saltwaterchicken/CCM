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
        settings.jobName = "Smith Wedding"
        settings.backupRoot = "/Volumes/Backup/Photos"
        settings.metadata.keywords = ["wedding", "Portland"]
        settings.rating.sharpnessThreshold = 42
        try SettingsStore.save(settings, to: url)
        XCTAssertEqual(try SettingsStore.load(from: url), settings)
    }

    func testPartialProjectFileFallsBackToDefaults() throws {
        let url = tempDir.appendingPathComponent("Project.plist")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>jobName</key><string>Camp Week 2</string>
            <key>folderPattern</key><string>{job}/{date:YYYY-MM-DD}</string>
            <key>rating</key><dict><key>enabled</key><false/></dict>
        </dict>
        </plist>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let settings = try SettingsStore.load(from: url)
        XCTAssertEqual(settings.jobName, "Camp Week 2")
        XCTAssertEqual(settings.folderPattern, "{job}/{date:YYYY-MM-DD}")
        XCTAssertFalse(settings.rating.enabled)
        XCTAssertEqual(settings.rating.sharpnessThreshold, RatingSettings().sharpnessThreshold)
        XCTAssertEqual(settings.renamePattern, IngestSettings().renamePattern)
        XCTAssertEqual(settings.fileTypes, FileTypes())
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
