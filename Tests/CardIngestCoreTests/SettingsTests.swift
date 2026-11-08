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

    func testTheOldCardIngestFolderIsRenamedMediaSherpa() throws {
        let fm = FileManager.default
        let old = tempDir.appendingPathComponent("Card Ingest", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: old.appendingPathComponent("Settings.plist"))

        let folder = SettingsStore.moveOldFolder(in: tempDir)
        XCTAssertEqual(folder.lastPathComponent, "Media Sherpa")
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Settings.plist")), Data("mine".utf8))
    }

    func testAMediaSherpaFolderIsKeptOverAnOldOne() throws {
        let fm = FileManager.default
        let old = tempDir.appendingPathComponent("Card Ingest", isDirectory: true)
        let new = tempDir.appendingPathComponent("Media Sherpa", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent("Settings.plist"))

        XCTAssertEqual(SettingsStore.moveOldFolder(in: tempDir), new)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("Settings.plist")), Data("new".utf8))
    }

    func testNoFolderYetMovesNothing() {
        let folder = SettingsStore.moveOldFolder(in: tempDir)
        XCTAssertEqual(folder.lastPathComponent, "Media Sherpa")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testLoadOrCreateWritesDefaultsWhenMissing() throws {
        let url = tempDir.appendingPathComponent("Nested/Settings.plist")
        let settings = try SettingsStore.loadOrCreate(at: url)
        XCTAssertEqual(settings, IngestSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<?xml"), "Settings should be saved as readable XML")
    }

    private func shippedFile(_ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("Shipped.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <!-- A comment, as the real one has. -->
        \(body)
        </dict></plist>
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testANewUserGetsWhatTheShippedFileSays() throws {
        let url = tempDir.appendingPathComponent("Settings.plist")
        let shipped = try shippedFile("""
        <key>autoStartOnInsert</key><true/>
        <key>metadata</key><dict><key>keywords</key><array><string>Summer Camp</string></array></dict>
        <key>tutorialKeywords</key><array><string>Lake</string></array>
        """)
        let settings = try SettingsStore.loadOrCreate(at: url, shipped: shipped)
        var expected = IngestSettings()
        expected.autoStartOnInsert = true
        expected.metadata.keywords = ["Summer Camp"]
        expected.tutorialKeywords = ["Lake"]
        XCTAssertEqual(settings, expected)
        XCTAssertEqual(try SettingsStore.load(from: url), expected, "Saved as their own file")
    }

    func testAShippedTopicNeverReachesANewUser() throws {
        let url = tempDir.appendingPathComponent("Settings.plist")
        let shipped = try shippedFile("<key>notifications</key><dict><key>topic</key><string>ccm-private</string><key>server</key><string>https://example.com</string></dict>")
        let settings = try SettingsStore.loadOrCreate(at: url, shipped: shipped)
        XCTAssertEqual(settings.notifications.topic, "")
        XCTAssertEqual(settings.notifications.server, "https://example.com", "Only the topic is left out")
        XCTAssertEqual(try SettingsStore.load(from: url).notifications.topic, "")
    }

    func testAnExistingUserKeepsTheirSettingsAndTopic() throws {
        let url = tempDir.appendingPathComponent("Settings.plist")
        var mine = IngestSettings()
        mine.notifications.topic = "ccm-mine"
        mine.nextImportNumber = 24
        try SettingsStore.save(mine, to: url)
        XCTAssertEqual(try SettingsStore.loadOrCreate(at: url, shipped: try shippedFile("<key>nextImportNumber</key><integer>1</integer>")), mine)
    }

    func testAShippedFileThatWontLoadGivesTheDefaults() throws {
        let url = tempDir.appendingPathComponent("Settings.plist")
        let bad = try shippedFile("<key>metadata</key><string>wrong kind</string>")
        XCTAssertEqual(try SettingsStore.loadOrCreate(at: url, shipped: bad), IngestSettings())
    }

    func testBadShippedFilesAreCaughtWhenBuilding() throws {
        XCTAssertNil(SettingsStore.shippingProblem(try shippedFile("<key>openWith</key><string>Adobe Bridge 2023</string>")))
        let topic = try shippedFile("<key>notifications</key><dict><key>topic</key><string>ccm-private</string></dict>")
        XCTAssertTrue(try XCTUnwrap(SettingsStore.shippingProblem(topic)).contains("topic"))
        let typo = try shippedFile("<key>metadata</key><dict><key>keyword</key><array/></dict>")
        XCTAssertTrue(try XCTUnwrap(SettingsStore.shippingProblem(typo)).contains("metadata › keyword"))
        XCTAssertTrue(try XCTUnwrap(SettingsStore.shippingProblem(try shippedFile("<key>openwith</key><string>x</string>"))).contains("openwith"))
        XCTAssertNotNil(SettingsStore.shippingProblem(try shippedFile("<key>metadata</key><string>wrong kind</string>")))
        XCTAssertNotNil(SettingsStore.shippingProblem(tempDir.appendingPathComponent("none")))
    }

    func testTheProjectsShippedFileIsFineAndListsEverySetting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shipped = root.appendingPathComponent("Ship/Settings.plist")
        XCTAssertNil(SettingsStore.shippingProblem(shipped))
        func keys(_ value: Any, _ prefix: String = "") -> [String] {
            guard let dictionary = value as? [String: Any] else { return [] }
            return dictionary.flatMap { ["\(prefix)\($0.key)"] + keys($0.value, "\(prefix)\($0.key).") }
        }
        let listed = keys(try PropertyListSerialization.propertyList(from: try Data(contentsOf: shipped), format: nil))
        let all = keys(try PropertyListSerialization.propertyList(from: try PropertyListEncoder().encode(IngestSettings()), format: nil))
        XCTAssertEqual(Set(all).subtracting(listed), [], "Add these to Ship/Settings.plist")
    }

    func testTutorialKeywordButtons() {
        XCTAssertEqual(IngestSettings().tutorialKeywordChoices(year: 2027), ["2027", "Summer Camp"])
        var settings = IngestSettings()
        settings.tutorialKeywords = ["Season {year}", " Lake ", "", "lake"]
        XCTAssertEqual(settings.tutorialKeywordChoices(year: 2027), ["Season 2027", "Lake"])
        settings.tutorialKeywords = []
        XCTAssertEqual(settings.tutorialKeywordChoices(year: 2027), [])
        let old = Data(#"<?xml version="1.0"?><plist version="1.0"><dict/></plist>"#.utf8)
        XCTAssertEqual(try PropertyListDecoder().decode(IngestSettings.self, from: old).tutorialKeywords, ["{year}", "Summer Camp"],
                       "A file from before this setting gets the old buttons")
    }

    func testRoundTrip() throws {
        let url = tempDir.appendingPathComponent("Settings.plist")
        var settings = IngestSettings()
        settings.folderName = "{todayyear4}-Smith Wedding-{iseq}"
        settings.nextImportNumber = 42
        settings.backupRoot = "/Volumes/Backup/Photos"
        settings.metadata.keywords = ["wedding", "Portland"]
        settings.rating.minimumSharpnessFaces = 42
        settings.rating.autoRating = true
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
            <key>rating</key><dict><key>enabled</key><true/><key>maximumBlown</key><real>0.9</real></dict>
        """)
        let settings = try SettingsStore.load(from: url)
        XCTAssertEqual(settings.folderName, "{todayyear4}-Camp-{iseq}")
        XCTAssertEqual(settings.nextImportNumber, 1)
        XCTAssertFalse(settings.rating.autoRating, "The old placeholder enabled key doesn't switch it on")
        XCTAssertTrue(settings.rating.available, "Offered unless the file says otherwise")
        XCTAssertEqual(settings.rating.maximumBlown, 0.9)
        XCTAssertEqual(settings.rating.minimumSharpnessFaces, RatingSettings().minimumSharpnessFaces)
        XCTAssertEqual(settings.renamePattern, IngestSettings().renamePattern)
        XCTAssertEqual(settings.fileTypes, FileTypes())
    }

    func testSettingsSavedBeforeREDStillGetIt() throws {
        let older = "{\"raw\":[\"cr3\"],\"photo\":[\"jpg\"],\"video\":[\"mov\"],\"sidecar\":[\"xmp\"]}"
        let types = try JSONDecoder().decode(FileTypes.self, from: Data(older.utf8))
        XCTAssertEqual(types.video, ["mov", "r3d"])
        XCTAssertEqual(types.sidecar, ["xmp", "rmd"])
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

    func testAutoRatingCanBeTurnedOffCompletelyInTheFile() throws {
        let url = try writePlist("Off.plist", """
            <key>rating</key><dict><key>available</key><false/><key>autoRating</key><true/></dict>
        """)
        let settings = try SettingsStore.load(from: url)
        XCTAssertFalse(settings.rating.available)
        XCTAssertFalse(settings.rating.checksOnLanding, "The checkbox left on does nothing")
        XCTAssertTrue(RatingSettings(autoRating: true).checksOnLanding)
    }
}
