import XCTest
@testable import CardIngestCore

final class ServerSyncTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var local: URL!
    private var server: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ServerSyncTests-\(UUID().uuidString)", isDirectory: true)
        local = base.appendingPathComponent("Local/2026-10-27-ES001", isDirectory: true)
        server = base.appendingPathComponent("Server/2026-10-27-ES001", isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", "-N", base.path]
        try process.run()
        process.waitUntilExit()
        try? fm.removeItem(at: base)
    }

    private func put(_ path: String, _ text: String, in folder: URL? = nil, date: Date? = nil) throws {
        let url = (folder ?? local).appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private func read(_ path: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    /// A culled card: RAWs, their sidecars with stars, a clip, the receipt and a Lightroom export.
    private func culledCard() throws {
        try put("A_0001.CR3", String(repeating: "raw1", count: 1000))
        try put("A_0001.xmp", "<rating>3</rating>")
        try put("A_0002.CR3", String(repeating: "raw2", count: 1000))
        try put("A_0002.xmp", "<rating>0</rating>")
        try put("A_0003.MP4", String(repeating: "clip", count: 2000))
        try put("Receipt_EOS_2026-10-27_101500.csv", "File,...")
        try put("•To Campanion/A_0001.jpg", "exported jpeg")
        try put("•To Campanion E/sub/A_0001.jpg", "another export")
        try put(".DS_Store", "finder")
        try put("CaptureOne/Cache/thumb.cot", "capture one")
    }

    func testAnEmptyServerGetsEverythingOnceAsCatchUp() throws {
        try culledCard()
        let plan = try ServerSync.plan(local: local, server: server)
        XCTAssertEqual(plan.adds.map(\.path), ["A_0001.CR3", "A_0001.xmp", "A_0002.CR3", "A_0002.xmp", "A_0003.MP4",
                                               "Receipt_EOS_2026-10-27_101500.csv", "•To Campanion E/sub/A_0001.jpg",
                                               "•To Campanion/A_0001.jpg"])
        XCTAssertEqual(plan.addedSidecars, 2)
        XCTAssertEqual(plan.addedExports, 2)
        XCTAssertEqual(plan.addedOriginals, 4)
        let outcome = ServerSync.run(plan)
        XCTAssertEqual(outcome.added, 8)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertEqual(try read("•To Campanion E/sub/A_0001.jpg", in: server), "another export")
        XCTAssertFalse(fm.fileExists(atPath: server.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(fm.fileExists(atPath: server.appendingPathComponent("CaptureOne").path))
        // Nothing left to do the second time.
        let again = try ServerSync.plan(local: local, server: server)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.unchanged, 8)
    }

    func testAfterTheBackupOnlyTheSidecarsAndExportsGoUp() throws {
        try culledCard()
        // The backup sent the card's files during the copy, with its own receipt.
        for name in ["A_0001.CR3", "A_0002.CR3", "A_0003.MP4"] {
            try fm.createDirectory(at: server, withIntermediateDirectories: true)
            try fm.copyItem(at: local.appendingPathComponent(name), to: server.appendingPathComponent(name))
        }
        try put("Receipt_EOS_2026-10-27_101500.csv", "the server's own receipt", in: server)
        let plan = try ServerSync.plan(local: local, server: server)
        XCTAssertEqual(plan.adds.map(\.path), ["A_0001.xmp", "A_0002.xmp", "•To Campanion E/sub/A_0001.jpg", "•To Campanion/A_0001.jpg"])
        XCTAssertEqual(plan.unchanged, 4)
        XCTAssertEqual(plan.cantUpdate, [])
    }

    func testNothingOnTheServerIsEverReplacedOrRemoved() throws {
        try culledCard()
        let old = Date(timeIntervalSinceNow: -3600)
        try put("A_0001.xmp", "<rating>1</rating>", in: server, date: old)      // stars changed here since
        try put("A_0002.xmp", "<rating>5</rating>", in: server, date: Date(timeIntervalSinceNow: 3600)) // newer there
        try put("A_0003.MP4", "part of a clip", in: server)                      // a broken earlier copy
        try put("•To Campanion/A_0001.jpg", "first export", in: server, date: old) // re-exported here
        try put("2025-08-01-ES099/old.CR3", "an older card gone from this Mac", in: server.deletingLastPathComponent())
        try put("A_0009.CR3", "deleted from this Mac since", in: server)

        let plan = try ServerSync.plan(local: local, server: server)
        XCTAssertEqual(plan.cantUpdate, ["A_0001.xmp", "A_0003.MP4", "•To Campanion/A_0001.jpg"])
        XCTAssertFalse(plan.adds.contains { ["A_0001.xmp", "A_0002.xmp", "A_0003.MP4", "A_0009.CR3"].contains($0.path) })
        _ = ServerSync.run(plan)
        XCTAssertEqual(try read("A_0001.xmp", in: server), "<rating>1</rating>")
        XCTAssertEqual(try read("A_0002.xmp", in: server), "<rating>5</rating>")
        XCTAssertEqual(try read("A_0003.MP4", in: server), "part of a clip")
        XCTAssertEqual(try read("•To Campanion/A_0001.jpg", in: server), "first export")
        XCTAssertEqual(try read("A_0009.CR3", in: server), "deleted from this Mac since")
        XCTAssertEqual(try read("2025-08-01-ES099/old.CR3", in: server.deletingLastPathComponent()), "an older card gone from this Mac")
    }

    func testOnACreateOnlyServerAReEditWaitsForTheAdmin() throws {
        try culledCard()
        let serverRoot = server.deletingLastPathComponent()
        try fm.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        for rule in ["everyone deny delete_child,directory_inherit", "everyone deny delete,writeattr,writeextattr,file_inherit,directory_inherit"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", rule, serverRoot.path]
            try process.run()
            process.waitUntilExit()
        }
        XCTAssertEqual(ServerSync.run(try ServerSync.plan(local: local, server: server)).problems, [])
        // A re-edit here: Sync lists it until the admin deletes the server's copy.
        try put("A_0001.xmp", "<rating>4</rating>", date: Date(timeIntervalSinceNow: 60))
        XCTAssertEqual(try ServerSync.plan(local: local, server: server).cantUpdate, ["A_0001.xmp"])
        XCTAssertThrowsError(try fm.removeItem(at: server.appendingPathComponent("A_0001.xmp")), "The photographer can't")
    }
}
