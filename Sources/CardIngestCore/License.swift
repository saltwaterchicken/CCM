import CryptoKit
import Foundation

/// Offline license keys: a small JSON payload (email, issued, expires) signed
/// with an Ed25519 private key that never leaves the developer's Mac. The app
/// holds only the public key, so it can tell a real key from a made-up or
/// edited one without any network. Keys are made by tools/licensing/license.swift.
public struct License: Equatable, Sendable {
    public let email: String
    public let issued: Date
    /// The last day the key works, through to midnight at its end.
    public let expires: Date

    /// Keys start with this, so they're easy to recognise in an email.
    public static let prefix = "CI1-"

    /// The public half of the signing key (raw 32 bytes, base64). Safe to
    /// publish: it can only check keys, not make them.
    public static let publicKey = "33iAPEf7BbV7e01LWg+WO/Jc1CP1fTDJNX3O92IYWIY="

    /// How far behind the latest date the app has seen the clock may be before
    /// it counts as turned back (time zones and small corrections stay well inside).
    public static let clockAllowance: TimeInterval = 2 * 24 * 3600

    /// Days from 14 before the end on, a reminder to renew shows.
    public static let reminderDays = 14

    public enum Status: Equatable, Sendable {
        case valid(License)
        case expired(License)
        /// The Mac's clock is earlier than a date the app has already seen.
        case clockTurnedBack(License, lastSeen: Date)
        case invalid(String)
        case missing

        public var license: License? {
            switch self {
            case let .valid(license), let .expired(license), let .clockTurnedBack(license, _): license
            case .invalid, .missing: nil
            }
        }

        public var isValid: Bool { if case .valid = self { true } else { false } }

        /// What went wrong, in words for the photographer; nil when valid.
        public var problem: String? {
            switch self {
            case .valid: nil
            case .missing: "Enter your license key to use Media Sherpa."
            case let .invalid(reason): reason
            case let .expired(license): "This key ran out on \(License.format(license.expires)). Ask for a new key to renew."
            case let .clockTurnedBack(_, lastSeen):
                "The Mac's clock is set earlier than \(License.format(lastSeen)), a date Media Sherpa has already seen. "
                    + "Set the right date and time in System Settings › General › Date & Time."
            }
        }
    }

    /// The day after the expiry date begins, when the key stops working.
    public var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: expires) ?? expires }

    /// Whole days from `now` to the end, counting today; 0 once it has ended.
    public func daysLeft(at now: Date) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: end).day ?? 0
        return max(0, days)
    }

    /// Checks a pasted key. Spaces and line breaks anywhere are ignored, as
    /// email apps break long lines. With `lastSeen` (the latest date this app
    /// has seen), a clock set more than two days earlier than that is caught.
    public static func check(_ key: String?, now: Date = Date(), lastSeen: Date? = nil,
                             publicKey: String = License.publicKey) -> Status {
        guard let key else { return .missing }
        let cleaned = key.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return .missing }
        guard cleaned.uppercased().hasPrefix(prefix) else {
            return .invalid("That isn't a Media Sherpa key: keys start with \(prefix).")
        }
        let parts = cleaned.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = base64URLDecode(parts[0]), let signature = base64URLDecode(parts[1]) else {
            return .invalid("That key is incomplete. Copy the whole key from the email, from \(prefix) to the end.")
        }
        guard let keyData = Data(base64Encoded: publicKey),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              verifier.isValidSignature(signature, for: payload) else {
            return .invalid("That key isn't valid. Copy it again from the email, or ask for a new one.")
        }
        guard let fields = try? JSONDecoder().decode(Payload.self, from: payload), fields.v == 1,
              let issued = day(fields.issued), let expires = day(fields.expires) else {
            return .invalid("That key is from a newer version of Media Sherpa. Update the app, or ask for a new key.")
        }
        let license = License(email: fields.email, issued: issued, expires: expires)
        if let lastSeen, now < lastSeen.addingTimeInterval(-clockAllowance) {
            return .clockTurnedBack(license, lastSeen: lastSeen)
        }
        return now >= license.end ? .expired(license) : .valid(license)
    }

    /// The latest date seen, after seeing `now`: it never moves backward.
    public static func lastSeen(_ previous: Date?, now: Date) -> Date {
        max(previous ?? now, now)
    }

    /// What a key carries, as JSON: dates are plain days, "2027-04-27".
    public struct Payload: Codable, Equatable, Sendable {
        public var email: String
        public var issued: String
        public var expires: String
        public var v: Int

        public init(email: String, issued: String, expires: String, v: Int = 1) {
            self.email = email
            self.issued = issued
            self.expires = expires
            self.v = v
        }
    }

    /// Makes a key from a payload and a private key: what the licensing tool
    /// does, here so the tests can make keys too.
    public static func issue(_ payload: Payload, signingWith privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(payload)
        return prefix + base64URLEncode(data) + "." + base64URLEncode(try privateKey.signature(for: data))
    }

    public static func format(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: Substring) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
