import AppKit
import CardIngestCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct CardIngestApp: App {
    @State private var model = SettingsModel()

    init() {
        // Needed so the window comes to the front when launched from Terminal.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Card Ingest") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 300)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Waiting for a card…")
                .font(.title2)

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
