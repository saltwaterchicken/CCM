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
        let model = SettingsModel()
        _model = State(initialValue: model)
        _watcher = State(initialValue: CardWatcher(settings: model.settings))
    }

    var body: some Scene {
        WindowGroup("Card Ingest") {
            ContentView(model: model, watcher: watcher)
                .frame(minWidth: 560, minHeight: 420)
                .onChange(of: model.settings) { _, settings in watcher.update(settings: settings) }
        }
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

            GroupBox("Settings") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("File", value: model.fileURL.path)
                    LabeledContent("Job", value: model.settings.jobName)
                    LabeledContent("Copies go to", value: model.destinationPreview)
                    LabeledContent("Backup", value: model.settings.backupRootURL?.path ?? "None")
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
                .textSelection(.enabled)
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
                            Button("Copy") {}
                                .disabled(true)
                                .help("Copying arrives in the next step.")
                        }
                        .padding(4)
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
}
