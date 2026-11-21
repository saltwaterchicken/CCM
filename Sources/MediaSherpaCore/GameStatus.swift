import Foundation

/// How far one card's copy has got, for the hidden game's status window.
public struct CopyProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case preparing = "READING CARD"
        case copying = "COPY + VERIFY"
        case waiting = "WAITING FOR YOU"
        case clearing = "TO CARD TRASH"
        case done = "ALL DONE"
        case failed = "FAILED"

        var isBusy: Bool { self == .preparing || self == .copying || self == .clearing || self == .waiting }
    }

    public var cardName: String
    public var stage: Stage
    /// When copying began (after reading the card).
    public var started: Date?
    /// Of the whole job, copy and verify together (0…1).
    public var fraction: Double
    /// The bytes being copied from the card.
    public var bytes: Int64
    public var filesDone: Int
    public var filesTotal: Int
    /// The last file verified, as it's named in the card folder.
    public var lastFile: String?
    /// Why it failed.
    public var problem: String?

    public init(cardName: String, stage: Stage, started: Date? = nil, fraction: Double = 0, bytes: Int64 = 0,
                filesDone: Int = 0, filesTotal: Int = 0, lastFile: String? = nil, problem: String? = nil) {
        self.cardName = cardName
        self.stage = stage
        self.started = started
        self.fraction = fraction
        self.bytes = bytes
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.lastFile = lastFile
        self.problem = problem
    }
}

/// What the game's status window shows, sent to it as JSON
/// (`AzimovsRebellion.setStatus`), in the shape the game reads: the same as
/// FrameDrop's Uploads window in CC Frame Puller.
public enum GameStatus {
    public struct Status: Codable, Equatable, Sendable {
        /// The window's title.
        public var title: String
        /// Files still to copy; more than 0 while a card is busy (the window opens itself then).
        public var active: Int
        /// Cards finished, once nothing is busy ("ALL DONE").
        public var finished: Int
        public var file: String
        public var stage: String
        /// This card (0…1).
        public var filePct: Double
        /// Every busy card together (0…1).
        public var totalPct: Double
        public var speed: String
        public var eta: String
        /// Why it failed, shown in place of the time left.
        public var reason: String
    }

    public static let title = "Card Progress"

    /// The card being copied (or the last one), with speed and time left.
    public static func status(_ cards: [CopyProgress], now: Date = Date()) -> Status {
        let busy = cards.filter(\.stage.isBusy)
        guard let card = busy.first(where: { $0.stage == .copying }) ?? busy.first ?? cards.last else {
            return Status(title: title, active: 0, finished: 0, file: "", stage: "IDLE", filePct: 0, totalPct: 0,
                          speed: "", eta: "", reason: "")
        }
        var speed = "", eta = ""
        if card.stage == .copying, let started = card.started {
            let elapsed = now.timeIntervalSince(started)
            if elapsed >= 2, card.fraction > 0 {
                // Copy and verify read and write the card's bytes more than once;
                // this is how fast the card's own bytes are getting through.
                let bytesPerSecond = card.fraction * Double(card.bytes) / elapsed
                speed = "\(Int((bytesPerSecond * 8 / 1_000_000).rounded())) Mb/s"
                if card.fraction >= 0.02, card.fraction < 1 {
                    eta = timeLeft(elapsed * (1 - card.fraction) / card.fraction)
                }
            }
        }
        let progress = { (c: CopyProgress) -> Double in
            c.stage == .done || c.stage == .waiting || c.stage == .clearing ? 1 : c.fraction
        }
        let filesLeft = busy.reduce(0) { $0 + max(0, $1.filesTotal - $1.filesDone) }
        let total = busy.isEmpty ? progress(card) : busy.map(progress).reduce(0, +) / Double(busy.count)
        return Status(title: title,
                      active: busy.isEmpty ? 0 : max(1, filesLeft),
                      finished: busy.isEmpty ? cards.filter { $0.stage == .done }.count : 0,
                      file: card.stage == .copying ? (card.lastFile ?? card.cardName) : card.cardName,
                      stage: card.stage.rawValue,
                      filePct: progress(card), totalPct: total,
                      speed: speed, eta: eta, reason: card.stage == .failed ? (card.problem ?? "") : "")
    }

    public static func json(_ cards: [CopyProgress], now: Date = Date()) -> String {
        let data = (try? JSONEncoder().encode(status(cards, now: now))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// "ABOUT 3 MIN LEFT", or "UNDER A MINUTE LEFT".
    public static func timeLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 60 { return "UNDER A MINUTE LEFT" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 120 { return "ABOUT \(minutes) MIN LEFT" }
        let hours = (Double(minutes) / 60).rounded()
        return "ABOUT \(Int(hours)) HOURS LEFT"
    }
}

/// The game's "Send Earth a Postcard": a JPEG it hands over as a data URL,
/// saved in the card folder.
public enum Postcard {
    public enum SaveError: LocalizedError, Equatable {
        case notAnImage
        case noFolder
        public var errorDescription: String? {
            switch self {
            case .notAnImage: "The postcard wasn't a picture"
            case .noFolder: "No card folder yet: copy a card first"
            }
        }
    }

    /// Writes the picture into `folder` and returns where. Never overwrites:
    /// a name already there gets " 2", " 3"… before the extension.
    public static func save(dataURL: String, fileName: String, in folder: URL) throws -> URL {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])), !data.isEmpty
        else { throw SaveError.notAnImage }
        let name = safeName(fileName)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Just a file name (no folders), not hidden, ending in .jpg.
    static func safeName(_ fileName: String) -> String {
        var name = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Postcard" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext != "jpg" && ext != "jpeg" { name += ".jpg" }
        return name
    }
}
