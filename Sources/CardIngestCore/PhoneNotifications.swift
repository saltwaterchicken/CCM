import Foundation

/// Where alerts go when a card finishes copying, its backup reaches the
/// server, or Sync With Server is done: an ntfy topic (https://ntfy.sh), which
/// the ntfy iPhone app subscribes to and the iPhone passes on to the Watch.
/// Off while the topic is empty. Only changed by editing the settings file.
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// The ntfy server. ntfy.sh is free; a server of your own works the same.
    public var server: String
    /// The topic the phone subscribes to. Anyone who knows it can read the
    /// alerts, so it should be long and hard to guess, like a password.
    public var topic: String

    public init(server: String = "https://ntfy.sh", topic: String = "") {
        self.server = server
        self.topic = topic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? d.topic
    }

    /// The server's address, or nil when notifications are off (no topic) or it isn't a web address.
    public var serverURL: URL? {
        let topic = topic.trimmingCharacters(in: .whitespaces)
        var server = server.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty, !server.isEmpty else { return nil }
        if !server.contains("://") { server = "https://" + server }
        guard let url = URL(string: server), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }

    public var isOn: Bool { serverURL != nil }
}

/// One alert for the phone.
public struct PhoneNotification: Equatable, Sendable {
    public var title: String
    public var message: String
    /// Something went wrong: the phone buzzes harder and shows a warning sign.
    public var isProblem: Bool

    public init(title: String, message: String, isProblem: Bool = false) {
        self.title = title
        self.message = message
        self.isProblem = isProblem
    }

    // MARK: What each event says

    /// A card copied and verified on this Mac.
    public static func cardCopied(folder: String, cardName: String, files: Int, bytes: Int64,
                                  alreadyImported: Int = 0, sidecarProblems: Int = 0) -> PhoneNotification {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var message = "\(count(files, "file")) (\(size)) from \(cardName) copied and verified."
        if alreadyImported > 0 { message += " \(count(alreadyImported, "file")) already imported, skipped." }
        if sidecarProblems > 0 { message += " \(count(sidecarProblems, "sidecar")) couldn't be written." }
        return PhoneNotification(title: "Card copied: \(folder)", message: message, isProblem: sidecarProblems > 0)
    }

    /// Everything on the card was already imported.
    public static func nothingNew(cardName: String, alreadyImported: Int) -> PhoneNotification {
        PhoneNotification(title: "Nothing new on \(cardName)",
                          message: "All \(count(alreadyImported, "file")) were already imported.")
    }

    public static func copyFailed(cardName: String, reason: String) -> PhoneNotification {
        PhoneNotification(title: "Copy failed: \(cardName)", message: reason, isProblem: true)
    }

    /// A card's backup, running beside the copy, finished.
    public static func backupDone(folder: String, sent: Int, alreadyThere: Int, queued: Int,
                                  problems: Int, wentAway: Bool) -> PhoneNotification {
        let reached = sent + alreadyThere
        if wentAway {
            return PhoneNotification(title: "Backup stopped: \(folder)",
                                     message: "The server went away: \(reached) of \(count(queued, "file")) reached it. Sync With Server will send the rest.",
                                     isProblem: true)
        }
        if problems > 0 {
            return PhoneNotification(title: "Backup problems: \(folder)",
                                     message: "\(problems) of \(count(queued, "file")) didn't reach the server safely.",
                                     isProblem: true)
        }
        return PhoneNotification(title: "On the server: \(folder)",
                                 message: "All \(count(reached, "file")) on the server and checked"
                                     + (alreadyThere > 0 ? " (\(alreadyThere) were already there)." : "."))
    }

    /// One card's part of a Sync With Server.
    public struct SyncedCard: Equatable, Sendable {
        public var name: String
        public var added: Int
        /// Files that need the admin: didn't go up, or changed here since.
        public var problems: Int

        public init(name: String, added: Int, problems: Int) {
            self.name = name
            self.added = added
            self.problems = problems
        }
    }

    public static func syncDone(_ cards: [SyncedCard]) -> PhoneNotification {
        let added = cards.reduce(0) { $0 + $1.added }
        let problems = cards.reduce(0) { $0 + $1.problems }
        let lines = cards.map { card in
            "\(card.name): " + (card.problems > 0 ? "\(card.added) added, \(card.problems) need the admin"
                                : card.added == 0 ? "already had everything" : "\(card.added) added")
        }
        let title = problems > 0 ? "Sync done, \(count(problems, "file")) \(problems == 1 ? "needs" : "need") the admin"
            : "Sync done: \(count(added, "file")) added"
        return PhoneNotification(title: title, message: lines.joined(separator: "\n"), isProblem: problems > 0)
    }

    public static let test = PhoneNotification(title: "Card Ingest",
                                               message: "Test notification. Alerts for copies and the server will arrive like this.")

    private static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

/// Sends alerts to ntfy with one web request each, in the background. A
/// failure is only logged: alerts never hold up or stop a copy.
public struct PhoneNotifier: Sendable {
    public let settings: NotificationSettings

    public init(_ settings: NotificationSettings) {
        self.settings = settings
    }

    /// The request for one alert: JSON to the server's root, which carries any
    /// text (accents, emoji) in titles and card names. Nil when notifications are off.
    public func request(for notification: PhoneNotification) -> URLRequest? {
        guard let url = settings.serverURL else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "topic": settings.topic.trimmingCharacters(in: .whitespaces),
            "title": notification.title,
            "message": notification.message,
        ]
        if notification.isProblem {
            body["priority"] = 4
            body["tags"] = ["warning"]
        } else {
            body["tags"] = ["white_check_mark"]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Sends it and doesn't wait. `done` hears nil when ntfy took it, or why not.
    public func send(_ notification: PhoneNotification, done: (@Sendable (String?) -> Void)? = nil) {
        guard let request = request(for: notification) else {
            done?("Notifications are off: there's no topic in the settings file.")
            return
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let problem: String?
            if let error {
                problem = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                problem = "The notification server answered \(http.statusCode)."
            } else {
                problem = nil
            }
            if let problem { NSLog("Card Ingest: phone notification not sent: %@", problem) }
            done?(problem)
        }.resume()
    }
}
