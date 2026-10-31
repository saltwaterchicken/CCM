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

/// How a card ended up: what was copied, moved to its Trash and ejected.
struct Finished: Identifiable, Sendable {
    let id = UUID()
    var cardName: String
    /// Nil when every file on the card was already imported, so nothing was copied.
    var report: CopyReport?
    /// What was new and what earlier imports already brought in (and was skipped).
    var check: CardCheck
    var trash: TrashResult?
    /// Why the originals stayed on the card, when trashing is on but didn't happen.
    var keptOnCard: String?
    var ejectProblem: String?
    /// RAW sidecars that couldn't be written; the copies themselves are fine.
    var sidecarProblems: [String] = []
}

/// Where a card's copy job stands.
enum CopyState {
    /// Reading capture dates and choosing names, before any copying.
    case preparing
    case copying(fraction: Double)
    /// Copied and verified; asking before `files` go to the card's Trash.
    case askTrash(Finished, files: [CardFile])
    /// Moving the originals to the card's Trash.
    case clearing
    case done(Finished)
    case failed(String)

    var isCopying: Bool {
        switch self {
        case .preparing, .copying: true
        case .askTrash, .clearing, .done, .failed: false
        }
    }

    /// Still working on this card (or waiting for an answer), so Copy isn't offered.
    var isBusy: Bool {
        switch self {
        case .preparing, .copying, .askTrash, .clearing: true
        case .done, .failed: false
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
    /// Cards the app finished and ejected, newest first, so their summary stays on screen.
    private(set) var ejected: [Finished] = []
    /// The photos of the card copied last, for culling.
    let grid = GridModel()
    /// Each card's backup to the server, running beside the local copy.
    let backups = ServerBackups()
    /// Off when the license has run out: no new copies start (one already
    /// running always finishes and verifies), and Sync With Server is off.
    var licensed = true {
        didSet { grid.licensed = licensed }
    }
    /// Alerts on the phone and Watch, from the settings file.
    private var notifier: PhoneNotifier

    private var settings: IngestSettings
    /// Called after a card copies and verifies, to move the import counter on.
    private let onImported: (ImportPlan) -> Void
    /// Called when the photographer says yes to moving a card's originals to its Trash.
    private let onTrashConfirmed: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(settings: IngestSettings, onImported: @escaping (ImportPlan) -> Void,
         onTrashConfirmed: @escaping () -> Void) {
        self.settings = settings
        self.onImported = onImported
        self.onTrashConfirmed = onTrashConfirmed
        notifier = PhoneNotifier(settings.notifications)
        backups.notifier = notifier
        grid.use(settings)
        grid.backups = backups
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
        notifier = PhoneNotifier(settings.notifications)
        backups.notifier = notifier
        grid.use(settings)
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
        // A card put back in (or another card at the same path) starts fresh, not with the last result.
        let mounted = Set(volumes.map(\.id))
        copyStates = copyStates.filter { mounted.contains($0.key) || $0.value.isBusy }

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

    /// Copies the card into its own folder in the destination, renaming each
    /// file, and verifies every copy. Only reads the card. With a backup set,
    /// each verified file is also sent to the backup (the server) from the
    /// local copy, beside it: the local copy, trash and eject never wait for
    /// it (photographer's call, 2026-10-27: a card may be needed back at once).
    func startCopy(_ card: DetectedVolume) {
        guard licensed, let files = card.files, copyStates[card.id]?.isBusy != true else { return }
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
        let grid = grid
        let backups = backups
        let session = UUID()
        // Reading dates and copying block, so they run on their own thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (ImportPlan, CopyReport?, [String]) in
                let plan = try ImportPlanner.plan(cardRoot: url, cardName: name, files: files, settings: settings)
                if flag.isStopped { throw CopyError.cancelled }
                if plan.nothingNew { return (plan, nil, []) }
                let job = Self.startBackup(plan, root: settings.backupRootURL, cardName: name, backups: backups)
                // Each shot gets its sidecar and goes on the grid as soon as its last file is verified.
                let shots = LiveShots(planned: plan.files, fileTypes: settings.fileTypes, keywords: settings.metadata.keywords)
                let report: CopyReport
                do {
                    report = try CardCopier.copy(
                        cardRoot: url, cardName: name, files: plan.files, to: Array(plan.folders.prefix(1)),
                        importNumber: plan.importNumber,
                        progress: { done, total in
                            let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 1
                            Task { @MainActor [weak self] in
                                if self?.copyStates[url]?.isCopying == true {
                                    self?.copyStates[url] = .copying(fraction: fraction)
                                }
                            }
                        },
                        fileVerified: { file in
                            job?.send(file)
                            guard let landed = shots.complete(file) else { return }
                            let folder = plan.folders.first
                            Task { @MainActor in grid.add(landed, session: session, cardName: name, folder: folder) }
                        },
                        isCancelled: { flag.isStopped })
                } catch {
                    // What did copy still goes up; there's no receipt for a copy that didn't finish.
                    job?.finish(nil)
                    throw error
                }
                job?.finish(report)
                return (plan, report, shots.sidecarProblems)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopFlags[url] = nil
                switch result {
                case let .success((plan, report, sidecarProblems)):
                    if report != nil {
                        self.onImported(plan)
                        self.checkHistory(url)
                    }
                    var finished = Finished(cardName: name, report: report, check: plan.check)
                    finished.sidecarProblems = sidecarProblems
                    if let report {
                        self.notifier.send(.cardCopied(folder: plan.folders.first?.lastPathComponent ?? name, cardName: name,
                                                       files: report.files.count, bytes: report.totalBytes,
                                                       alreadyImported: plan.check.alreadyImported.count,
                                                       sidecarProblems: sidecarProblems.count))
                    } else {
                        self.notifier.send(.nothingNew(cardName: name, alreadyImported: plan.check.alreadyImported.count))
                    }
                    self.afterCopy(url, finished)
                case let .failure(error):
                    self.copyStates[url] = .failed(error.localizedDescription)
                    // Stop was pressed here, so the phone doesn't need telling.
                    if (error as? CopyError) != .cancelled {
                        self.notifier.send(.copyFailed(cardName: name, reason: error.localizedDescription))
                    }
                }
            }
        }
    }

    /// The backup of one card, if a backup folder is set: started when it's on
    /// a server (or a drive) that's there now, otherwise shown as not backed up.
    nonisolated private static func startBackup(_ plan: ImportPlan, root: URL?, cardName: String,
                                                backups: ServerBackups) -> ServerBackupJob? {
        guard let root, plan.folders.count > 1 else { return nil }
        let folder = plan.folders[1]
        let notStarted: String?
        switch BackupVolume.check(root) {
        case .server, .localDrive: notStarted = nil
        case .standIn: notStarted = "the server isn't connected (a folder on this Mac is standing in for it)."
        case .missing, .notSet: notStarted = "the server wasn't connected."
        }
        let id = UUID()
        Task { @MainActor in
            backups.begin(id: id, cardName: cardName, folderName: folder.lastPathComponent, localFolder: plan.folders[0],
                          notStarted: notStarted)
        }
        guard notStarted == nil else { return nil }
        return ServerBackupJob(folder: folder, root: root) { status in
            Task { @MainActor in backups.update(id, status) }
        }
    }

    /// File › Send Test Notification: tells the photographer whether it reached ntfy.
    func sendTestNotification() {
        notifier.send(.test) { problem in
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = problem == nil ? "Test notification sent" : "The test notification wasn't sent"
                alert.informativeText = problem ?? "It should be on your iPhone (and Watch) in a few seconds. "
                    + "If it isn't, check the ntfy app is subscribed to the topic in the settings file."
                alert.runModal()
            }
        }
    }

    var notificationsOn: Bool { notifier.settings.isOn }

    func stopCopy(_ card: DetectedVolume) {
        stopFlags[card.id]?.stop()
    }

    /// Once every copy is verified: the card's Trash (asking first for the
    /// first few cards), then eject, as the settings say.
    private func afterCopy(_ url: URL, _ finished: Finished) {
        var finished = finished
        guard settings.trashAfterVerify, let card = volumes.first(where: { $0.id == url }) else {
            return finish(url, finished)
        }
        let protected = [settings.destinationRootURL] + [settings.backupRootURL].compactMap { $0 }
        if let refusal = CardClearer.refusal(for: card.info, protectedFolders: protected) {
            finished.keptOnCard = refusal
            return finish(url, finished)
        }
        let files = CardClearer.safelyCopied(report: finished.report, check: finished.check)
        if files.isEmpty { return finish(url, finished) }
        if settings.confirmTrashForFirstCards > 0 {
            copyStates[url] = .askTrash(finished, files: files)
        } else {
            clear(url, finished, files)
        }
    }

    func confirmTrash(_ card: DetectedVolume) {
        guard case let .askTrash(finished, files) = copyStates[card.id] else { return }
        onTrashConfirmed()
        clear(card.id, finished, files)
    }

    func keepOnCard(_ card: DetectedVolume) {
        guard case var .askTrash(finished, _) = copyStates[card.id] else { return }
        finished.keptOnCard = "You chose to keep the originals on the card."
        finish(card.id, finished)
    }

    private func clear(_ url: URL, _ finished: Finished, _ files: [CardFile]) {
        copyStates[url] = .clearing
        Task.detached {
            let result = CardClearer.trash(files, cardRoot: url)
            await MainActor.run { [weak self] in
                var finished = finished
                finished.trash = result
                self?.finish(url, finished)
            }
        }
    }

    /// Shows the summary, and ejects the card if that's on. An ejected card's
    /// summary moves to `ejected` so it stays on screen.
    private func finish(_ url: URL, _ finished: Finished) {
        copyStates[url] = .done(finished)
        guard settings.ejectWhenDone, volumes.contains(where: { $0.id == url && $0.verdict.isCard }) else { return }
        // Answered on a background thread, like NSWorkspace.open in GridModel.
        FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk]) { @Sendable error in
            let problem = error.map { "Couldn't eject the card: \($0.localizedDescription) Eject it in Finder when you're ready." }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var finished = finished
                if let problem {
                    finished.ejectProblem = problem
                    self.copyStates[url] = .done(finished)
                } else {
                    if case .done = self.copyStates[url] { self.copyStates[url] = nil }
                    self.ejected.insert(finished, at: 0)
                    self.ejected = Array(self.ejected.prefix(5))
                }
            }
        }
    }

    func dismissEjected(_ finished: Finished) {
        ejected.removeAll { $0.id == finished.id }
    }
}
