import CryptoKit
import XCTest
@testable import CardIngestCore

/// Finding the XMP block inside a RAW, whose digest Lightroom needs in the sidecar.
final class RawXMPTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RawXMPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// What Sony puts in an ARW, padded like the real one.
    static let block = Data(("<?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'>"
        + "<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about='' "
        + "xmlns:xmp='http://ns.adobe.com/xap/1.0/'><xmp:Rating>0</xmp:Rating></rdf:Description></rdf:RDF>"
        + "</x:xmpmeta>" + String(repeating: " ", count: 200) + "<?xpacket end='w'?>").utf8)

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// A tiny TIFF-style RAW: a first IFD with an image width and tag 700.
    static func tiffRaw(xmp: Data?, littleEndian: Bool = true, magic: UInt16 = 42) -> Data {
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: littleEndian ? v.littleEndian : v.bigEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: littleEndian ? v.littleEndian : v.bigEndian) { Data($0) } }
        var d = Data((littleEndian ? "II" : "MM").utf8)
        d.append(u16(magic))
        d.append(u32(8))
        let entries: UInt16 = xmp == nil ? 1 : 2
        let dataStart = UInt32(8 + 2 + Int(entries) * 12 + 4)
        d.append(u16(entries))
        for part in [u16(256), u16(3), u32(1), u16(6000), u16(0)] { d.append(part) }
        if let xmp {
            for part in [u16(700), u16(7), u32(UInt32(xmp.count)), u32(dataStart)] { d.append(part) }
        }
        d.append(u32(0))
        if let xmp { d.append(xmp) }
        d.append(Data(repeating: 0xAB, count: 5000))
        return d
    }

    /// A tiny CR3-style file: ftyp, moov, then Adobe's XMP uuid box.
    static func cr3(xmp: Data) -> Data {
        func box(_ type: String, _ body: Data) -> Data {
            withUnsafeBytes(of: UInt32(8 + body.count).bigEndian) { Data($0) } + Data(type.utf8) + body
        }
        var d = box("ftyp", Data("crx isom".utf8))
        d.append(box("moov", Data(repeating: 1, count: 300)))
        d.append(box("uuid", RawXMP.xmpBoxID + xmp))
        d.append(box("mdat", Data(repeating: 2, count: 4000)))
        return d
    }

    /// A tiny RAF: Fuji's header, pointers at 84, and a preview JPEG with Exif and XMP sections.
    static func raf(xmp: Data) -> Data {
        func be16(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func be32(_ v: Int) -> Data { be16(v >> 16) + be16(v & 0xFFFF) }
        var jpeg = Data([0xFF, 0xD8])
        let exif = Data("Exif\0\0".utf8) + Data(repeating: 3, count: 500)
        jpeg.append(Data([0xFF, 0xE1]) + be16(exif.count + 2) + exif)
        let app1 = Data("http://ns.adobe.com/xap/1.0/\0".utf8) + xmp
        jpeg.append(Data([0xFF, 0xE1]) + be16(app1.count + 2) + app1)
        jpeg.append(Data([0xFF, 0xDA, 0x00, 0x0C]) + Data(repeating: 9, count: 2000))
        var d = Data("FUJIFILMCCD-RAW ".utf8) + Data(repeating: 0, count: 68)
        d.append(be32(148))
        d.append(be32(jpeg.count))
        d.append(Data(repeating: 0, count: 148 - d.count))
        d.append(jpeg)
        return d
    }

    func testFujifilmRAF() throws {
        XCTAssertEqual(RawXMP.embeddedXMP(in: try write(Self.raf(xmp: Self.block), "_DSF0001.RAF")), Self.block)
        XCTAssertEqual(RawXMP.digest(of: try write(Self.raf(xmp: Self.block), "_DSF0002.RAF")), Self.md5(Self.block))
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testSonyStyleRawGivesTheDigestOfItsXMPBlock() throws {
        let raw = try write(Self.tiffRaw(xmp: Self.block), "DSC00001.ARW")
        XCTAssertEqual(RawXMP.embeddedXMP(in: raw), Self.block)
        XCTAssertEqual(RawXMP.digest(of: raw), Self.md5(Self.block))
        XCTAssertEqual(RawXMP.digest(of: raw)?.count, 32)
    }

    func testBigEndianAndOtherTIFFMagicNumbers() throws {
        XCTAssertEqual(RawXMP.digest(of: try write(Self.tiffRaw(xmp: Self.block, littleEndian: false), "a.NEF")),
                       Self.md5(Self.block))
        XCTAssertEqual(RawXMP.digest(of: try write(Self.tiffRaw(xmp: Self.block, magic: 0x4F52), "a.ORF")),
                       Self.md5(Self.block))
        XCTAssertEqual(RawXMP.digest(of: try write(Self.tiffRaw(xmp: Self.block, magic: 0x55), "a.RW2")),
                       Self.md5(Self.block))
    }

    func testCanonCR3() throws {
        XCTAssertEqual(RawXMP.digest(of: try write(Self.cr3(xmp: Self.block), "IMG_0001.CR3")), Self.md5(Self.block))
    }

    func testNoBlockOrNotARawGivesNil() throws {
        XCTAssertNil(RawXMP.digest(of: try write(Self.tiffRaw(xmp: nil), "plain.DNG")))
        XCTAssertNil(RawXMP.digest(of: try write(Data("random bytes, not a raw".utf8), "x.CR2")))
        XCTAssertNil(RawXMP.digest(of: try write(Data(), "empty.ARW")))
        XCTAssertNil(RawXMP.digest(of: dir.appendingPathComponent("missing.ARW")))
    }

    func testADamagedRawIsntReadPastItsEnd() throws {
        var raw = Self.tiffRaw(xmp: Self.block)
        raw = raw.prefix(40)
        XCTAssertNil(RawXMP.digest(of: try write(raw, "cut.ARW")))
    }

    /// Lightroom only takes the sidecar's stars when this digest is in it.
    func testSidecarForARawCarriesItsDigest() throws {
        let raw = try write(Self.tiffRaw(xmp: Self.block), "2026-10-23-ES_0002.ARW")
        let sidecar = dir.appendingPathComponent("2026-10-23-ES_0002.xmp")
        try Stars.write(1, toXMP: sidecar, raw: raw)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains(Self.md5(Self.block)), text)
        XCTAssertTrue(text.contains("EmbeddedXMPDigest"))
        XCTAssertTrue(text.contains("<photoshop:SidecarForExtension>ARW</photoshop:SidecarForExtension>"), text)
        XCTAssertTrue(text.contains("MetadataDate"))
        XCTAssertEqual(Stars.read(xmp: sidecar), 1)
    }

    /// Optional: REAL_ARW=/path/to.ARW REAL_DIGEST=... checks against what Lightroom wrote.
    func testAgainstARealRawWhenGiven() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["REAL_ARW"], let expected = env["REAL_DIGEST"] else { throw XCTSkip("no real RAW given") }
        XCTAssertEqual(RawXMP.digest(of: URL(fileURLWithPath: path)), expected)
    }
}
