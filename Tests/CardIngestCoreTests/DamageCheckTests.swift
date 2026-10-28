import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CardIngestCore

/// Spotting files that were already damaged on the card, e.g. by a flat
/// battery while the camera was writing, and keeping them on the card.
final class DamageCheckTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("DamageTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func problem(_ data: Data, _ name: String) throws -> String? {
        DamageCheck.problem(at: try write(data, name))
    }

    /// A real JPEG, noisy so it doesn't compress to nothing.
    private func jpeg() throws -> Data {
        let width = 400, height = 300
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 1
        for i in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
    private func le32(_ v: Int) -> Data { Data((0..<4).map { UInt8(v >> ($0 * 8) & 0xFF) }) }
    private func be32(_ v: Int) -> Data { Data((0..<4).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) }) }

    /// A little-endian TIFF-style RAW: IFD0 points to a SubIFD holding one
    /// strip of `stripLength` bytes at `stripOffset`.
    private func tiffRaw(stripOffset: Int, stripLength: Int, fileLength: Int) -> Data {
        var d = Data("II".utf8) + le16(42) + le32(8)
        // IFD0 at 8: one entry, the SubIFD at 26.
        d += le16(1) + le16(330) + le16(4) + le32(1) + le32(26) + le32(0)
        // SubIFD at 26: strip offset and length.
        d += le16(2)
        d += le16(273) + le16(4) + le32(1) + le32(stripOffset)
        d += le16(279) + le16(4) + le32(1) + le32(stripLength)
        d += le32(0)
        var seed: UInt8 = 3
        while d.count < fileLength {
            seed = seed &* 37 &+ 11
            d.append(seed)
        }
        return d
    }

    private func box(_ type: String, _ body: Data, size: Int? = nil) -> Data {
        be32(size ?? body.count + 8) + Data(type.utf8) + body
    }

    func testAWholeJPEGLooksFine() throws {
        let whole = try jpeg()
        XCTAssertNil(try problem(whole, "A.JPG"))
        XCTAssertNil(try problem(whole + Data(repeating: 0, count: 2000), "B.JPG"), "A little padding after the end is fine")
        XCTAssertNil(try problem(whole + box("mdat", Data(repeating: 5, count: 5000)), "C.JPG"),
                     "Something else after the picture, as some phones add, is fine")
    }

    func testAJPEGCutShortIsSpotted() throws {
        let whole = try jpeg()
        let cut = whole.prefix(whole.count * 2 / 3)
        XCTAssertEqual(try problem(Data(cut), "A.JPG"), "it stops part way through: the end of the picture is missing.")
    }

    func testAJPEGEndingInBlankBytesIsSpotted() throws {
        let whole = try jpeg()
        let blanked = whole.prefix(whole.count / 2) + Data(repeating: 0, count: 400 * 1024)
        let found = try XCTUnwrap(try problem(Data(blanked), "A.JPG"))
        XCTAssertTrue(found.hasPrefix("the last "), found)
        XCTAssertTrue(found.hasSuffix("of it is blank: the camera didn't finish writing it."), found)
    }

    func testAnEmptyOrBlankFileIsSpotted() throws {
        XCTAssertEqual(try problem(Data(), "A.CR3"), "it's empty: the camera didn't write anything into it.")
        XCTAssertEqual(try problem(Data(repeating: 0, count: 600 * 1024), "B.NEF"),
                       "it's blank: the camera didn't write the picture into it.")
        XCTAssertEqual(try problem(Data(repeating: 0xFF, count: 300 * 1024), "C.JPG"),
                       "it's blank: the camera didn't write the picture into it.")
    }

    func testSidecarsAndUnknownFilesAreNotChecked() throws {
        XCTAssertNil(try problem(Data(), "A.xmp"))
        XCTAssertNil(try problem(Data(repeating: 0, count: 600 * 1024), "B.THM"))
        XCTAssertNil(try problem(Data("random bytes, not a raw".utf8), "C.CR2"), "A layout it doesn't know isn't called damaged")
    }

    func testATIFFRawWhosePictureDataRunsPastTheEndIsSpotted() throws {
        XCTAssertNil(try problem(tiffRaw(stripOffset: 100, stripLength: 5000, fileLength: 5100), "A.NEF"))
        let cut = try XCTUnwrap(try problem(tiffRaw(stripOffset: 100, stripLength: 50_000, fileLength: 5100), "B.NEF"))
        XCTAssertTrue(cut.hasPrefix("it stops part way through:"), cut)
        XCTAssertTrue(cut.contains("of the picture data is missing"), cut)
    }

    func testAFujifilmRawCutShortIsSpotted() throws {
        func raf(rawLength: Int) -> Data {
            var d = Data("FUJIFILMCCD-RAW ".utf8) + Data(repeating: 0x20, count: 68)
            d += be32(200) + be32(100) + be32(300) + be32(50) + be32(400) + be32(rawLength)
            while d.count < 2000 { d.append(UInt8(truncatingIfNeeded: d.count &* 13)) }
            return d
        }
        XCTAssertNil(try problem(raf(rawLength: 1600), "A.RAF"))
        XCTAssertNotNil(try problem(raf(rawLength: 90_000), "B.RAF"))
    }

    func testAClipThatNeverFinishedIsSpotted() throws {
        let ftyp = box("ftyp", Data("isom\0\0\0\0isom".utf8))
        let moov = box("moov", Data(repeating: 1, count: 300))
        let mdat = box("mdat", Data(repeating: 2, count: 4000))
        XCTAssertNil(try problem(ftyp + moov + mdat, "A.MP4"))
        XCTAssertNil(try problem(ftyp + mdat + moov, "B.MOV"), "The index can come at the end")
        XCTAssertEqual(try problem(ftyp + box("mdat", Data(repeating: 2, count: 4000), size: 0), "C.MP4"),
                       "the clip was never finished (it has no index), so it won't play. Recording may have stopped suddenly.")
        let cut = try XCTUnwrap(try problem(ftyp + moov + box("mdat", Data(repeating: 2, count: 4000), size: 90_000), "D.MP4"))
        XCTAssertTrue(cut.hasPrefix("it stops part way through:"), cut)
        // A CR3 is built the same way.
        XCTAssertNil(try problem(ftyp + moov + mdat, "E.CR3"))
        XCTAssertNotNil(try problem(ftyp + moov + box("mdat", Data(repeating: 2, count: 100), size: 9000), "F.CR3"))
    }

    /// A Copy brings a damaged file in exactly as it is, says so in the
    /// report and receipt, and leaves the original on the card.
    func testACopyKeepsTheDamagedFileOnTheCardAndSaysSo() throws {
        let card = base.appendingPathComponent("CARD", isDirectory: true)
        let folder = card.appendingPathComponent("DCIM/100TEST", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let whole = try jpeg()
        try whole.write(to: folder.appendingPathComponent("IMG_0001.JPG"))
        let cut = Data(whole.prefix(whole.count / 2))
        try cut.write(to: folder.appendingPathComponent("IMG_0002.JPG"))

        var settings = IngestSettings()
        settings.destinationRoot = base.appendingPathComponent("Main").path
        let files = try CardScanner.scan(cardRoot: card, fileTypes: settings.fileTypes)
        let plan = try ImportPlanner.plan(cardRoot: card, cardName: "CARD", files: files, settings: settings,
                                          captureDate: { _, _ in nil })
        let report = try CardCopier.copy(cardRoot: card, cardName: "CARD", files: plan.files, to: plan.folders,
                                         fileTypes: settings.fileTypes)

        XCTAssertEqual(report.files.count, 2, "Both are copied")
        XCTAssertEqual(report.damaged.map(\.originalPath), ["DCIM/100TEST/IMG_0002.JPG"])
        let copy = try XCTUnwrap(report.damaged.first?.destinations.first)
        XCTAssertEqual(try Data(contentsOf: copy), cut, "Copied exactly as it was on the card")

        let receipt = try String(contentsOf: try XCTUnwrap(report.receipts.first), encoding: .utf8)
        XCTAssertTrue(receipt.contains("yes, but damaged on the card: it stops part way through"), receipt)
        XCTAssertTrue(receipt.contains("Damaged on the card,1"), receipt)
        XCTAssertEqual(Receipt.read(try XCTUnwrap(report.receipts.first))?.rows.count, 2, "The receipt still reads back")

        let safe = CardClearer.safelyCopied(report: report, check: plan.check)
        XCTAssertEqual(safe.map(\.relativePath), ["DCIM/100TEST/IMG_0001.JPG"], "The damaged one stays on the card")

        // Put back in later, it still stays.
        let again = try ImportPlanner.plan(cardRoot: card, cardName: "CARD", files: files, settings: settings,
                                           captureDate: { _, _ in nil })
        XCTAssertTrue(again.nothingNew)
        XCTAssertEqual(CardClearer.safelyCopied(report: nil, check: again.check).map(\.relativePath),
                       ["DCIM/100TEST/IMG_0001.JPG"])

        // Loaded back into the grid, it's marked too.
        let loaded = try ImportedFolder.shots(in: plan.folders[0], backupRoot: nil, fileTypes: settings.fileTypes)
        XCTAssertEqual(loaded.map { $0.shot.damaged.isEmpty }, [true, false])
    }
}
