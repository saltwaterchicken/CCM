import XCTest
@testable import MediaSherpaCore

final class GameStatusTests: XCTestCase {
    func testNothingCopyingIsIdle() {
        let status = GameStatus.status([])
        XCTAssertEqual(status.active, 0)
        XCTAssertEqual(status.stage, "IDLE")
        XCTAssertEqual(status.title, "Card Progress")
    }

    func testSpeedAndTimeLeftComeFromTheCardsBytes() {
        let start = Date(timeIntervalSince1970: 1_000)
        // A quarter of 4 GB in 60 seconds: about 133 Mb/s, three minutes to go.
        let card = CopyProgress(cardName: "EOS_DIGITAL", stage: .copying, started: start, fraction: 0.25,
                                bytes: 4_000_000_000, filesDone: 100, filesTotal: 400, lastFile: "2026-07-01-ES_1234.CR3")
        let status = GameStatus.status([card], now: start.addingTimeInterval(60))
        XCTAssertEqual(status.active, 300, "files still to copy")
        XCTAssertEqual(status.file, "2026-07-01-ES_1234.CR3")
        XCTAssertEqual(status.stage, "COPY + VERIFY")
        XCTAssertEqual(status.speed, "133 Mb/s")
        XCTAssertEqual(status.eta, "ABOUT 3 MIN LEFT")
        XCTAssertEqual(status.filePct, 0.25)
        XCTAssertEqual(status.totalPct, 0.25)
    }

    func testNoGuessesInTheFirstSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let card = CopyProgress(cardName: "CARD", stage: .copying, started: start, fraction: 0.01, bytes: 1_000_000)
        let status = GameStatus.status([card], now: start.addingTimeInterval(1))
        XCTAssertEqual(status.speed, "")
        XCTAssertEqual(status.eta, "")
    }

    func testReadingTheCardCountsAsBusy() {
        // Before the files are counted the window still has to open.
        XCTAssertEqual(GameStatus.status([CopyProgress(cardName: "A", stage: .preparing)]).active, 1)
    }

    func testTheCopyingCardIsShownAndTotalCoversEveryBusyCard() {
        let cards = [CopyProgress(cardName: "A", stage: .preparing),
                     CopyProgress(cardName: "B", stage: .copying, fraction: 0.5),
                     CopyProgress(cardName: "C", stage: .done)]
        let status = GameStatus.status(cards)
        XCTAssertEqual(status.file, "B")
        XCTAssertEqual(status.totalPct, 0.25)
        XCTAssertEqual(status.finished, 0, "only counted once nothing is busy")
    }

    func testFinishedCardsAreCountedWhenAllAreDone() {
        let status = GameStatus.status([CopyProgress(cardName: "A", stage: .done, fraction: 1),
                                        CopyProgress(cardName: "B", stage: .done, fraction: 1)])
        XCTAssertEqual(status.active, 0)
        XCTAssertEqual(status.finished, 2)
        XCTAssertEqual(status.filePct, 1)
    }

    func testAFailureSaysWhy() {
        let status = GameStatus.status([CopyProgress(cardName: "A", stage: .failed, problem: "The card was removed")])
        XCTAssertEqual(status.stage, "FAILED")
        XCTAssertEqual(status.reason, "The card was removed")
    }

    func testTimeLeftWording() {
        XCTAssertEqual(GameStatus.timeLeft(30), "UNDER A MINUTE LEFT")
        XCTAssertEqual(GameStatus.timeLeft(61), "ABOUT 2 MIN LEFT")
        XCTAssertEqual(GameStatus.timeLeft(3 * 3600), "ABOUT 3 HOURS LEFT")
    }

    func testJSONHasTheFieldsTheGameReads() throws {
        let json = GameStatus.json([CopyProgress(cardName: "A", stage: .copying, fraction: 0.5)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for key in ["title", "active", "finished", "file", "stage", "filePct", "totalPct", "speed", "eta", "reason"] {
            XCTAssertNotNil(object[key], key)
        }
    }

    // MARK: Postcards

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAPostcardIsSavedAndNeverOverwrites() throws {
        let dir = try folder()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        let name = "Azimovs Rebellion - Ember Mesa - 2026-07-01 14.05.jpg"
        let first = try Postcard.save(dataURL: dataURL, fileName: name, in: dir)
        XCTAssertEqual(first.lastPathComponent, name)
        XCTAssertEqual(try Data(contentsOf: first), jpeg)
        let second = try Postcard.save(dataURL: dataURL, fileName: name, in: dir)
        XCTAssertEqual(second.lastPathComponent, "Azimovs Rebellion - Ember Mesa - 2026-07-01 14.05 2.jpg")
    }

    func testAPostcardStaysInTheCardFolder() throws {
        let dir = try folder()
        let dataURL = "data:image/jpeg;base64," + Data([1, 2, 3]).base64EncodedString()
        let url = try Postcard.save(dataURL: dataURL, fileName: "../../.evil:name", in: dir)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
        XCTAssertEqual(url.pathExtension, "jpg")
    }

    func testSomethingThatIsntAPictureIsRefused() throws {
        let dir = try folder()
        XCTAssertThrowsError(try Postcard.save(dataURL: "hello", fileName: "x.jpg", in: dir))
        XCTAssertThrowsError(try Postcard.save(dataURL: "data:text/plain;base64,aGk=", fileName: "x.jpg", in: dir))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
