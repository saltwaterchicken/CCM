import CardIngestCore
import SwiftUI

enum SyncProblem: Error, LocalizedError {
    case notConnected

    var errorDescription: String? {
        "The server isn't connected. Connect to it in Finder (Go › Connect to Server), then Sync again."
    }
}

/// The Sync With Server button for the card in the grid, at the right of the
/// Server panel's first line, with the card's name under it; and the summary
/// to confirm. What it's doing shows below the light (SyncStatusView).
struct SyncButton: View {
    var model: GridModel

    var body: some View {
        if let folder = model.folder, model.serverRoot != nil {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Sync With Server") { model.compareWithServer() }
                    .disabled(model.backupRunning || model.sync != .idle)
                    .help(model.backupRunning ? "Waiting for this card's backup to finish"
                          : "Sends this card's sidecars, exports and anything the backup missed to the server. "
                          + "Nothing there is deleted or replaced; you see what it will do first.")
                Text(folder.lastPathComponent + (model.backupRunning ? " (after its backup)" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .sheet(isPresented: Binding(get: { if case .confirm = model.sync { true } else { false } },
                                        set: { if !$0, case .confirm = model.sync { model.dismissSync() } })) {
                if case let .confirm(plan) = model.sync { SyncConfirmView(model: model, plan: plan) }
            }
        }
    }
}

/// What Sync With Server is doing.
struct SyncStatusView: View {
    var model: GridModel

    var body: some View {
        switch model.sync {
        case .idle, .confirm:
            EmptyView()
        case .comparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Comparing with the server…").foregroundStyle(.secondary)
            }
        case let .syncing(done, total):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                Text("Syncing with the server: \(done) of \(total)").foregroundStyle(.secondary).monospacedDigit()
            }
        case let .done(outcome, cantUpdate):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if outcome.problems.isEmpty && cantUpdate.isEmpty {
                        Label(outcome.added == 0 ? "The server already has everything." : "Synced: \(outcome.added) files added to the server and checked.",
                              systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Synced \(outcome.added) files. \(outcome.problems.count + cantUpdate.count) need the admin.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("OK") { model.dismissSync() }
                }
                if !outcome.problems.isEmpty || !cantUpdate.isEmpty {
                    DisclosureGroup("Which files") {
                        FileList(lines: outcome.problems + cantUpdate.map { "\($0): already on the server and changed here since" })
                    }
                    .font(.caption)
                }
            }
        case let .failed(message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("OK") { model.dismissSync() }
            }
        }
    }
}

/// The summary to confirm before Sync writes anything.
struct SyncConfirmView: View {
    var model: GridModel
    let plan: ServerSync.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync \(plan.localFolder.lastPathComponent) with the server").font(.title3.bold())
            Text(plan.serverFolder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if plan.isEmpty {
                Label("The server already has everything from this card.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Adds \(plan.adds.count) \(plan.adds.count == 1 ? "file" : "files") to the server:")
                VStack(alignment: .leading, spacing: 2) {
                    if plan.addedOriginals > 0 { Text("• \(plan.addedOriginals) photos, clips and receipts the backup didn't send") }
                    if plan.addedSidecars > 0 { Text("• \(plan.addedSidecars) sidecars with stars and keywords") }
                    if plan.addedExports > 0 { Text("• \(plan.addedExports) exported JPEGs (\(ServerSync.exportFolderPrefix))") }
                }
                .padding(.leading, 8)
            }
            if plan.unchanged > 0 {
                Text("Already on the server: \(plan.unchanged).").foregroundStyle(.secondary)
            }
            if !plan.cantUpdate.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Can't update \(plan.cantUpdate.count) \(plan.cantUpdate.count == 1 ? "file" : "files"): already on the server "
                          + "and changed here since. To send them again, ask the admin to delete the server's copies, then Sync.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    FileList(lines: plan.cantUpdate)
                }
            }
            Text("Nothing on the server is deleted or replaced.").font(.callout.weight(.semibold))
            HStack {
                Spacer()
                Button(plan.isEmpty ? "Close" : "Cancel") { model.dismissSync() }
                    .keyboardShortcut(.cancelAction)
                if !plan.isEmpty {
                    Button("Sync \(plan.adds.count) Files") { model.runSync(plan) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.window)
    }
}

/// Up to 12 file lines, then how many more.
struct FileList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(lines.prefix(12), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            if lines.count > 12 { Text("and \(lines.count - 12) more").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
