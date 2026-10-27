import CardIngestCore
import SwiftUI

/// Each card's backup to the server, newest first: running beside the local
/// copy, finished, or waiting for Sync With Server.
@MainActor
@Observable
final class ServerBackups {
    struct Entry: Identifiable {
        let id: UUID
        let cardName: String
        let folderName: String
        /// Nil until the job starts; stays nil when the server wasn't there.
        var status: ServerBackupJob.Status?
        /// Why it didn't start.
        var notStarted: String?
    }

    private(set) var entries: [Entry] = []

    /// Starts showing a card's backup. Its updates can arrive first, so
    /// whichever comes first makes the entry.
    func begin(id: UUID, cardName: String, folderName: String, notStarted: String?) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = Entry(id: id, cardName: cardName, folderName: folderName,
                                   status: entries[index].status, notStarted: notStarted)
        } else {
            entries.insert(Entry(id: id, cardName: cardName, folderName: folderName, notStarted: notStarted), at: 0)
            entries = Array(entries.prefix(5))
        }
    }

    func update(_ id: UUID, _ status: ServerBackupJob.Status) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = status
        } else {
            entries.insert(Entry(id: id, cardName: "", folderName: "", status: status), at: 0)
        }
    }

    var isEmpty: Bool { entries.isEmpty }
}

struct BackupsView: View {
    var backups: ServerBackups

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(backups.entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.folderName).font(.callout.weight(.semibold))
                    if let reason = entry.notStarted {
                        Label("Not backed up: \(reason) Sync With Server can send it later.", systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                    } else if let status = entry.status {
                        if !status.finished {
                            ProgressView(value: Double(status.handled), total: Double(max(status.queued, 1)))
                            Text("Sending to the server: \(status.handled) of \(status.queued)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else if status.problems.isEmpty {
                            Label(done(status), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                        if status.finished, !status.problems.isEmpty {
                            Label(status.wentAway
                                  ? "The server went away: \(status.sent + status.alreadyThere) of \(status.queued) files reached it. Sync With Server can send the rest."
                                  : "\(status.problems.count) of \(status.queued) files didn't reach the server safely.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !status.problems.isEmpty, !status.wentAway {
                            DisclosureGroup("Which files") {
                                ForEach(status.problems.prefix(20), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                                if status.problems.count > 20 { Text("and \(status.problems.count - 20) more").font(.caption) }
                            }
                            .font(.caption)
                        }
                        if let problem = status.receiptProblem {
                            Text("Couldn't write the receipt on the server: \(problem)").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func done(_ status: ServerBackupJob.Status) -> String {
        let total = status.sent + status.alreadyThere
        return "All \(total) files on the server and checked" + (status.alreadyThere > 0 ? " (\(status.alreadyThere) were already there)." : ".")
    }
}
