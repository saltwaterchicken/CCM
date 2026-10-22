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

/// Where a card's copy job stands.
enum CopyState {
    case copying(fraction: Double)
    case done(CopyReport)
    case failed(String)

    var isCopying: Bool {
        if case .copying = self { return true }
        return false
    }
}

/// A stop button's flag, shared with the background copy.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }
}

/// Watches for volumes being mounted and unmounted, and sorts them into camera
/// cards and everything else. It only reads; it never changes a volume.
@MainActor
@Observable
final class CardWatcher {
    private(set) var volumes: [DetectedVolume] = []
    var cards: [DetectedVolume] { volumes.filter { $0.verdict.isCard } }
    var ignored: [DetectedVolume] { volumes.filter { !$0.verdict.isCard } }

    private(set) var copyStates: [URL: CopyState] = [:]
    private var stopFlags: [URL: StopFlag] = [:]

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

    /// Copies the card to the destination (and backup, if set) and verifies
    /// every file. Only reads the card.
    func startCopy(_ card: DetectedVolume) {
        guard let files = card.files, copyStates[card.id]?.isCopying != true else { return }
        let url = card.id
        let name = card.info.name
        if let problem = settings.folderProblem {
            copyStates[url] = .failed(problem)
            return
        }
        let folders: [URL]
        do {
            let now = Date()
            var list = [try settings.destinationFolder(for: now)]
            if let backup = settings.backupRootURL {
                list.append(try settings.destinationFolder(for: now, root: backup))
            }
            folders = list
        } catch {
            copyStates[url] = .failed(error.localizedDescription)
            return
        }

        let flag = StopFlag()
        stopFlags[url] = flag
        copyStates[url] = .copying(fraction: 0)
        Task.detached {
            let result = Result {
                try CardCopier.copy(
                    cardRoot: url, cardName: name, files: files, to: folders,
                    progress: { done, total in
                        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 1
                        Task { @MainActor [weak self] in
                            if self?.copyStates[url]?.isCopying == true {
                                self?.copyStates[url] = .copying(fraction: fraction)
                            }
                        }
                    },
                    isCancelled: { flag.isStopped })
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stopFlags[url] = nil
                switch result {
                case let .success(report): self.copyStates[url] = .done(report)
                case let .failure(error): self.copyStates[url] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stopCopy(_ card: DetectedVolume) {
        stopFlags[card.id]?.stop()
    }
}
