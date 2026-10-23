import XCTest
@testable import CardIngestCore

final class NameTemplateTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // Captured 2026-10-14 09:05:03 UTC, imported 2027-01-02 23:59:00 UTC.
    private let captured = Date(timeIntervalSince1970: 1_791_968_703)
    private let today = Date(timeIntervalSince1970: 1_798_934_340)

    private func render(_ pattern: String, original: String? = "IMG_1234.CR3", number: Int = 7) throws -> String {
        try NameTemplate(pattern).render(
            TemplateValues(today: today, importNumber: number, capture: captured, originalName: original),
            calendar: calendar)
    }

    func testImportDateTokens() throws {
        XCTAssertEqual(try render("{todayyear4}"), "2027")
        XCTAssertEqual(try render("{todayyear2}"), "27")
        XCTAssertEqual(try render("{todaymonth0}"), "01")
        XCTAssertEqual(try render("{todayday0}"), "02")
    }

    func testCaptureDateTokens() throws {
        XCTAssertEqual(try render("{year4}"), "2026")
        XCTAssertEqual(try render("{year2}"), "26")
        XCTAssertEqual(try render("{month0}"), "10")
        XCTAssertEqual(try render("{day0}"), "14")
        XCTAssertEqual(try render("{hour0}"), "09")
        XCTAssertEqual(try render("{minute0}"), "05")
        XCTAssertEqual(try render("{second0}"), "03")
    }

    func testImportNumberIsThreeDigits() throws {
        XCTAssertEqual(try render("{iseq}", number: 1), "001")
        XCTAssertEqual(try render("{iseq}", number: 42), "042")
        XCTAssertEqual(try render("{iseq}", number: 1234), "1234")
    }

    func testFrameNumber() throws {
        XCTAssertEqual(try render("{frame4}", original: "IMG_1234.CR3"), "1234")
        XCTAssertEqual(try render("{frame4}", original: "DSC01234.ARW"), "1234")
        XCTAssertEqual(try render("{frame4}", original: "_MG_0042.CR2"), "0042")
        XCTAssertEqual(try render("{frame4}", original: "GOPR0007.MP4"), "0007")
        XCTAssertEqual(try render("{frame4}", original: "C0001.MP4"), "0001")
        XCTAssertEqual(try render("{frame4}", original: "PICTURE.JPG"), "0000")
        XCTAssertEqual(try render("{frame4}", original: "IMG_12.JPG"), "0012")
        XCTAssertEqual(try render("{frame4}", original: "IMG_1234"), "1234", "No extension")
    }

    func testFileNameDropsExtension() throws {
        XCTAssertEqual(try render("{filename}", original: "IMG_1234.CR3"), "IMG_1234")
    }

    func testTextOutsideBracesIsKeptAndTokensIgnoreCase() throws {
        XCTAssertEqual(try render("{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}", number: 1), "2027-01-02-ES001")
        XCTAssertEqual(try render("{year4}-{month0}-{day0}-ES_{frame4}"), "2026-10-14-ES_1234")
        XCTAssertEqual(try render("Shot {YEAR4} #{Frame4}"), "Shot 2026 #1234")
    }

    func testResultCannotMakeFolders() throws {
        XCTAssertEqual(try render("../A/B:C"), "-A-B-C")
        XCTAssertEqual(try render("   "), "Unknown")
    }

    func testUnknownTokenIsNamed() {
        XCTAssertThrowsError(try render("{year4}-{lens}")) { error in
            XCTAssertEqual(error as? TemplateError, .unknownToken("lens"))
            XCTAssertTrue(error.localizedDescription.contains("{lens}"))
        }
        XCTAssertThrowsError(try NameTemplate("{date:YYYY}").validate(forFiles: true)) { error in
            XCTAssertEqual(error as? TemplateError, .unknownToken("date:YYYY"), "Old Milestone 1 fields are gone")
        }
        XCTAssertThrowsError(try render("{year4")) { error in
            XCTAssertEqual(error as? TemplateError, .unclosedBrace)
        }
    }

    func testFileTokensAreRefusedInFolderNames() {
        let folder = TemplateValues(today: today, importNumber: 1)
        for token in ["year4", "day0", "frame4", "filename"] {
            XCTAssertThrowsError(try NameTemplate("{\(token)}").render(folder)) { error in
                XCTAssertEqual(error as? TemplateError, .onlyInFileNames(token))
            }
        }
        XCTAssertNoThrow(try NameTemplate("{todayyear4}-ES{iseq}").validate(forFiles: false))
    }
}
