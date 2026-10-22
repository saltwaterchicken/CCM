import AppKit
import CardIngestCore

/// A mounted volume and what the app decided about it.
struct DetectedVolume: Identifiable {
    var info: VolumeInfo
    var verdict: CardVerdict
    /// Camera files found on the card; nil until the scan finishes.
    var files: [CardFile]?
    var scanError: String?

    var id: URL { info.url }
    var totalBytes: Int64 { files?.reduce(0) { $0 + $1.size } ?? 0 }
}

/// Watches for volumes being mounted and unmounted, and sorts them into camera
/// cards and everything else. It only reads; it never changes a volume.
@MainActor
@Observable
final class CardWatcher {
    private(set) var volumes: [DetectedVolume] = []
    var cards: [DetectedVolume] { volumes.filter { $0.verdict.isCard } }
    var ignored: [DetectedVolume] { volumes.filter { !$0.verdict.isCard } }

    private var settings: IngestSettings
    private var observers: [NSObjectProtocol] = []

    init(settings: IngestSettings) {
        self.settings = settings
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func update(settings: IngestSettings) {
        self.settings = settings
        refresh()
    }

    /// Re-checks every mounted volume.
    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let protected = [settings.destinationRootURL] + [settings.backupRootURL].compactMap { $0 }
        let previous = Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0) })

        volumes = urls.compactMap { url in
            guard let info = try? VolumeInfo.read(url) else { return nil }
            let verdict = CardRules.verdict(for: info, protectedFolders: protected)
            var volume = DetectedVolume(info: info, verdict: verdict)
            if let old = previous[url], old.verdict == verdict {
                volume.files = old.files
                volume.scanError = old.scanError
            }
            return volume
        }
        .sorted { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending }

        for card in cards where card.files == nil && card.scanError == nil {
            scan(card.info.url)
        }
    }

    /// Counts the camera files on a card in the background.
    private func scan(_ url: URL) {
        let fileTypes = settings.fileTypes
        Task.detached {
            let result = Result { try CardScanner.scan(cardRoot: url, fileTypes: fileTypes) }
            await MainActor.run { [weak self] in
                guard let self, let index = self.volumes.firstIndex(where: { $0.id == url }) else { return }
                switch result {
                case let .success(files): self.volumes[index].files = files
                case let .failure(error): self.volumes[index].scanError = error.localizedDescription
                }
            }
        }
    }
}
