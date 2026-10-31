import XCTest
@testable import CardIngestCore

final class PhoneNotificationsTests: XCTestCase {
    func testOffWithoutATopic() {
        XCTAssertFalse(NotificationSettings().isOn)
        XCTAssertFalse(NotificationSettings(topic: "   ").isOn)
        XCTAssertNil(PhoneNotifier(NotificationSettings()).request(for: .test))
    }

    func testServerAddress() {
        XCTAssertEqual(NotificationSettings(topic: "t").serverURL?.absoluteString, "https://ntfy.sh")
        XCTAssertEqual(NotificationSettings(server: "ntfy.example.com", topic: "t").serverURL?.absoluteString,
                       "https://ntfy.example.com", "https:// is added when left out")
        XCTAssertNil(NotificationSettings(server: "ftp://ntfy.sh", topic: "t").serverURL)
        XCTAssertNil(NotificationSettings(server: "", topic: "t").serverURL)
    }

    func testRequestIsJSONToTheServer() throws {
        let notifier = PhoneNotifier(NotificationSettings(topic: " ccm-test-topic "))
        let request = try XCTUnwrap(notifier.request(for: PhoneNotification(title: "Card copied: Été", message: "ok")))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["topic"] as? String, "ccm-test-topic")
        XCTAssertEqual(body["title"] as? String, "Card copied: Été", "Accents survive in JSON")
        XCTAssertEqual(body["message"] as? String, "ok")
        XCTAssertNil(body["priority"])
    }

    func testProblemsAreLouder() throws {
        let notifier = PhoneNotifier(NotificationSettings(topic: "t"))
        let request = try XCTUnwrap(notifier.request(for: .copyFailed(cardName: "EOS_DIGITAL", reason: "Card removed")))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["priority"] as? Int, 4)
        XCTAssertEqual(body["tags"] as? [String], ["warning"])
    }

    func testSettingsFileKeys() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>notifications</key><dict><key>topic</key><string>ccm-abc</string></dict>
        </dict></plist>
        """
        let settings = try PropertyListDecoder().decode(IngestSettings.self, from: Data(plist.utf8))
        XCTAssertEqual(settings.notifications, NotificationSettings(server: "https://ntfy.sh", topic: "ccm-abc"))
        XCTAssertEqual(IngestSettings().notifications.topic, "", "Off by default")
    }

    func testMessages() {
        let copied = PhoneNotification.cardCopied(folder: "2026-10-28-ES012", cardName: "EOS_DIGITAL", files: 412,
                                                  bytes: 12_000_000_000, alreadyImported: 3)
        XCTAssertEqual(copied.title, "Card copied: 2026-10-28-ES012")
        XCTAssertTrue(copied.message.hasPrefix("412 files ("))
        XCTAssertTrue(copied.message.contains("3 files already imported, skipped."))
        XCTAssertFalse(copied.isProblem)

        XCTAssertEqual(PhoneNotification.backupDone(folder: "F", sent: 1, alreadyThere: 0, queued: 1, problems: 0, wentAway: false).message,
                       "All 1 file on the server and checked.")
        XCTAssertTrue(PhoneNotification.backupDone(folder: "F", sent: 5, alreadyThere: 0, queued: 9, problems: 4, wentAway: true).isProblem)

        let sync = PhoneNotification.syncDone([.init(name: "A", added: 10, problems: 0), .init(name: "B", added: 0, problems: 0)])
        XCTAssertEqual(sync.title, "Sync done: 10 files added")
        XCTAssertEqual(sync.message, "A: 10 added\nB: already had everything")
        let bad = PhoneNotification.syncDone([.init(name: "A", added: 2, problems: 1)])
        XCTAssertEqual(bad.title, "Sync done, 1 file needs the admin")
        XCTAssertTrue(bad.isProblem)
    }

    func testNewTopicIsLongAndRandom() {
        let topic = NotificationSettings.newTopic()
        XCTAssertTrue(topic.hasPrefix("ccm-"))
        XCTAssertEqual(topic.count, 28)
        XCTAssertNotEqual(topic, NotificationSettings.newTopic())
        XCTAssertTrue(NotificationSettings(topic: topic).isOn)
    }
}
