import CryptoKit
import XCTest
@testable import CardIngestCore

final class LicenseTests: XCTestCase {
    private let signer = Curve25519.Signing.PrivateKey()
    private var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }
    private let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!

    private func key(expires: String = "2027-04-27", email: String = "es@example.com",
                     signedBy other: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        try License.issue(.init(email: email, issued: "2026-10-27", expires: expires), signingWith: other ?? signer)
    }

    private func check(_ key: String, now: Date? = nil, lastSeen: Date? = nil) -> License.Status {
        License.check(key, now: now ?? today, lastSeen: lastSeen, publicKey: publicKey)
    }

    func testAValidKeyUnlocksWithItsEmailAndExpiry() throws {
        let status = check(try key())
        XCTAssertTrue(status.isValid)
        XCTAssertEqual(status.license?.email, "es@example.com")
        XCTAssertEqual(status.license?.expires, Calendar.current.date(from: DateComponents(year: 2027, month: 4, day: 27)))
        XCTAssertNil(status.problem)
    }

    func testAnEditedPayloadIsRejected() throws {
        let parts = try key().dropFirst(License.prefix.count).split(separator: ".")
        let forged = String(data: License.base64URLDecode(parts[0])!, encoding: .utf8)!.replacingOccurrences(of: "2027", with: "2099")
        let edited = License.prefix + License.base64URLEncode(Data(forged.utf8)) + "." + parts[1]
        XCTAssertEqual(check(edited), .invalid("That key isn't valid. Copy it again from the email, or ask for a new one."))
    }

    func testAnEditedSignatureIsRejected() throws {
        var characters = Array(try key())
        let last = characters.count - 3
        characters[last] = characters[last] == "A" ? "B" : "A"
        XCTAssertFalse(check(String(characters)).isValid)
        XCTAssertNil(check(String(characters)).license)
    }

    func testAKeySignedWithAnotherPrivateKeyIsRejected() throws {
        XCTAssertNil(check(try key(signedBy: Curve25519.Signing.PrivateKey())).license)
    }

    func testAKeyStopsWorkingTheDayAfterItsExpiry() throws {
        let key = try key(expires: "2026-11-05")
        let lastDay = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23))!
        let dayAfter = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 1))!
        XCTAssertTrue(check(key, now: lastDay).isValid)
        guard case .expired = check(key, now: dayAfter) else { return XCTFail("Should have expired") }
        XCTAssertEqual(check(key).license?.daysLeft(at: today), 10, "Today through November 5")
        XCTAssertEqual(check(key).license?.daysLeft(at: dayAfter), 0)
    }

    func testAClockTurnedBackIsCaughtButASmallDifferenceIsNot() throws {
        let key = try key()
        let lastSeen = Calendar.current.date(byAdding: .day, value: 10, to: today)!
        guard case .clockTurnedBack = check(key, lastSeen: lastSeen) else { return XCTFail("Should catch the clock") }
        XCTAssertTrue(check(key, lastSeen: today.addingTimeInterval(36 * 3600)).isValid, "Within two days")
        XCTAssertEqual(License.lastSeen(lastSeen, now: today), lastSeen, "Never moves backward")
        XCTAssertEqual(License.lastSeen(today, now: lastSeen), lastSeen)
        XCTAssertEqual(License.lastSeen(nil, now: today), today)
    }

    func testSpacesAndLineBreaksFromEmailAreIgnored() throws {
        let key = try key()
        let start = String(key.prefix(20)), middle = String(key.dropFirst(20).prefix(30)), end = String(key.dropFirst(50))
        let mangled = "  \(start)\n\(middle)\r\n \(end)\n"
        XCTAssertTrue(check(mangled).isValid)
    }

    func testARenewalReplacesTheOldKey() throws {
        let later = Calendar.current.date(from: DateComponents(year: 2027, month: 5, day: 1))!
        guard case .expired = check(try key(), now: later) else { return XCTFail("Old key should have expired") }
        XCTAssertTrue(check(try key(expires: "2027-10-27"), now: later).isValid)
    }

    func testNothingOrSomethingElsePastedSaysWhatsWrong() {
        XCTAssertEqual(check(""), .missing)
        XCTAssertEqual(License.check(nil), .missing)
        XCTAssertEqual(check("hello"), .invalid("That isn't a Media Sherpa key: keys start with CI1-."))
        XCTAssertEqual(check("CI1-abc"),
                       .invalid("That key is incomplete. Copy the whole key from the email, from CI1- to the end."))
    }

    func testTheBuiltInPublicKeyIsARealKey() {
        let data = Data(base64Encoded: License.publicKey)
        XCTAssertNotNil(data.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) })
    }
}
