import Foundation

/// The values a pattern can draw on. Fields that aren't known yet stay nil and
/// render as "Unknown".
public struct TemplateValues: Sendable {
    public var date: Date
    public var job: String
    public var camera: String?
    public var serial: String?
    public var original: String?
    public var sequence: Int?

    public init(date: Date, job: String, camera: String? = nil, serial: String? = nil,
                original: String? = nil, sequence: Int? = nil) {
        self.date = date
        self.job = job
        self.camera = camera
        self.serial = serial
        self.original = original
        self.sequence = sequence
    }
}

public enum TemplateError: Error, LocalizedError, Equatable {
    case unknownField(String)
    case unclosedBrace
    case badSequenceWidth(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownField(name):
            return "The pattern uses {\(name)}, which isn't a field I know. Available: date, job, camera, serial, original, seq."
        case .unclosedBrace:
            return "The pattern has a { without a matching }."
        case let .badSequenceWidth(arg):
            return "{seq:\(arg)} needs a number of digits, like {seq:4}."
        }
    }
}

/// Fills in patterns such as `{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}`.
///
/// Date formats use YYYY, YY, MM, DD, hh, mm and ss. A `/` written in the
/// pattern itself makes a subfolder; a `/` or `:` inside a value (a job named
/// "A/B", say) is replaced with `-` so it can't create folders by accident.
public struct NameTemplate: Sendable {
    public let pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    public func render(_ values: TemplateValues, calendar: Calendar = .current) throws -> String {
        var output = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { throw TemplateError.unclosedBrace }
            let token = rest[rest.index(after: open)..<close]
            output += try field(token, values, calendar)
            rest = rest[rest.index(after: close)...]
        }
        if rest.contains("}") { throw TemplateError.unclosedBrace }
        output += rest
        return output
    }

    private func field(_ token: Substring, _ v: TemplateValues, _ calendar: Calendar) throws -> String {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : nil
        switch name {
        case "date":
            return Self.formatDate(v.date, arg ?? "YYYY-MM-DD", calendar)
        case "job":
            return Self.clean(v.job.isEmpty ? "Untitled" : v.job)
        case "camera":
            return Self.clean(v.camera ?? "Unknown")
        case "serial":
            return Self.clean(v.serial ?? "Unknown")
        case "original":
            let original = v.original.map { ($0 as NSString).deletingPathExtension } ?? "Unknown"
            return Self.clean(original)
        case "seq":
            let width: Int
            if let arg {
                guard let n = Int(arg), (1...9).contains(n) else { throw TemplateError.badSequenceWidth(arg) }
                width = n
            } else {
                width = 4
            }
            let digits = String(v.sequence ?? 1)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        default:
            throw TemplateError.unknownField(String(token))
        }
    }

    static func formatDate(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ n: Int?, _ width: Int) -> String {
            let s = String(n ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let replacements: [(String, String)] = [
            ("YYYY", pad(c.year, 4)),
            ("YY", pad((c.year ?? 0) % 100, 2)),
            ("MM", pad(c.month, 2)),
            ("DD", pad(c.day, 2)),
            ("hh", pad(c.hour, 2)),
            ("mm", pad(c.minute, 2)),
            ("ss", pad(c.second, 2)),
        ]
        var output = ""
        var rest = Substring(format)
        outer: while !rest.isEmpty {
            for (key, value) in replacements where rest.hasPrefix(key) {
                output += value
                rest = rest.dropFirst(key.count)
                continue outer
            }
            output.append(rest.removeFirst())
        }
        return clean(output)
    }

    /// Makes a value safe to use inside one file or folder name.
    static func clean(_ value: String) -> String {
        var s = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Unknown" : s
    }
}

extension IngestSettings {
    /// The folder this card's files will go into, for example
    /// ~/Pictures/Card Ingest/2026/2026-10-14_Smith Wedding.
    public func destinationFolder(for date: Date, root: URL? = nil, calendar: Calendar = .current) throws -> URL {
        let relative = try NameTemplate(folderPattern).render(TemplateValues(date: date, job: jobName), calendar: calendar)
        var url = root ?? destinationRootURL
        for component in relative.split(separator: "/") where !component.isEmpty && component != "." && component != ".." {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        return url
    }
}
