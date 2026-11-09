import XCTest
@testable import MediaSherpaCore

final class BackupVolumeTests: XCTestCase {
    func testNoBackupFolder() {
        XCTAssertEqual(BackupVolume.check(nil), .notSet)
    }

    func testAShareThatIsntMounted() {
        let folder = URL(fileURLWithPath: "/Volumes/NoSuchShare-\(UUID().uuidString)/Photos/2026", isDirectory: true)
        XCTAssertEqual(BackupVolume.check(folder), .missing)
    }

    func testAFolderOnThisMacsOwnDriveIsntTheServer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-\(UUID().uuidString)/Not yet made")
        guard case .localDrive = BackupVolume.check(folder) else {
            return XCTFail("Expected a local drive, got \(BackupVolume.check(folder))")
        }
    }

    func testTheMacsOwnDriveThroughVolumesIsALocalDriveNotAStandIn() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let viaVolumes = URL(fileURLWithPath: "/Volumes/Macintosh HD" + home, isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: viaVolumes.path), "No Macintosh HD shortcut here")
        guard case .localDrive = BackupVolume.check(viaVolumes) else {
            return XCTFail("Expected a local drive, got \(BackupVolume.check(viaVolumes))")
        }
    }
}
