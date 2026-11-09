import XCTest
@testable import MediaSherpaCore

/// The photographer's own keywords, in a text file of their own.
final class KeywordHistoryTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("My Keywords.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testSavedOnePerLineAndReadBack() throws {
        XCTAssertEqual(KeywordHistory.load(from: url), [], "No file yet")
        try KeywordHistory.save(["Steve", "Jurassic Park"], to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Steve\nJurassic Park\n")
        XCTAssertEqual(KeywordHistory.load(from: url), ["Steve", "Jurassic Park"])
    }

    func testEditedByHand() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "  Lake \n\nlake\nCanoe\r\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(KeywordHistory.load(from: url), ["Lake", "Canoe"], "Blank lines, spaces and repeats dropped")
    }

    func testNewestFirstAndKeptToTheLimit() {
        XCTAssertEqual(KeywordHistory.used(["lake", "Sunset"], in: ["Canoe", "Lake"]), ["lake", "Sunset", "Canoe"])
        let many = (0..<600).map { "k\($0)" }
        XCTAssertEqual(KeywordHistory.used(["new"], in: many).count, KeywordHistory.limit)
    }

    func testMovedInOnceFromTheOldLists() throws {
        XCTAssertEqual(KeywordHistory.moveIn([[], []], to: url), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Nothing to move: no file")
        XCTAssertEqual(KeywordHistory.moveIn([["Steve", "house"], ["House", "Lake"]], to: url), ["Steve", "house", "Lake"])
        XCTAssertEqual(KeywordHistory.moveIn([["Other"]], to: url), ["Steve", "house", "Lake"], "An existing file is left alone")
    }
}
