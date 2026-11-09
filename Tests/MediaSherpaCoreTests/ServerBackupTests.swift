import XCTest
@testable import MediaSherpaCore

final class ServerBackupTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var local: URL!
    private var server: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ServerBackupTests-\(UUID().uuidString)", isDirectory: true)
        local = base.appendingPathComponent("Local/2026-10-27-ES001", isDirectory: true)
        server = base.appendingPathComponent("Server", isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: server, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try chmod(["-R", "-N", base.path])
        try? fm.removeItem(at: base)
    }

    private func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    /// Like the photographers' accounts on the server: new files and folders
    /// can be made, but nothing can be renamed, deleted or have its details changed.
    private func makeCreateOnly(_ folder: URL) throws {
        try chmod(["+a", "everyone deny delete_child,directory_inherit", folder.path])
        try chmod(["+a", "everyone deny delete,writeattr,writeextattr,file_inherit,directory_inherit", folder.path])
    }

    /// A verified local copy, as the copy's report describes it.
    private func copied(_ name: String, _ data: Data) throws -> CopiedFile {
        let url = local.appendingPathComponent(name)
        try data.write(to: url)
        var hasher = XXHash64()
        hasher.update(data)
        return CopiedFile(newName: name, originalPath: "DCIM/" + name, size: Int64(data.count), originalModified: nil,
                          checksum: XXHash64.hex(hasher.digest()), destinations: [url], alreadyThere: false)
    }

    private func report(_ files: [CopiedFile]) -> CopyReport {
        CopyReport(cardName: "EOS_DIGITAL", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                   finishedAt: Date(timeIntervalSince1970: 1_800_000_100), destinationFolders: [local],
                   importNumber: 1, files: files, receipts: [])
    }

    private var card: URL { server.appendingPathComponent(local.lastPathComponent, isDirectory: true) }

    func testAFileIsWrittenOnceAndChecked() throws {
        let raw = try copied("A_0001.CR3", Data(repeating: 7, count: 300_000))
        XCTAssertEqual(ServerBackup.send(raw.destinations[0], checksum: raw.checksum, to: card), .copied)
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("A_0001.CR3")), try Data(contentsOf: raw.destinations[0]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: card.path), ["A_0001.CR3"], "No temporary file")
        XCTAssertEqual(ServerBackup.send(raw.destinations[0], checksum: raw.checksum, to: card), .alreadyThere)
    }

    func testADifferentFileOnTheServerIsNeverReplaced() throws {
        let raw = try copied("A_0001.CR3", Data(repeating: 7, count: 1000))
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        let theirs = Data("the admin's file".utf8)
        try theirs.write(to: card.appendingPathComponent("A_0001.CR3"))
        XCTAssertEqual(ServerBackup.send(raw.destinations[0], checksum: raw.checksum, to: card), .different)
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("A_0001.CR3")), theirs)
    }

    func testAWholeCardGoesToACreateOnlyServerWithItsReceipt() throws {
        try makeCreateOnly(server)
        let files = [try copied("A_0001.CR3", Data(repeating: 1, count: 200_000)),
                     try copied("A_0001.JPG", Data(repeating: 2, count: 50_000)),
                     try copied("A_0002.MP4", Data(repeating: 3, count: 400_000))]
        let job = ServerBackupJob(folder: card, root: server)
        files.forEach(job.send)
        job.finish(report(files))
        job.wait()
        let status = job.current
        XCTAssertEqual(status.sent, 3)
        XCTAssertEqual(status.problems, [])
        XCTAssertTrue(status.finished)
        XCTAssertNil(status.receiptProblem)
        let names = try fm.contentsOfDirectory(atPath: card.path).sorted()
        XCTAssertEqual(names.filter { !$0.hasPrefix("Receipt_") }, ["A_0001.CR3", "A_0001.JPG", "A_0002.MP4"])
        let receipt = try XCTUnwrap(names.first { $0.hasPrefix("Receipt_") })
        let text = try String(contentsOf: card.appendingPathComponent(receipt), encoding: .utf8)
        XCTAssertTrue(text.contains(files[2].checksum))
        XCTAssertTrue(text.contains(card.path), "The receipt names the server's folder")
        // Nothing on the server could be removed or renamed by this account.
        XCTAssertThrowsError(try fm.removeItem(at: card.appendingPathComponent("A_0001.CR3")))

        // The same card again (an interrupted backup tried once more): nothing is written twice.
        let again = ServerBackupJob(folder: card, root: server)
        files.forEach(again.send)
        again.finish(report(files))
        again.wait()
        XCTAssertEqual(again.current.alreadyThere, 3)
        XCTAssertEqual(again.current.problems, [])
        XCTAssertNil(again.current.receiptProblem)
    }

    func testWhenTheServerGoesAwayTheRestWaitForSync() throws {
        let gone = URL(fileURLWithPath: "/Volumes/NoSuchShare-\(UUID().uuidString)", isDirectory: true)
        let files = [try copied("A_0001.CR3", Data(repeating: 1, count: 1000)),
                     try copied("A_0002.CR3", Data(repeating: 2, count: 1000))]
        let job = ServerBackupJob(folder: gone.appendingPathComponent("2026-10-27-ES001"), root: gone)
        files.forEach(job.send)
        job.finish(report(files))
        job.wait()
        XCTAssertTrue(job.current.wentAway)
        XCTAssertEqual(job.current.sent, 0)
        XCTAssertEqual(job.current.problems.count, 2)
        XCTAssertTrue(job.current.finished)
    }

    func testASidecarGivenStarsSinceGoesAsItIsButAChangedRAWIsReported() throws {
        let sidecar = try copied("A_0001.XMP", Data("<x:xmpmeta/>".utf8))
        try Data("<x:xmpmeta rating=\"3\"/>".utf8).write(to: sidecar.destinations[0])
        XCTAssertEqual(ServerBackup.send(sidecar.destinations[0], checksum: sidecar.checksum, to: card), .copied)
        let raw = try copied("A_0002.CR3", Data(repeating: 1, count: 1000))
        try Data(repeating: 9, count: 1000).write(to: raw.destinations[0])
        guard case .failed = ServerBackup.send(raw.destinations[0], checksum: raw.checksum, to: card) else {
            return XCTFail("A RAW that no longer matches the card must be reported")
        }
    }

    func testACardCopiedLocallyIsBackedUpBesideItAsTheAppDoes() throws {
        // A fake card: a RAW+JPEG pair, a RAW with the camera's sidecar, and a clip.
        let cardRoot = base.appendingPathComponent("CARD", isDirectory: true)
        let files = ["DCIM/100CANON/IMG_0001.CR3": 300_000, "DCIM/100CANON/IMG_0001.JPG": 80_000,
                     "DCIM/100CANON/IMG_0002.CR3": 300_000, "DCIM/100CANON/IMG_0002.XMP": 400,
                     "DCIM/100CANON/MVI_0003.MP4": 500_000]
        for (path, size) in files {
            let url = cardRoot.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ path.count) }).write(to: url)
        }
        var settings = IngestSettings()
        settings.destinationRoot = base.appendingPathComponent("Local").path
        settings.backupRoot = server.path
        try makeCreateOnly(server)
        let plan = try ImportPlanner.plan(cardRoot: cardRoot, cardName: "EOS_DIGITAL",
                                          files: try CardScanner.scan(cardRoot: cardRoot, fileTypes: settings.fileTypes),
                                          settings: settings, captureDate: { _, _ in nil })
        XCTAssertEqual(plan.folders.count, 2)

        // As CardWatcher does: the card to the local folder only; each verified file queued for the server.
        let job = ServerBackupJob(folder: plan.folders[1], root: server)
        let shots = LiveShots(planned: plan.files, fileTypes: settings.fileTypes)
        let report = try CardCopier.copy(cardRoot: cardRoot, cardName: "EOS_DIGITAL", files: plan.files,
                                         to: Array(plan.folders.prefix(1)), importNumber: plan.importNumber,
                                         fileVerified: { file in
                                             job.send(file)
                                             _ = shots.complete(file)
                                         })
        job.finish(report)
        // The card can go to the Trash now, from the local copy alone.
        XCTAssertEqual(CardClearer.safelyCopied(report: report, check: plan.check).count, 5)
        job.wait()

        XCTAssertEqual(job.current.sent, 5)
        XCTAssertEqual(job.current.problems, [])
        let local = try fm.contentsOfDirectory(atPath: plan.folders[0].path).filter { !$0.hasPrefix("Receipt_") }.sorted()
        let onServer = try fm.contentsOfDirectory(atPath: plan.folders[1].path).filter { !$0.hasPrefix("Receipt_") }.sorted()
        // The RAW without a card sidecar got one on this Mac; the server gets the card's files only, for now.
        XCTAssertEqual(local.count, 6)
        XCTAssertEqual(onServer, report.files.map(\.newName).sorted())
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: plan.folders[1].path).filter { $0.hasPrefix("Receipt_") }.count, 1)
        for name in onServer {
            XCTAssertEqual(try Data(contentsOf: plan.folders[1].appendingPathComponent(name)),
                           try Data(contentsOf: plan.folders[0].appendingPathComponent(name)), name)
        }
    }
}
