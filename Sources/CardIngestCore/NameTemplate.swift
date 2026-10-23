import Foundation

/// The values a pattern can draw on. The capture date and the camera's file
/// name only exist for files, so a folder pattern leaves them nil.
public struct TemplateValues: Sendable {
    /// The day of the import.
    public var today: Date
    /// The import counter, `{iseq}`.
    public var importNumber: Int
    /// When the picture or clip was taken.
    public var capture: Date?
    /// The camera's own file name, with or without its extension, e.g. "IMG_1234.CR3".
    public var originalName: String?

    public init(today: Date, importNumber: Int, capture: Date? = nil, originalName: String? = nil) {
        self.today = today
        self.importNumber = importNumber
        self.capture = capture
        self.originalName = originalName
    }
}

public enum TemplateError: Error, LocalizedError, Equatable {
    case unknownToken(String)
    case unclosedBrace
    /// A file-only token, such as a capture date, used where there is no file.
    case onlyInFileNames(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownToken(name):
            return "The pattern uses {\(name)}, which isn't a token I know. Available: "
                + NameTemplate.tokenNames.map { "{\($0)}" }.joined(separator: ", ") + "."
        case .unclosedBrace:
            return "The pattern has a { without a matching }."
        case let .onlyInFileNames(name):
            return "{\(name)} comes from each picture, so it can only be used in file names. "
                + "For the folder, use the import date: {todayyear4}, {todayyear2}, {todaymonth0}, {todayday0}."
        }
    }
}

/// Fills in Photo Mechanic-style patterns such as
/// `{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}`. Text outside braces is
/// kept as typed. The result is always one name: a `/` or `:` becomes `-`, so a
/// pattern can't create subfolders or escape the destination.
public struct NameTemplate: Sendable {
    public let pattern: String

    /// Every token, in the order they're listed to the photographer.
    public static let tokenNames = [
        "todayyear4", "todayyear2", "todaymonth0", "todayday0",
        "year4", "year2", "month0", "day0", "hour0", "minute0", "second0",
        "iseq", "frame4", "filename",
    ]

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    public func render(_ values: TemplateValues, calendar: Calendar = .current) throws -> String {
        var output = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { throw TemplateError.unclosedBrace }
            let token = String(rest[rest.index(after: open)..<close])
            output += try value(of: token, values, calendar)
            rest = rest[rest.index(after: close)...]
        }
        if rest.contains("}") { throw TemplateError.unclosedBrace }
        output += rest
        return Self.clean(output)
    }

    /// Checks the pattern for typos without needing real values.
    public func validate(forFiles: Bool) throws {
        let sample = TemplateValues(today: Date(), importNumber: 1,
                                    capture: forFiles ? Date() : nil,
                                    originalName: forFiles ? "IMG_0001.CR3" : nil)
        _ = try render(sample)
    }

    private func value(of token: String, _ v: TemplateValues, _ calendar: Calendar) throws -> String {
        let name = token.lowercased()
        func part(_ component: Calendar.Component, of date: Date?, width: Int) throws -> String {
            guard let date else { throw TemplateError.onlyInFileNames(token) }
            var n = calendar.component(component, from: date)
            if component == .year && width == 2 { n %= 100 }
            return Self.pad(n, width)
        }
        switch name {
        case "todayyear4": return try part(.year, of: v.today, width: 4)
        case "todayyear2": return try part(.year, of: v.today, width: 2)
        case "todaymonth0": return try part(.month, of: v.today, width: 2)
        case "todayday0": return try part(.day, of: v.today, width: 2)
        case "year4": return try part(.year, of: v.capture, width: 4)
        case "year2": return try part(.year, of: v.capture, width: 2)
        case "month0": return try part(.month, of: v.capture, width: 2)
        case "day0": return try part(.day, of: v.capture, width: 2)
        case "hour0": return try part(.hour, of: v.capture, width: 2)
        case "minute0": return try part(.minute, of: v.capture, width: 2)
        case "second0": return try part(.second, of: v.capture, width: 2)
        case "iseq": return Self.pad(v.importNumber, 3)
        case "frame4":
            guard let original = v.originalName else { throw TemplateError.onlyInFileNames(token) }
            return Self.frameNumber(original)
        case "filename":
            guard let original = v.originalName else { throw TemplateError.onlyInFileNames(token) }
            return (original as NSString).deletingPathExtension
        default:
            throw TemplateError.unknownToken(token)
        }
    }

    /// The last 4 digits of the number in a camera's file name: IMG_1234 and
    /// DSC01234 both give 1234, C0001 gives 0001, a name without digits 0000.
    static func frameNumber(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let digits = base.reversed().drop { !$0.isASCIIDigit }.prefix { $0.isASCIIDigit }
        return pad(Int(String(digits.prefix(4).reversed())) ?? 0, 4)
    }

    static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// Makes a value safe to use as one file or folder name.
    static func clean(_ value: String) -> String {
        var s = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Unknown" : s
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
