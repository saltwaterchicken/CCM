import Darwin
import XCTest
@testable import MediaSherpaCore

/// A card's data must pass through memory, not stay there: until 2026-11-03 every 8 MB read
/// was held until the whole card was done, and a video card ran the Mac out of memory.
final class MemoryUseTests: XCTestCase {
    private let size: Int64 = 1 << 30
    /// Well under the 1 GB read, and well over a chunk or two.
    private let allowed: UInt64 = 300 << 20
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// What the Mac counts against this process, and what ran out.
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return info.phys_footprint
    }

    /// Takes no room on the disk until it's copied; reads as zeros.
    private func bigFile(_ name: String, startingWith head: Data = Data()) throws -> URL {
        let url = folder.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: head))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    /// The most memory `work` added, sampled as it goes.
    private func peakGrowth(during work: () throws -> Void) rethrows -> UInt64 {
        final class Peak: @unchecked Sendable {
            let lock = NSLock()
            var value: UInt64 = 0
            var done = false
        }
        let before = footprint()
        let peak = Peak()
        let finished = DispatchSemaphore(value: 0)
        let watcher = Thread { [self] in
            while peak.lock.withLock({ !peak.done }) {
                let now = footprint()
                peak.lock.withLock { peak.value = max(peak.value, now) }
                usleep(5_000)
            }
            finished.signal()
        }
        watcher.start()
        defer {
            peak.lock.withLock { peak.done = true }
            finished.wait()
        }
        try work()
        let highest = peak.lock.withLock { max(peak.value, footprint()) }
        return highest > before ? highest - before : 0
    }

    func testCopyDoesNotHoldTheCardInMemory() throws {
        let card = folder.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let clip = try bigFile("CLIP.MXF")
        try FileManager.default.moveItem(at: clip, to: card.appendingPathComponent("CLIP.MXF"))
        let planned = PlannedFile(source: CardFile(relativePath: "CLIP.MXF", size: size), newName: "CLIP.MXF")
        let growth = try peakGrowth {
            _ = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: [planned],
                                    to: [folder.appendingPathComponent("out")])
        }
        XCTAssertLessThan(growth, allowed, "copying 1 GB added \(growth >> 20) MB")
    }

    func testServerCopyDoesNotHoldTheFileInMemory() throws {
        let clip = try bigFile("CLIP.MXF")
        let growth = peakGrowth {
            XCTAssertEqual(ServerBackup.send(clip, checksum: nil, to: folder.appendingPathComponent("server")), .copied)
        }
        XCTAssertLessThan(growth, allowed, "sending 1 GB added \(growth >> 20) MB")
    }

    func testClipDigestDoesNotHoldTheClipInMemory() throws {
        var head = Data(withUnsafeBytes(of: UInt32(size).bigEndian) { Array($0) })
        head.append(Data("mdat".utf8))
        let clip = try bigFile("CLIP.MP4", startingWith: head)
        let growth = try peakGrowth { _ = try ClipMetadata.mediaDigest(of: clip) }
        XCTAssertLessThan(growth, allowed, "reading 1 GB added \(growth >> 20) MB")
    }
}
