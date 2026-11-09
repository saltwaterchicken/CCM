import XCTest
@testable import MediaSherpaCore

final class HelpTests: XCTestCase {
    private func top(_ query: String) -> String? { Help.search(query).first?.id }

    func testTheWordsPhotographersTypeFindTheirAnswer() {
        XCTAssertEqual(top("trash"), "trash")
        XCTAssertEqual(top("deleted photos"), "trash")
        XCTAssertEqual(top("stars not in Lightroom"), "lightroom")
        XCTAssertEqual(top("server red"), "server-light")
        XCTAssertEqual(top("blue stars"), "blue-stars")
        XCTAssertEqual(top("calib"), "calibrate", "Half a word is enough")
        XCTAssertEqual(top("import number"), "number")
        XCTAssertEqual(top("whatsapp"), "support")
    }

    func testCardTypesFindTheirAnswer() {
        XCTAssertEqual(top("cfexpress"), "card-readers")
        XCTAssertEqual(top("xqd reader"), "card-readers")
        XCTAssertEqual(top("orange copy only"), "card-readers")
        XCTAssertTrue(Help.search("copy only").map(\.id).contains("card-readers"))
        XCTAssertEqual(top("trash"), "trash", "The new answers don't push out the main one")
        XCTAssertEqual(top("blackmagic"), "use-as-card")
        XCTAssertEqual(top("mxf"), "mxf")
        XCTAssertEqual(top("no sound in clip"), "mxf")
        XCTAssertEqual(top("red card"), "use-as-card")
        XCTAssertEqual(top("use as card"), "use-as-card")
        XCTAssertEqual(top("r3d preview"), "red-preview")
        XCTAssertEqual(top("copy automatically when card goes in"), "auto-start")
        XCTAssertEqual(top("red clips thumbnail"), "red-preview")
    }

    func testTheSettingsFileListHasEverySetting() throws {
        func keys(_ value: Any) -> [String] {
            guard let dictionary = value as? [String: Any] else { return [] }
            return dictionary.flatMap { [$0.key] + keys($0.value) }
        }
        let data = try PropertyListEncoder().encode(IngestSettings())
        let found = keys(try PropertyListSerialization.propertyList(from: data, format: nil))
        XCTAssertGreaterThan(found.count, 30)
        let list = try XCTUnwrap(Help.answers.first { $0.id == "settings-file-list" }).answer
        let words = Set(list.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        for key in found { XCTAssertTrue(words.contains(key), "Add \(key) to the list here and in NOTES.md's ReadMe section") }
        XCTAssertEqual(top("settings file list"), "settings-file-list")
        XCTAssertEqual(top("what can I edit in the plist"), "settings-file-list")
    }

    func testNothingTypedListsEverythingAndNonsenseFindsNothing() {
        XCTAssertEqual(Help.search("").count, Help.answers.count)
        XCTAssertEqual(Help.search("how do I").count, Help.answers.count, "Only small words")
        XCTAssertEqual(Help.search("zzqx"), [])
    }

    func testWordsShareAStemAndSynonyms() {
        XCTAssertEqual(Help.words("Trashed deleted erase"), ["trash", "trash", "trash"])
        XCTAssertEqual(Help.words("Stars rating NAS Synology"), ["star", "star", "server", "server"])
    }

    func testMenuCommandsAreFoundByTheWordsInThem() {
        let commands = [MenuCommand(id: 0, menu: "File", title: "Copy NIKON D850", shortcut: "⌘↩"),
                        MenuCommand(id: 1, menu: "File", title: "Load Folder…"),
                        MenuCommand(id: 2, menu: "Photos", title: "Sync With Server", enabled: false),
                        MenuCommand(id: 3, menu: "Photos", title: "Check 12 Unrated Photos"),
                        MenuCommand(id: 4, menu: "Help", title: "Setup Tutorial…")]
        XCTAssertEqual(Help.search("sync", in: commands).map(\.id), [2])
        XCTAssertEqual(Help.search("synology", in: commands).map(\.id), [2], "Synonyms count")
        XCTAssertEqual(Help.search("copy", in: commands).map(\.id), [0])
        XCTAssertEqual(Help.search("tut", in: commands).map(\.id), [4], "Half a word is enough")
        XCTAssertEqual(Help.search("photos", in: commands).map(\.id), [3, 2], "Name matches before menu matches")
        XCTAssertEqual(Help.search("load server", in: commands), [], "Every word must be found")
        XCTAssertEqual(Help.search("", in: commands), [])
    }

    func testShortcutsReadAsInTheMenu() {
        XCTAssertEqual(Help.shortcut(key: "\r", command: true), "⌘↩")
        XCTAssertEqual(Help.shortcut(key: "o", command: true), "⌘O")
        XCTAssertEqual(Help.shortcut(key: "?", shift: true, command: true), "⇧⌘?")
        XCTAssertEqual(Help.shortcut(key: ""), "")
    }

    func testEveryAnswerHasItsOwnID() {
        XCTAssertEqual(Set(Help.answers.map(\.id)).count, Help.answers.count)
    }
}

final class SupportTests: XCTestCase {
    private func report(card: String, number: Int?, folder: URL, files: Int) -> CopyReport {
        let copied = (0..<files).map { i in
            CopiedFile(newName: "2026-10-27-ES_000\(i).NEF", originalPath: "DCIM/100NIKON/DSC_000\(i).NEF", size: 1_000_000,
                       originalModified: nil, checksum: "abc", destinations: [folder.appendingPathComponent("x")], alreadyThere: false)
        }
        return CopyReport(cardName: card, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          finishedAt: Date(timeIntervalSince1970: 1_800_000_100), destinationFolders: [folder],
                          importNumber: number, files: copied, receipts: [])
    }

    func testTheLatestReceiptAndItsSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appendingPathComponent("2026-10-26-ES006"), newer = root.appendingPathComponent("2026-10-27-ES007")
        for folder in [older, newer] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let first = try Receipt.write(report(card: "OLD, CARD", number: 6, folder: older, files: 1), in: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: first.path)
        let second = try Receipt.write(report(card: "EOS_DIGITAL", number: 7, folder: newer, files: 3), in: newer)

        XCTAssertEqual(Support.latestReceipt(under: root)?.lastPathComponent, second.lastPathComponent)
        let summary = try XCTUnwrap(Support.summary(ofReceipt: second))
        XCTAssertEqual(summary.card, "EOS_DIGITAL")
        XCTAssertEqual(summary.files, 3)
        XCTAssertEqual(summary.totalBytes, 3_000_000)
        XCTAssertEqual(summary.importNumber, 7)
        XCTAssertEqual(summary.copies, newer.path)
        XCTAssertTrue(summary.lines.contains("Import number: 007"))
        XCTAssertEqual(Support.summary(ofReceipt: first)?.card, "OLD, CARD", "A quoted value")
        XCTAssertNil(Support.latestReceipt(under: root.appendingPathComponent("none")))
    }

    func testTheMessageKeepsThePhotographersWordsFirst() {
        let text = Support.message(problem: "  The light is red  ", details: ["Media Sherpa 1.0"], receipt: nil)
        XCTAssertEqual(text, "The light is red\n\n— From Media Sherpa —\nMedia Sherpa 1.0")
    }

    func testTheWhatsAppLinkCarriesTheWholeMessage() {
        XCTAssertEqual(Support.whatsAppURL(number: "+1 (555) 123-4567", text: "a+b & c\nd?")?.absoluteString,
                       "https://wa.me/15551234567?text=a%2Bb%20%26%20c%0Ad%3F")
        XCTAssertNil(Support.whatsAppURL(number: "", text: "hi"), "No number set")
        XCTAssertNil(Support.whatsAppURL(number: "555-1234", text: "hi"), "Needs the country code")
    }

    func testTheBuiltInNumberUnlessTheSettingsFileHasOne() {
        XCTAssertEqual(Support.number(setting: "", built: "+1 555 123 4567"), "+1 555 123 4567")
        XCTAssertEqual(Support.number(setting: "+44 20 7946 0000", built: "+1 555 123 4567"), "+44 20 7946 0000")
        XCTAssertEqual(Support.number(setting: "", built: nil), "")
    }
}
