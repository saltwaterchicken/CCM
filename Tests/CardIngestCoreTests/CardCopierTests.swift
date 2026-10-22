import XCTest
@testable import CardIngestCore

final class CardCopierTests: XCTestCase {
    private var base: URL!
    private var card: URL { base.appendingPathComponent("CARD", isDirectory: true) }
    private var main: URL { base.appendingPathComponent("Main/2026/2026-10-22_Test", isDirectory: true) }
    private var backup: URL { base.appendingPathComponent("Backup/2026-10-22_Test", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("CopierTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100TEST"), withIntermediateDirectories: true)
        try put("DCIM/100TEST/IMG_0001.CR3", Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try put("DCIM/100TEST/IMG_0001.JPG", Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
        try put("DCIM/100TEST/EMPTY.THM", Data())
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: card.appendingPathComponent("DCIM/100TEST/IMG_0001.CR3").path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func put(_ path: String, _ data: Data) throws {
        try data.write(to: card.appendingPathComponent(path))
    }

    private func scan() throws -> [CardFile] {
        try CardScanner.scan(cardRoot: card, fileTypes: FileTypes())
    }

    /// Every file on the card with its checksum, to prove the card wasn't touched.
    private func snapshotOfCard() throws -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        let enumerator = fm.enumerator(at: card, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            result[url.path] = XXHash64.hash(try Data(contentsOf: url))
        }
        return result
    }

    private func leftoverPartials(in folder: URL) -> [String] {
        guard let e = fm.enumerator(atPath: folder.path) else { return [] }
        return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".partial") }
    }

    func testCopiesVerifiesAndWritesReceipts() throws {
        let before = try snapshotOfCard()
        let files = try scan()
        let report = try CardCopier.copy(cardRoot: card, cardName: "NO NAME", files: files, to: [main, backup])

        XCTAssertEqual(report.files.count, 3)
        for file in report.files {
            let original = try Data(contentsOf: card.appendingPathComponent(file.relativePath))
            XCTAssertEqual(file.checksum, XXHash64.hex(XXHash64.hash(original)))
            XCTAssertFalse(file.alreadyThere)
            for folder in [main, backup] {
                let copy = try Data(contentsOf: folder.appendingPathComponent(file.relativePath))
                XCTAssertEqual(copy, original, "\(file.relativePath) in \(folder.path)")
            }
        }

        // Capture time on disk is kept.
        let copied = try fm.attributesOfItem(atPath: main.appendingPathComponent("DCIM/100TEST/IMG_0001.CR3").path)
        XCTAssertEqual((copied[.modificationDate] as? Date)?.timeIntervalSince1970, 1_700_000_000)

        // One receipt per destination, listing every file.
        XCTAssertEqual(report.receipts.count, 2)
        let receipt = try String(contentsOf: report.receipts[0], encoding: .utf8)
        XCTAssertTrue(receipt.hasPrefix("File,Size (bytes),xxHash64,Verified"))
        for file in report.files {
            XCTAssertTrue(receipt.contains("\(file.relativePath),\(file.size),\(file.checksum),yes"))
        }
        XCTAssertTrue(report.receipts[0].lastPathComponent.hasPrefix("Receipt_NO NAME_"))

        XCTAssertEqual(try snapshotOfCard(), before, "The card must not change")
        XCTAssertEqual(leftoverPartials(in: base), [])
    }

    func testRunningAgainFindsFilesAlreadyThere() throws {
        let files = try scan()
        _ = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: files, to: [main])
        let again = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: files, to: [main])
        XCTAssertTrue(again.files.allSatisfy(\.alreadyThere))
    }

    func testFinishesAnInterruptedCopyToTheBackup() throws {
        let files = try scan()
        _ = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: files, to: [main])
        // The backup run was cut short: one file made it, one was half written.
        let jpg = "DCIM/100TEST/IMG_0001.JPG"
        let done = backup.appendingPathComponent(jpg)
        try fm.createDirectory(at: done.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: main.appendingPathComponent(jpg), to: done)
        let stale = backup.appendingPathComponent("DCIM/100TEST/.IMG_0001.CR3.partial")
        try Data("half a file".utf8).write(to: stale)

        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: files, to: [main, backup])

        let byPath = Dictionary(uniqueKeysWithValues: report.files.map { ($0.relativePath, $0) })
        XCTAssertEqual(byPath[jpg]?.alreadyThere, true)
        XCTAssertEqual(byPath["DCIM/100TEST/IMG_0001.CR3"]?.alreadyThere, false)
        for file in report.files {
            let original = try Data(contentsOf: card.appendingPathComponent(file.relativePath))
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(file.relativePath)), original,
                           file.relativePath)
        }
        XCTAssertEqual(leftoverPartials(in: base), [])
    }

    func testDifferentFileAtDestinationIsNeverOverwritten() throws {
        let clash = main.appendingPathComponent("DCIM/100TEST/IMG_0001.JPG")
        try fm.createDirectory(at: clash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("someone else's photo".utf8).write(to: clash)

        XCTAssertThrowsError(try CardCopier.copy(cardRoot: card, cardName: "CARD", files: try scan(), to: [main])) { error in
            guard case CopyError.differentFileAlreadyThere = error else { return XCTFail("Got \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: clash, encoding: .utf8), "someone else's photo")
        XCTAssertEqual(leftoverPartials(in: base), [])
    }

    func testMissingFileOnCardStopsTheJob() throws {
        var files = try scan()
        files.append(CardFile(relativePath: "DCIM/100TEST/GONE.CR3", size: 10))
        XCTAssertThrowsError(try CardCopier.copy(cardRoot: card, cardName: "CARD", files: files, to: [main])) { error in
            guard case CopyError.readFailed = error else { return XCTFail("Got \(error)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: main.appendingPathComponent("DCIM/100TEST/GONE.CR3").path))
        XCTAssertEqual(leftoverPartials(in: base), [])
        let receipts = try fm.contentsOfDirectory(atPath: main.path).filter { $0.hasPrefix("Receipt_") }
        XCTAssertEqual(receipts, [], "No receipt for a failed job")
    }

    func testNotEnoughSpaceIsCheckedFirst() throws {
        let huge = [CardFile(relativePath: "DCIM/100TEST/IMG_0001.CR3", size: Int64.max / 4)]
        XCTAssertThrowsError(try CardCopier.copy(cardRoot: card, cardName: "CARD", files: huge, to: [main])) { error in
            guard case CopyError.notEnoughSpace = error else { return XCTFail("Got \(error)") }
        }
    }

    func testCancelStopsAndCleansUp() throws {
        XCTAssertThrowsError(try CardCopier.copy(cardRoot: card, cardName: "CARD", files: try scan(), to: [main],
                                                 isCancelled: { true })) { error in
            XCTAssertEqual(error as? CopyError, .cancelled)
        }
        XCTAssertEqual(leftoverPartials(in: base), [])
    }

    func testProgressReachesTheEnd() throws {
        final class Box: @unchecked Sendable { var last: (Int64, Int64) = (0, 0) }
        let box = Box()
        _ = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: try scan(), to: [main, backup],
                                progress: { done, total in box.last = (done, total) })
        XCTAssertGreaterThan(box.last.1, 0)
        XCTAssertEqual(box.last.0, box.last.1)
    }

    func testCSVEscaping() {
        XCTAssertEqual(Receipt.csv("plain"), "plain")
        XCTAssertEqual(Receipt.csv("a,b"), "\"a,b\"")
        XCTAssertEqual(Receipt.csv("say \"hi\""), "\"say \"\"hi\"\"\"")
    }
}
