import XCTest
@testable import CardIngestCore

final class XXHash64Tests: XCTestCase {
    // Expected values come from the reference xxHash library.
    func testKnownValues() {
        XCTAssertEqual(XXHash64.hex(XXHash64.hash(Data())), "ef46db3751d8e999")
        XCTAssertEqual(XXHash64.hex(XXHash64.hash(Data("a".utf8))), "d24ec4f1a98c6e5b")
        XCTAssertEqual(XXHash64.hex(XXHash64.hash(Data("abc".utf8))), "44bc2cf5ad770999")
        XCTAssertEqual(XXHash64.hex(XXHash64.hash(Data("Card Ingest".utf8))), "f8120d69bc0d9cf9")
        let pattern = Data((0..<1000).map { UInt8($0 % 251) })
        XCTAssertEqual(XXHash64.hex(XXHash64.hash(pattern.prefix(37))), "d93fa2dfee5c24c9")
        XCTAssertEqual(XXHash64.hex(XXHash64.hash(pattern)), "f306f04aa88b54d3")
    }

    func testPiecesGiveTheSameAnswerAsOneGo() {
        let pattern = Data((0..<1000).map { UInt8($0 % 251) })
        for pieceSize in [1, 3, 7, 31, 32, 33, 100, 999] {
            var hasher = XXHash64()
            var start = 0
            while start < pattern.count {
                let end = min(start + pieceSize, pattern.count)
                hasher.update(pattern.subdata(in: start..<end))
                start = end
            }
            XCTAssertEqual(XXHash64.hex(hasher.digest()), "f306f04aa88b54d3", "piece size \(pieceSize)")
        }
    }
}
