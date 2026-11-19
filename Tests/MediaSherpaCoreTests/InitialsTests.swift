import XCTest
@testable import MediaSherpaCore

final class InitialsTests: XCTestCase {
    func testTheInitialsAreTheLettersBeforeTheImportNumber() {
        XCTAssertEqual(Initials.current(in: "{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}"), "ES")
        XCTAssertEqual(Initials.current(in: "Camp_KE{ISEQ}"), "KE")
        XCTAssertNil(Initials.current(in: "{todayyear4}-{iseq}"))
        XCTAssertNil(Initials.current(in: "{todayyear4}-ES"))
    }

    func testNewInitialsGoInBothNamesAndOnlyOutsideTheTokens() throws {
        let changed = try XCTUnwrap(Initials.apply("ab", to: IngestSettings()))
        XCTAssertEqual(changed.folderName, "{todayyear4}-{todaymonth0}-{todayday0}-AB{iseq}")
        XCTAssertEqual(changed.renamePattern, "{year4}-{month0}-{day0}-AB_{frame4}")
        XCTAssertEqual(try changed.cardFolderName().hasSuffix("-AB001"), true)
    }

    func testTypingOneLetterAtATimeKeepsWorking() throws {
        var settings = IngestSettings()
        for typed in ["J", "JM", "JMK", "JM"] { settings = try XCTUnwrap(Initials.apply(typed, to: settings)) }
        XCTAssertEqual(settings.folderName, "{todayyear4}-{todaymonth0}-{todayday0}-JM{iseq}")
        XCTAssertEqual(settings.renamePattern, "{year4}-{month0}-{day0}-JM_{frame4}")
    }

    func testOnlyWhereTheInitialsStandAlone() {
        XCTAssertEqual(Initials.replace("ES", with: "AB", in: "BEST-ES_{frame4}"), "BEST-AB_{frame4}")
        XCTAssertEqual(Initials.replace("E", with: "AB", in: "{todaymonth0}-E{iseq}"), "{todaymonth0}-AB{iseq}", "Not inside a token")
    }

    func testWhatsTypedIsCleanedAndNothingTypedChangesNothing() {
        XCTAssertEqual(Initials.clean(" e.s/ 2 "), "ES2")
        XCTAssertEqual(Initials.clean("abcdefgh"), "ABCDEF")
        XCTAssertNil(Initials.apply("", to: IngestSettings()))
        XCTAssertNil(Initials.apply("AB", to: IngestSettings(folderName: "{todayyear4}-{iseq}")))
    }

    func testThePatternSplitsAroundTheInitialsForTheJobPanel() throws {
        let folder = try XCTUnwrap(Initials.split("{todayyear4}-{todaymonth0}-{todayday0}-ISC{iseq}", at: "ISC"))
        XCTAssertEqual(folder.before, "{todayyear4}-{todaymonth0}-{todayday0}-")
        XCTAssertEqual(folder.after, "{iseq}")
        let file = try XCTUnwrap(Initials.split("{year4}-{month0}-{day0}-ISC_{frame4}", at: "ISC"))
        XCTAssertEqual(file.before, "{year4}-{month0}-{day0}-")
        XCTAssertEqual(file.after, "_{frame4}")
        let first = try XCTUnwrap(Initials.split("BEST-ES_{frame4}", at: "ES"), "Not inside a longer word")
        XCTAssertEqual(first.before, "BEST-")
        XCTAssertNil(Initials.split("{todaymonth0}-{iseq}", at: "E"), "Not inside a token")
        XCTAssertNil(Initials.split("{year4}_{frame4}", at: "ES"))
        XCTAssertNil(Initials.split("{year4}", at: ""))
    }
}
