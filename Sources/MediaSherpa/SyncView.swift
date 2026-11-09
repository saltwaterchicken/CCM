import MediaSherpaCore
import SwiftUI

enum SyncProblem: Error, LocalizedError {
    case notConnected

    var errorDescription: String? {
        "The server isn't connected. Connect to it in Finder (Go › Connect to Server), then Sync again."
    }
}

/// The Sync With Server button, at the right of the Server panel's first
/// line, with the cards it covers under it: every card in the panel's list,
/// and the one in the grid. Then the summary to confirm. What it's doing shows
/// below the light (SyncStatusView).
struct SyncButton: View {
    var model: GridModel

    var body: some View {
        let ready = model.syncReady.map(\.lastPathComponent)
        let waiting = model.backupsRunning
        if model.serverRoot != nil, !ready.isEmpty || !waiting.isEmpty {
            VStack(alignment: .trailing, spacing: 2) {
                Button(ready.count > 1 ? "Sync \(ready.count) Cards With Server" : "Sync With Server") { model.compareWithServer() }
                    .disabled(!model.licensed || ready.isEmpty || model.sync != .idle)
                    .help(ready.isEmpty ? "Waiting for the backup to finish"
                          : "Sends each card's sidecars, exports and anything the backup missed to the server. "
                          + "Nothing there is deleted or replaced; you see what it will do first.")
                Text(names(ready, waiting: waiting))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sheet(isPresented: Binding(get: { if case .confirm = model.sync { true } else { false } },
                                        set: { if !$0, case .confirm = model.sync { model.dismissSync() } })) {
                if case let .confirm(plans, waiting) = model.sync { SyncConfirmView(model: model, plans: plans, waiting: waiting) }
            }
        }
    }

    private func names(_ ready: [String], waiting: [String]) -> String {
        (ready + waiting.map { "\($0) (after its backup)" }).joined(separator: "\n")
    }
}

/// Cards with clips waiting for Save to Clips, which aren't on the server until
/// it's pressed. Load brings the card back to the grid to do it.
struct WaitingClipsView: View {
    var model: GridModel

    var body: some View {
        if !model.waitingClips.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.waitingClips, id: \.folder) { card in
                    HStack {
                        Label("\(card.clips) \(card.clips == 1 ? "clip" : "clips") from \(card.folder.lastPathComponent) not on the Server yet: press Save to Clips",
                              systemImage: "film")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if model.folder?.standardizedFileURL != card.folder.standardizedFileURL {
                            Button("Load") { model.load(card.folder) }
                        }
                    }
                }
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
        case let .done(results):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(results.count == 1 ? "Sync finished" : "Sync finished for \(results.count) cards:").font(.callout.weight(.semibold))
                    Spacer()
                    Button("OK") { model.dismissSync() }
                }
                // Cards in the list below show their own result there.
                let listed = Set(model.backups?.entries.map(\.folderName) ?? [])
                ForEach(results, id: \.name) { result in
                    if !listed.contains(result.name) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name).font(.callout.weight(.semibold))
                            SyncResultLine(result: result)
                        }
                    }
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

/// One card's Sync result, under its name.
struct SyncResultLine: View {
    let result: GridModel.CardSync

    var body: some View {
        let outcome = result.outcome
        VStack(alignment: .leading, spacing: 4) {
            if outcome.problems.isEmpty && result.cantUpdate.isEmpty {
                Label(outcome.added == 0 ? "Synced: the server already had everything."
                      : "Synced: \(outcome.added) files added to the server and checked.",
                      systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Label("Synced \(outcome.added) files. \(outcome.problems.count + result.cantUpdate.count) need the admin.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                DisclosureGroup("Which files") {
                    FileList(lines: outcome.problems + result.cantUpdate.map { "\($0): already on the server and changed here since" })
                }
                .font(.caption)
            }
        }
    }
}

/// The summary to confirm before Sync writes anything: card by card.
struct SyncConfirmView: View {
    var model: GridModel
    let plans: [ServerSync.Plan]
    let waiting: [String]

    var body: some View {
        let adds = plans.reduce(0) { $0 + $1.adds.count }
        VStack(alignment: .leading, spacing: 12) {
            Text(plans.count == 1 ? "Sync \(plans[0].localFolder.lastPathComponent) with the server"
                 : "Sync \(plans.count) cards with the server").font(.title3.bold())
            if let root = plans.first?.serverFolder.deletingLastPathComponent() {
                Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plans, id: \.localFolder) { card($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            if !waiting.isEmpty {
                Label("Not included yet, as its backup is still sending: \(waiting.joined(separator: ", ")). Sync again once it's done.",
                      systemImage: "clock").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing on the server is deleted or replaced.").font(.callout.weight(.semibold))
            HStack {
                Spacer()
                Button(adds == 0 ? "Close" : "Cancel") { model.dismissSync() }
                    .keyboardShortcut(.cancelAction)
                if adds > 0 {
                    Button("Sync \(adds) Files") { model.runSync(plans) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Theme.window)
    }

    private func card(_ plan: ServerSync.Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.localFolder.lastPathComponent).font(.headline)
            if plan.isEmpty, plan.heldClips == 0 {
                Label("The server already has everything from this card.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if !plan.isEmpty {
                Text("Adds \(plan.adds.count) \(plan.adds.count == 1 ? "file" : "files"):")
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
            if plan.heldClips > 0 {
                Label("Not sending \(plan.heldClips) \(plan.heldClips == 1 ? "clip" : "clips"): waiting for Save to Clips.", systemImage: "film")
                    .foregroundStyle(.orange)
            }
            if !plan.cantUpdate.isEmpty {
                Label("Can't update \(plan.cantUpdate.count) \(plan.cantUpdate.count == 1 ? "file" : "files"): already on the server "
                      + "and changed here since. To send them again, ask the admin to delete the server's copies, then Sync.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                FileList(lines: plan.cantUpdate)
            }
        }
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
