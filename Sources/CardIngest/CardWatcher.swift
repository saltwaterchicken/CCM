import AppKit
import CardIngestCore

/// A mounted volume and what the app decided about it.
struct DetectedVolume: Identifiable {
    var info: VolumeInfo
    var verdict: CardVerdict
    /// Camera files found on the card; nil until the scan finishes.
    var files: [CardFile]?
    var scanError: String?
    /// Which of those files earlier imports already brought in; nil until checked.
    var check: CardCheck?

    var id: URL { info.url }
    var totalBytes: Int64 { files?.reduce(0) { $0 + $1.size } ?? 0 }
}

/// Where a card's copy job stands.
enum CopyState {
    /// Reading capture dates and choosing names, before any copying.
    case preparing
    case copying(fraction: Double)
    /// Copied the new files; `skipped` were already imported earlier.
    case done(CopyReport, skipped: Int)
    /// Every file on the card was already imported, so nothing was copied.
    case nothingNew(CardCheck)
    case failed(String)

    var isCopying: Bool {
        switch self {
        case .preparing, .copying: true
        case .done, .nothingNew, .failed: false
        }
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
    /// Called after a card copies and verifies, to move the import counter on.
    private let onImported: (ImportPlan) -> Void
    private var observers: [NSObjectProtocol] = []

    init(settings: IngestSettings, onImported: @escaping (ImportPlan) -> Void) {
        self.settings = settings
        self.onImported = onImported
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
                volume.check = old.check
            }
            return volume
        }
        .sorted { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending }

        for card in cards where card.files == nil && card.scanError == nil {
            scan(card.info.url)
        }
        // The destination may have changed, so look again at what's already imported.
        for card in cards where card.files != nil {
            checkHistory(card.info.url)
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
                case let .success(files):
                    self.volumes[index].files = files
                    self.checkHistory(url)
                case let .failure(error): self.volumes[index].scanError = error.localizedDescription
                }
            }
        }
    }

    /// Reads the destination's receipts in the background to find which of the
    /// card's files earlier imports already brought in.
    private func checkHistory(_ url: URL) {
        guard let files = volumes.first(where: { $0.id == url })?.files else { return }
        let destination = settings.destinationRootURL
        Task.detached {
            let check = ImportHistory.load(from: destination).check(files)
            await MainActor.run { [weak self] in
                guard let self, let index = self.volumes.firstIndex(where: { $0.id == url }),
                      self.volumes[index].files == files else { return }
                self.volumes[index].check = check
            }
        }
    }

    /// Copies the card into its own folder in the destination (and backup, if
    /// set), renaming each file, and verifies every copy. Only reads the card.
    func startCopy(_ card: DetectedVolume) {
        guard let files = card.files, copyStates[card.id]?.isCopying != true else { return }
        let url = card.id
        let name = card.info.name
        let settings = settings
        if let problem = settings.folderProblem {
            copyStates[url] = .failed(problem)
            return
        }

        let flag = StopFlag()
        stopFlags[url] = flag
        copyStates[url] = .preparing
        // Reading dates and copying block, so they run on their own thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (ImportPlan, CopyReport?) in
                let plan = try ImportPlanner.plan(cardRoot: url, cardName: name, files: files, settings: settings)
                if flag.isStopped { throw CopyError.cancelled }
                if plan.nothingNew { return (plan, nil) }
                let report = try CardCopier.copy(
                    cardRoot: url, cardName: name, files: plan.files, to: plan.folders,
                    importNumber: plan.importNumber,
                    progress: { done, total in
                        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 1
                        Task { @MainActor [weak self] in
                            if self?.copyStates[url]?.isCopying == true {
                                self?.copyStates[url] = .copying(fraction: fraction)
                            }
                        }
                    },
                    isCancelled: { flag.isStopped })
                return (plan, report)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopFlags[url] = nil
                switch result {
                case let .success((plan, report)):
                    guard let report else {
                        self.copyStates[url] = .nothingNew(plan.check)
                        return
                    }
                    self.copyStates[url] = .done(report, skipped: plan.check.alreadyImported.count)
                    self.onImported(plan)
                    self.checkHistory(url)
                case let .failure(error):
                    self.copyStates[url] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stopCopy(_ card: DetectedVolume) {
        stopFlags[card.id]?.stop()
    }
}
