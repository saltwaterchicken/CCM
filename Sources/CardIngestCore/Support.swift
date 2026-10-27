import Foundation

/// The summary at the end of a receipt, for a support message.
public struct ReceiptSummary: Equatable, Sendable {
    public let url: URL
    public let card: String
    public let files: Int
    public let totalBytes: Int64
    public let importNumber: Int?
    public let finished: String?
    public let copies: String

    /// One line per field, as the support message lists them.
    public var lines: [String] {
        var lines = ["Card: \(card)", "Files: \(files), \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)), all verified"]
        if let importNumber { lines.append("Import number: \(String(format: "%03d", importNumber))") }
        if let finished { lines.append("Finished: \(finished)") }
        lines.append("Folder: \(copies)")
        lines.append("Receipt: \(url.lastPathComponent)")
        return lines
    }
}

/// Live Tech Support: a message to the support WhatsApp, written by the app
/// and sent by the photographer. A WhatsApp link carries text only, so the
/// receipt itself goes separately (Share or drag from Finder).
public enum Support {
    /// The newest receipt in the card folders directly inside `root`, by when it was written.
    public static func latestReceipt(under root: URL) -> URL? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return nil }
        var newest: (url: URL, date: Date)?
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where Receipt.isReceipt(name) {
                let url = folder.appendingPathComponent(name)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || date > newest!.date { newest = (url, date) }
            }
        }
        return newest?.url
    }

    /// Reads the summary lines a receipt ends with; nil when it has none.
    public static func summary(ofReceipt url: URL) -> ReceiptSummary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        // From the end, up to the blank line before the summary (the file itself ends with a newline).
        for line in text.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            if line.isEmpty { break }
            guard let comma = line.firstIndex(of: ",") else { continue }
            var value = String(line[line.index(after: comma)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            fields[String(line[..<comma])] = value
        }
        guard let card = fields["Card"], let files = fields["Files"].flatMap({ Int($0) }) else { return nil }
        return ReceiptSummary(url: url, card: card, files: files, totalBytes: fields["Total bytes"].flatMap { Int64($0) } ?? 0,
                              importNumber: fields["Import number"].flatMap { Int($0) }, finished: fields["Finished"],
                              copies: fields["Copies"] ?? "")
    }

    /// The message as it's sent: the photographer's words first, then what
    /// the app knows, then the latest receipt.
    public static func message(problem: String, details: [String], receipt: ReceiptSummary?) -> String {
        var parts = [problem.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !details.isEmpty { parts.append("— From Card Ingest —\n" + details.joined(separator: "\n")) }
        if let receipt { parts.append("— Latest receipt —\n" + receipt.lines.joined(separator: "\n")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The number to write to: the settings file's, when it holds one, else
    /// the one `make-app.sh` built into the app.
    public static func number(setting: String, built: String?) -> String {
        setting.filter(\.isNumber).count >= 8 ? setting : built ?? ""
    }

    /// A link that opens WhatsApp with the message written to `number`. Nil
    /// when the number has too few digits to be one (it needs its country code).
    public static func whatsAppURL(number: String, text: String) -> URL? {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 8 else { return nil }
        // Everything but letters, digits and -._~ encoded, so a + or & in the message stays in it.
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: plain) else { return nil }
        return URL(string: "https://wa.me/\(digits)?text=\(encoded)")
    }
}
