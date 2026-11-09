import XCTest
@testable import CardIngestCore

final class PreferencesMoveTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var oldID = ""
    private var newID = ""

    override func setUp() {
        let id = UUID().uuidString
        oldID = "test.cardingest.old.\(id)"
        newID = "test.cardingest.new.\(id)"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: oldID)
        defaults.removePersistentDomain(forName: newID)
        // macOS leaves an empty file behind for each; don't let them pile up.
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
        for id in [oldID, newID] {
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(id).plist"))
        }
    }

    func testTheLicenseKeyAndTutorialComeAcross() {
        defaults.setPersistentDomain(["licenseKey": "CI1-abc", "setupTutorialSeen": true], forName: oldID)

        XCTAssertTrue(PreferencesMove.moveOld(to: newID, from: [oldID], defaults: defaults))
        let moved = defaults.persistentDomain(forName: newID)
        XCTAssertEqual(moved?["licenseKey"] as? String, "CI1-abc")
        XCTAssertEqual(moved?["setupTutorialSeen"] as? Bool, true)
        XCTAssertTrue(defaults.persistentDomain(forName: oldID)?.isEmpty ?? true)
    }

    func testPreferencesAlreadyUnderTheNewIDAreKept() {
        defaults.setPersistentDomain(["licenseKey": "CI1-old"], forName: oldID)
        defaults.setPersistentDomain(["licenseKey": "CI1-new"], forName: newID)

        XCTAssertFalse(PreferencesMove.moveOld(to: newID, from: [oldID], defaults: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: newID)?["licenseKey"] as? String, "CI1-new")
    }

    func testNothingToMove() {
        XCTAssertFalse(PreferencesMove.moveOld(to: newID, from: [oldID], defaults: defaults))
        XCTAssertTrue(defaults.persistentDomain(forName: newID)?.isEmpty ?? true)
    }
}
