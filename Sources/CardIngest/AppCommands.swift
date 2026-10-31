import CardIngestCore
import SwiftUI

/// The window's main actions in the menu bar too, with their shortcuts. Each
/// is enabled exactly when its button in the window is.
struct CardCommands: Commands {
    var settings: SettingsModel
    var watcher: CardWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if watcher.cards.isEmpty {
                Button("Copy Card") {}.disabled(true)
            }
            ForEach(Array(watcher.cards.enumerated()), id: \.element.id) { index, card in
                let state = watcher.copyStates[card.id]
                if state?.isCopying == true {
                    Button("Stop Copying \(card.info.name)") { watcher.stopCopy(card) }
                        .keyboardShortcut(index == 0 ? KeyboardShortcut(".", modifiers: .command) : nil)
                } else {
                    Button("Copy \(card.info.name)") { watcher.startCopy(card) }
                        .keyboardShortcut(index == 0 ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .disabled(!watcher.licensed || state?.isBusy == true || (card.files?.isEmpty ?? true))
                }
            }
            Divider()
            Button("Load Folder…") { watcher.grid.chooseFolderToLoad() }
                .keyboardShortcut("o", modifiers: .command)
            if let folder = watcher.grid.folder {
                Button("Show \(folder.lastPathComponent) in Finder") { NSWorkspace.shared.open(folder) }
            }
            Divider()
            Button("Load Project Settings…") { settings.chooseProjectFile() }
            Button("Use Default Settings") { settings.useDefaultFile() }
            Button("Reload Settings") { settings.reload() }
            Button("Show Settings File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([settings.fileURL]) }
        }

        CommandMenu("Photos") {
            let grid = watcher.grid
            let hasPhotos = !grid.grid.shots.isEmpty
            let count = grid.grid.toOpen.count
            Button("Open \(count) in \(grid.applicationName)") { grid.openInApplication() }
                .disabled(!hasPhotos || count == 0)
            Button(grid.keywordBarShown ? "Hide Keywords" : "Show Keywords") {
                grid.closeView()
                grid.toggleKeywordBar()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!hasPhotos)
            Divider()
            Button("Show All Photos") { grid.filter = .all }
                .disabled(!hasPhotos)
            if grid.rating.available {
                Button("Show Flagged by App (\(grid.grid.flaggedByApp))") { grid.filter = .appFlagged }
                    .disabled(!hasPhotos || (grid.grid.checks.isEmpty && !grid.isChecking))
                Button(grid.uncheckedCount > 0 ? "Check \(grid.uncheckedCount) Unrated Photos" : "Check Unrated Photos") {
                    grid.checkUnchecked()
                }
                .disabled(!hasPhotos || grid.isChecking || grid.uncheckedCount == 0)
                Divider()
                Button("Calibrate Auto-Rating…") { openWindow(id: "calibration") }
                Button("Calibrate on This Card…") {
                    grid.calibrationRequest = grid.folder
                    openWindow(id: "calibration")
                }
                .disabled(grid.folder == nil)
            }
            Divider()
            Button("Sync With Server") { grid.compareWithServer() }
                .disabled(!grid.licensed || grid.serverRoot == nil || grid.syncReady.isEmpty || grid.sync != .idle)
        }
    }
}
