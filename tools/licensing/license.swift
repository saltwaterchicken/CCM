#!/usr/bin/env swift
// Makes Card Ingest license keys. For the developer's Mac only: not part of
// the app or the Swift package, and the private key it makes is kept outside
// the repo, in ~/.cardingest. See README.md beside this file.
//
//   swift tools/licensing/license.swift generate-keypair
//   swift tools/licensing/license.swift issue-license --email someone@example.com --months 6
//   swift tools/licensing/license.swift issue-license --email someone@example.com --expires 2027-04-30
//
// The key format must match License.swift in CardIngestCore.

import CryptoKit
import Foundation

let privateKeyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cardingest/license_private.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func dayString(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func generateKeypair() {
    if FileManager.default.fileExists(atPath: privateKeyURL.path) {
        fail("A private key already exists at \(privateKeyURL.path). Not replacing it: every key issued with it "
             + "would stop working. Move it away first if you really mean to start again.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let folder = privateKeyURL.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: privateKeyURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
    } catch {
        fail("Couldn't save the private key: \(error.localizedDescription)")
    }
    print("Private key saved to \(privateKeyURL.path) (only you can read it). Back it up somewhere safe and offline;")
    print("never commit it, email it or put it in the app.")
    print("")
    print("Public key, for License.publicKey in Sources/CardIngestCore/License.swift:")
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

func issueLicense(_ arguments: [String]) {
    guard let email = option("--email", in: arguments)?.trimmingCharacters(in: .whitespaces), email.contains("@") else {
        fail("Give the customer's email: --email someone@example.com")
    }
    let today = Calendar.current.startOfDay(for: Date())
    let expires: String
    if let given = option("--expires", in: arguments) {
        guard given.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            fail("--expires takes a date like 2027-04-30")
        }
        expires = given
    } else {
        let months = Int(option("--months", in: arguments) ?? "6") ?? 0
        guard months > 0, let end = Calendar.current.date(byAdding: .month, value: months, to: today) else {
            fail("--months takes a whole number of months, like 6")
        }
        expires = dayString(end)
    }
    guard let text = try? String(contentsOf: privateKeyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No private key at \(privateKeyURL.path). Run generate-keypair first (once), or put your backup back there.")
    }
    // Keys sorted, as License.issue in the app does, though only the signature over these exact bytes matters.
    let payload: [String: Any] = ["email": email, "issued": dayString(today), "expires": expires, "v": 1]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
          let signature = try? key.signature(for: data) else {
        fail("Couldn't sign the key.")
    }
    print("License for \(email), good through \(expires):")
    print("")
    print("CI1-" + base64URL(data) + "." + base64URL(signature))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate-keypair": generateKeypair()
case "issue-license": issueLicense(arguments)
default:
    fail("""
        Usage:
          swift tools/licensing/license.swift generate-keypair
          swift tools/licensing/license.swift issue-license --email someone@example.com [--months 6 | --expires YYYY-MM-DD]
        """)
}
