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
        _watcher = State(initialValue: CardWatcher(settings: model.settings))
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

    var destinationPreview: String {
        do {
            return try settings.destinationFolder(for: Date()).path
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

/// Job name, destination and backup. Every change is saved to the settings file.
struct JobPanel: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Job name").gridColumnAlignment(.trailing)
                TextField("e.g. Smith Wedding", text: Binding(
                    get: { model.settings.jobName },
                    set: { name in model.change { $0.jobName = name } }))
                    .textFieldStyle(.roundedBorder)
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
            } else {
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
        } else {
            Button("Copy") { watcher.startCopy(card) }
                .keyboardShortcut(.defaultAction)
                .disabled(card.files?.isEmpty ?? true)
        }
    }

    @ViewBuilder
    private func copyStatus(_ card: DetectedVolume) -> some View {
        switch watcher.copyStates[card.id] {
        case let .copying(fraction):
            ProgressView(value: fraction) {
                Text("Copying and verifying… \(Int(fraction * 100))%")
            }
        case let .done(report):
            VStack(alignment: .leading, spacing: 4) {
                Label("Copied and verified \(report.files.count) files (\(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file))). Nothing on the card was changed.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                ForEach(report.destinationFolders, id: \.self) { folder in
                    Text(folder.path).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    // Opens the main copy's folder itself, so the photos are right there.
                    Button("Show Imported Files") {
                        if let folder = report.destinationFolders.first { NSWorkspace.shared.open(folder) }
                    }
                    Button("Show Receipt in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(report.receipts)
                    }
                }
            }
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
}
