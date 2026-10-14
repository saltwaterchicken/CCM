import XCTest
@testable import CardIngestCore

final class NameTemplateTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // 2026-10-14 09:05:03 UTC
    private let date = Date(timeIntervalSince1970: 1_791_968_703)

    func testBriefExamplePattern() throws {
        let values = TemplateValues(date: date, job: "Camp", camera: "Canon EOS R5", sequence: 7)
        let name = try NameTemplate("{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}").render(values, calendar: calendar)
        XCTAssertEqual(name, "2026-10-14_Camp_Canon EOS R5_0007")
    }

    func testTimeAndShortYear() throws {
        let values = TemplateValues(date: date, job: "x")
        XCTAssertEqual(try NameTemplate("{date:YYMMDD-hhmmss}").render(values, calendar: calendar), "261014-090503")
    }

    func testOriginalDropsExtension() throws {
        let values = TemplateValues(date: date, job: "x", original: "IMG_1234.CR3")
        XCTAssertEqual(try NameTemplate("{original}").render(values, calendar: calendar), "IMG_1234")
    }

    func testMissingFieldsSayUnknown() throws {
        let values = TemplateValues(date: date, job: "")
        XCTAssertEqual(try NameTemplate("{job}_{camera}_{serial}").render(values, calendar: calendar), "Untitled_Unknown_Unknown")
    }

    func testValuesCannotCreateFolders() throws {
        let values = TemplateValues(date: date, job: "../A/B:C")
        XCTAssertEqual(try NameTemplate("{job}").render(values, calendar: calendar), "-A-B-C")
    }

    func testErrors() {
        let values = TemplateValues(date: date, job: "x")
        XCTAssertThrowsError(try NameTemplate("{lens}").render(values)) { error in
            XCTAssertEqual(error as? TemplateError, .unknownField("lens"))
        }
        XCTAssertThrowsError(try NameTemplate("{job").render(values)) { error in
            XCTAssertEqual(error as? TemplateError, .unclosedBrace)
        }
        XCTAssertThrowsError(try NameTemplate("{seq:abc}").render(values)) { error in
            XCTAssertEqual(error as? TemplateError, .badSequenceWidth("abc"))
        }
    }

    func testDefaultDestinationFolder() throws {
        var settings = IngestSettings()
        settings.jobName = "Smith Wedding"
        let root = URL(fileURLWithPath: "/Photos", isDirectory: true)
        let folder = try settings.destinationFolder(for: date, root: root, calendar: calendar)
        XCTAssertEqual(folder.path, "/Photos/2026/2026-10-14_Smith Wedding")
    }

    func testFolderPatternCannotEscapeRoot() throws {
        var settings = IngestSettings()
        settings.folderPattern = "../../{job}"
        let root = URL(fileURLWithPath: "/Photos", isDirectory: true)
        let folder = try settings.destinationFolder(for: date, root: root, calendar: calendar)
        XCTAssertEqual(folder.path, "/Photos/Untitled")
    }
}
