import AppKit
import CardIngestCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct CardIngestApp: App {
    @State private var model: SettingsModel
    @State private var watcher: CardWatcher

    init() {
        // Needed so the window comes to the front when launched from Terminal.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        // Always dark, like Capture One, whatever the Mac's own setting. This also
        // makes the Choose… panels and alerts dark.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let model = SettingsModel()
        _model = State(initialValue: model)
        _watcher = State(initialValue: CardWatcher(settings: model.settings) { plan in
            // Only a verified copy uses up the number, and the counter never goes down.
            model.change { $0.nextImportNumber = plan.nextImportNumber(after: $0.nextImportNumber) }
        } onTrashConfirmed: {
            model.change { $0.confirmTrashForFirstCards = max(0, $0.confirmTrashForFirstCards - 1) }
        })
    }

    var body: some Scene {
        WindowGroup("Card Ingest") {
            ContentView(model: model, watcher: watcher)
                .frame(minWidth: 600, minHeight: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
                .groupBoxStyle(PanelStyle())
                .preferredColorScheme(.dark)
                .onChange(of: model.settings) { _, settings in watcher.update(settings: settings) }
        }
    }
}

/// The dark, low-contrast look of pro photo apps like Capture One: a near-black
/// window with slightly lighter panels, so photos and status stand out.
enum Theme {
    static let window = Color(white: 0.09)
    static let panel = Color(white: 0.145)
    static let panelEdge = Color(white: 0.22)
}

/// A flat panel with a small grey heading, in place of the standard group box.
struct PanelStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelEdge, lineWidth: 1))
    }
}

/// Holds the settings currently in use and which file they came from.
@MainActor
@Observable
final class SettingsModel {
    var settings = IngestSettings()
    var fileURL = SettingsStore.defaultFileURL
    var errorMessage: String?

    init() {
        reload()
    }

    func reload() {
        do {
            settings = fileURL == SettingsStore.defaultFileURL
                ? try SettingsStore.loadOrCreate(at: fileURL)
                : try SettingsStore.load(from: fileURL)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useFile(_ url: URL) {
        fileURL = url
        reload()
    }

    func useDefaultFile() {
        useFile(SettingsStore.defaultFileURL)
    }

    /// Changes one setting and saves it straight to the file in use.
    func change(_ edit: (inout IngestSettings) -> Void) {
        var updated = settings
        edit(&updated)
        guard updated != settings else { return }
        settings = updated
        do {
            try SettingsStore.save(settings, to: fileURL)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The next card's folder, e.g. 2026-10-23-ES001, or what's wrong with the pattern.
    var folderPreview: Result<String, Error> {
        Result { try settings.cardFolderName() }
    }

    var destinationPreview: String {
        switch folderPreview {
        case let .success(name): settings.destinationRootURL.appendingPathComponent(name).path
        case let .failure(error): error.localizedDescription
        }
    }

    /// What a camera file called IMG_1234.CR3 taken today would become.
    var fileNamePreview: String {
        let values = TemplateValues(today: Date(), importNumber: settings.nextImportNumber,
                                    capture: Date(), originalName: "IMG_1234.CR3")
        do {
            return "IMG_1234.CR3 → " + (try NameTemplate(settings.renamePattern).render(values)) + ".CR3"
        } catch {
            return error.localizedDescription
        }
    }
}

struct ContentView: View {
    @Bindable var model: SettingsModel
    var watcher: CardWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardsView(watcher: watcher)

            GroupBox("Job") {
                JobPanel(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            GroupBox("Settings File") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.fileURL.path).textSelection(.enabled)
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.fileURL])
                        }
                        Button("Load Project Settings…", action: chooseFile)
                        Button("Use Default") { model.useDefaultFile() }
                        Button("Reload") { model.reload() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Spacer()
        }
        .padding(20)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.message = "Choose a project settings file"
        if panel.runModal() == .OK, let url = panel.url {
            model.useFile(url)
        }
    }
}

/// Folder name, import number, destination and backup. Every change is saved
/// to the settings file.
struct JobPanel: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Folder name").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. {todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}", text: Binding(
                        get: { model.settings.folderName },
                        set: { pattern in model.change { $0.folderName = pattern } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    switch model.folderPreview {
                    case let .success(name):
                        Text("Next card: \(name)").foregroundStyle(.secondary)
                    case let .failure(error):
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            GridRow {
                Text("Next import number")
                HStack {
                    TextField("1", value: Binding(
                        get: { model.settings.nextImportNumber },
                        set: { number in model.change { $0.nextImportNumber = max(1, number) } }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("{iseq}; goes up by one after each card copies and verifies")
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Destination")
                HStack {
                    Text(model.settings.destinationRoot)
                        .lineLimit(1).truncationMode(.middle)
                        .help(model.settings.destinationRootURL.path)
                    Spacer()
                    Button("Choose…") {
                        if let url = chooseFolder("Choose where cards are copied to", startingAt: model.settings.destinationRootURL) {
                            model.change { $0.destinationRoot = Self.displayPath(url) }
                        }
                    }
                }
            }
            GridRow {
                Text("Backup")
                HStack {
                    Text(model.settings.backupRootURL == nil ? "None (optional)" : model.settings.backupRoot)
                        .foregroundStyle(model.settings.backupRootURL == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if model.settings.backupRootURL != nil {
                        Button("Remove") { model.change { $0.backupRoot = "" } }
                    }
                    Button("Choose…") {
                        if let url = chooseFolder("Choose a second place to copy cards to, ideally another drive", startingAt: model.settings.backupRootURL) {
                            model.change { $0.backupRoot = Self.displayPath(url) }
                        }
                    }
                }
            }
            GridRow {
                Text("Copies go to")
                Text(model.destinationPreview)
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            GridRow {
                Text("File names")
                Text(model.fileNamePreview)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            GridRow {
                Text("When done").gridCellAnchor(.topTrailing)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Move the card's photos and videos to the card's Trash once every copy is verified", isOn: Binding(
                        get: { model.settings.trashAfterVerify },
                        set: { on in model.change { $0.trashAfterVerify = on } }))
                    if model.settings.trashAfterVerify {
                        let asks = model.settings.confirmTrashForFirstCards
                        Text((asks > 0 ? "Asks first for the next \(asks) \(asks == 1 ? "card" : "cards"). " : "")
                             + "Only cards with a DCIM folder. They stay in the card's Trash until you format the card in the camera.")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    Toggle("Eject the card when finished", isOn: Binding(
                        get: { model.settings.ejectWhenDone },
                        set: { on in model.change { $0.ejectWhenDone = on } }))
                }
                .toggleStyle(.checkbox)
            }
            if let problem = model.settings.folderProblem {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
    }

    private func chooseFolder(_ message: String, startingAt start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Keeps paths in the settings file short and readable, e.g. `~/Pictures/...`.
    private static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Shows the cards that are inserted, and why any other drives were left alone.
struct CardsView: View {
    var watcher: CardWatcher
    @State private var showIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if watcher.cards.isEmpty {
                Text("Waiting for a card…").font(.title2)
            }
            ForEach(watcher.ejected) { finished in
                GroupBox {
                    HStack(alignment: .top) {
                        Image(systemName: "eject.circle").font(.largeTitle)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(finished.cardName).font(.title3).bold()
                            Text("Ejected. You can take the card out.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dismiss") { watcher.dismissEjected(finished) }
                    }
                    .padding(4)
                    summary(finished)
                }
            }
            if !watcher.cards.isEmpty {
                ForEach(watcher.cards) { card in
                    GroupBox {
                        HStack(alignment: .top) {
                            Image(systemName: "sdcard").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.info.name).font(.title3).bold()
                                Text(card.info.url.path).foregroundStyle(.secondary)
                                if let error = card.scanError {
                                    Text("Couldn't read the card: \(error)").foregroundStyle(.red)
                                } else if let files = card.files {
                                    Text("\(files.count) camera files, \(ByteCountFormatter.string(fromByteCount: card.totalBytes, countStyle: .file))")
                                    if let message = card.check?.message {
                                        Label(message, systemImage: "clock.arrow.circlepath")
                                            .foregroundStyle(.orange)
                                    }
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            Spacer()
                            copyButton(card)
                        }
                        .padding(4)
                        copyStatus(card)
                    }
                }
            }
            DisclosureGroup("Other drives left alone (\(watcher.ignored.count))", isExpanded: $showIgnored) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(watcher.ignored) { volume in
                        if case let .ignored(reason) = volume.verdict {
                            Text("\(volume.info.name): \(reason)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func copyButton(_ card: DetectedVolume) -> some View {
        if watcher.copyStates[card.id]?.isCopying == true {
            Button("Stop") { watcher.stopCopy(card) }
        } else if watcher.copyStates[card.id]?.isBusy == true {
            EmptyView()
        } else {
            Button("Copy") { watcher.startCopy(card) }
                .keyboardShortcut(.defaultAction)
                .disabled(card.files?.isEmpty ?? true)
        }
    }

    @ViewBuilder
    private func copyStatus(_ card: DetectedVolume) -> some View {
        switch watcher.copyStates[card.id] {
        case .preparing:
            ProgressView { Text("Reading capture dates and choosing names…") }
        case let .copying(fraction):
            ProgressView(value: fraction) {
                Text("Copying and verifying… \(Int(fraction * 100))%")
            }
        case let .askTrash(finished, files):
            VStack(alignment: .leading, spacing: 6) {
                summary(finished)
                Label("Move the \(files.count) \(files.count == 1 ? "original" : "originals") on \(card.info.name) to the card's Trash? "
                      + "Every one has a verified copy. They stay in the card's Trash until you format the card in the camera.",
                      systemImage: "trash")
                HStack {
                    Button("Move to Trash") { watcher.confirmTrash(card) }
                        .keyboardShortcut(.defaultAction)
                    Button("Keep on Card") { watcher.keepOnCard(card) }
                }
            }
        case .clearing:
            ProgressView { Text("Moving the originals to the card's Trash…") }
        case let .done(finished):
            summary(finished)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Nothing on the card was changed. Copies that weren't verified were removed.")
                    .foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }

    /// What was copied, skipped, moved to the card's Trash and ejected.
    @ViewBuilder
    private func summary(_ finished: Finished) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let skipped = finished.check.alreadyImported.count
            if let report = finished.report {
                Label("Copied and verified \(report.files.count) files (\(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file))).",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if skipped > 0 {
                    Text("Skipped \(skipped) \(skipped == 1 ? "file" : "files") already imported earlier.")
                        .foregroundStyle(.secondary)
                }
                if let number = report.importNumber {
                    Text("Import number \(String(format: "%03d", number))").foregroundStyle(.secondary)
                }
                if finished.rated > 0 {
                    Text("Stars for \(finished.rated) \(finished.rated == 1 ? "photo are" : "photos are") in their .xmp sidecars "
                         + "(1 star, or what the camera set).")
                        .foregroundStyle(.secondary)
                }
                if !finished.starProblems.isEmpty {
                    Label("Couldn't write stars for \(finished.starProblems.count) \(finished.starProblems.count == 1 ? "photo" : "photos"): "
                          + finished.starProblems[0], systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(report.destinationFolders, id: \.self) { folder in
                    Text(folder.path).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Label(finished.check.message ?? "Nothing new on this card.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("Nothing was copied, and the import number wasn't used up.")
                    .foregroundStyle(.secondary)
            }
            if let trash = finished.trash {
                if trash.trashed > 0 {
                    Label("Moved \(trash.trashed) \(trash.trashed == 1 ? "original" : "originals") to the card's Trash. "
                          + "The space frees up once you format the card in the camera.", systemImage: "trash")
                }
                if !trash.failures.isEmpty {
                    Label("Left \(trash.failures.count) \(trash.failures.count == 1 ? "file" : "files") on the card:",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ForEach(trash.failures.prefix(5), id: \.self) { line in
                        Text(line).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if trash.failures.count > 5 {
                        Text("…and \(trash.failures.count - 5) more.").foregroundStyle(.secondary)
                    }
                }
            } else if let kept = finished.keptOnCard {
                Text(kept).foregroundStyle(.secondary)
            } else {
                Text("Nothing on the card was changed.").foregroundStyle(.secondary)
            }
            if let problem = finished.ejectProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                // Opens the main copy's folder itself, so the photos are right there.
                Button("Show Imported Files") {
                    if let folder = finished.report?.destinationFolders.first ?? finished.check.earlierFolders.last {
                        NSWorkspace.shared.open(folder)
                    }
                }
                if let report = finished.report {
                    Button("Show Receipt in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(report.receipts)
                    }
                }
            }
        }
    }
}
