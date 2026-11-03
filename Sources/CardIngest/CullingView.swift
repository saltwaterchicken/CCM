import AppKit
import CardIngestCore
import SwiftUI

/// The grid for the card copied last (or a folder loaded with Load Folder):
/// fills in as shots land, and stays until the next Copy brings in new files.
/// Stars are written to the sidecars on a queue of their own, in the order
/// they were given.
@MainActor
@Observable
final class GridModel {
    private(set) var grid = CullGrid()
    private(set) var cardName = ""
    private(set) var folder: URL?
    private(set) var problem: String?
    /// Set by CardWatcher: Sync With Server is off when the license has run out.
    var licensed = true
    private(set) var cache = ThumbnailCache()
    /// Pictures for the large view, at the screen's size; the neighbours are loaded ahead.
    private(set) var big = GridModel.bigCache()
    /// 100% pictures: the one showing and the next, as they can be 400 MB each.
    private var actualImages: [String: CGImage] = [:]
    private var actualOrder: [String] = []
    private var actualLoading: [String: Task<CGImage?, Never>] = [:]
    /// The large view is open on the focused shot; `actualSize` shows it at 100%.
    private(set) var isViewing = false
    var actualSize = false
    /// Tiles per row, for the up and down arrows; set by the grid as it's laid out.
    var columns = 1
    /// From the settings file: the app the Open button uses, and where Load Folder looks.
    var openWith = IngestSettings().openWith
    var destinationRoot = IngestSettings().destinationRootURL
    var fileTypes = FileTypes()
    /// The auto-rating limits, and whether shots are checked as they land.
    var rating = RatingSettings()
    /// Calibrating the card in the grid (see CalibrationModel); nil otherwise.
    private(set) var calibration: CalibrationModel?
    /// While calibrating: the photos in shooting order, or by score, softest first.
    var calibrationByScore = false {
        didSet { sortForCalibration() }
    }
    /// The backup folder (the server), for Sync With Server.
    var serverRoot: URL?
    /// The cards' backups, so Sync waits for this card's to finish.
    weak var backups: ServerBackups?
    /// Tells the phone when Sync With Server is done.
    var notifier = PhoneNotifier(NotificationSettings())
    private(set) var sync = SyncState.idle

    enum SyncState: Equatable {
        case idle
        case comparing
        /// One plan per card, and the cards left out as their backup is still sending.
        case confirm([ServerSync.Plan], waiting: [String])
        case syncing(done: Int, total: Int)
        case done([CardSync])
        case failed(String)
    }

    /// What Sync With Server did for one card.
    struct CardSync: Equatable {
        let name: String
        let outcome: ServerSync.Outcome
        let cantUpdate: [String]
    }

    /// The cards Sync With Server covers, by their folders on this Mac: every
    /// card in the Server panel's list, and the one in the grid (it may be an
    /// older card, loaded with Load Folder).
    var syncFolders: [URL] {
        var folders = backups?.entries.compactMap(\.localFolder) ?? []
        if let folder, !folders.contains(where: { $0.lastPathComponent == folder.lastPathComponent }) {
            folders.insert(folder, at: 0)
        }
        return folders
    }

    /// The cards whose backup is still sending, which Sync leaves for now.
    var backupsRunning: [String] {
        let running = Set(backups?.entries.filter(\.running).map(\.folderName) ?? [])
        return syncFolders.map(\.lastPathComponent).filter(running.contains)
    }

    /// The cards Sync would send now.
    var syncReady: [URL] {
        let running = Set(backupsRunning)
        return syncFolders.filter { !running.contains($0.lastPathComponent) }
    }

    /// Compares every card with its folder on the server, then asks before writing anything.
    func compareWithServer() {
        let folders = syncReady
        guard licensed, !folders.isEmpty, let root = serverRoot else { return }
        let waiting = backupsRunning
        let types = fileTypes
        sync = .comparing
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[ServerSync.Plan], Error> in
                switch BackupVolume.check(root) {
                case .server, .localDrive:
                    return Result {
                        try folders.map { try ServerSync.plan(local: $0, server: root.appendingPathComponent($0.lastPathComponent, isDirectory: true), fileTypes: types) }
                    }
                default: return .failure(SyncProblem.notConnected)
                }
            }.value
            guard sync == .comparing else { return }
            switch result {
            case let .success(plans): sync = .confirm(plans, waiting: waiting)
            case let .failure(error): sync = .failed(error.localizedDescription)
            }
        }
    }

    /// Sends each card in turn, and says what happened to each.
    func runSync(_ plans: [ServerSync.Plan]) {
        let total = plans.reduce(0) { $0 + $1.adds.count }
        sync = .syncing(done: 0, total: total)
        Task {
            var results: [CardSync] = []
            var before = 0
            for plan in plans {
                let offset = before
                let outcome = await Task.detached(priority: .utility) {
                    ServerSync.run(plan, progress: { done in
                        Task { @MainActor [weak self] in
                            if case .syncing = self?.sync { self?.sync = .syncing(done: offset + done, total: total) }
                        }
                    })
                }.value
                before += plan.adds.count
                results.append(CardSync(name: plan.localFolder.lastPathComponent, outcome: outcome, cantUpdate: plan.cantUpdate))
            }
            backups?.synced(results)
            sync = .done(results)
            notifier.send(.syncDone(results.map {
                PhoneNotification.SyncedCard(name: $0.name, added: $0.outcome.added,
                                             problems: $0.outcome.problems.count + $0.cantUpdate.count)
            }))
        }
    }

    func dismissSync() { sync = .idle }
    private var session: UUID?
    private let writes = DispatchQueue(label: "Card Ingest stars", qos: .userInitiated)
    /// Sharpness and exposure checks: behind the copy, on half the cores, so
    /// copying, verifying, trash and eject never wait for them.
    private let checks: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Card Ingest checks"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        return queue
    }()
    /// Shots waiting to be checked or being checked, and how far the checks have got.
    private var pending: Set<String> = []
    private(set) var checksDone = 0
    private(set) var checksTotal = 0
    private var checkProblems: [String] = []
    var isChecking: Bool { !pending.isEmpty }

    /// The screen's longest side in pixels: as big as the large view needs.
    static var screenPixels: Int {
        let screen = NSScreen.main
        return Int(max(screen?.frame.width ?? 1600, screen?.frame.height ?? 1000) * (screen?.backingScaleFactor ?? 2))
    }

    private static func bigCache() -> ThumbnailCache {
        ThumbnailCache(maxPixels: screenPixels, byteLimit: 384 * 1024 * 1024, concurrent: 2) { shot, pixels in
            await LargeImage.fit(shot, maxPixels: pixels)
        }
    }

    /// A shot from the Copy `session`; the first shot of a new Copy clears the grid.
    func add(_ landed: LandedShot, session: UUID, cardName: String, folder: URL?) {
        if session != self.session { begin(session, cardName: cardName, folder: folder) }
        grid.add(landed)
        if rating.checksOnLanding, landed.check == nil, landed.stars == nil, landed.shot.isPhoto { check([landed.shot]) }
    }

    /// Checks the photos nobody has rated and the checks haven't seen (the
    /// Check button, for a loaded folder or with auto-rating off).
    func checkUnchecked() {
        check(grid.unchecked)
    }

    /// How many photos a Check would look at.
    var uncheckedCount: Int { grid.unchecked.count { !pending.contains($0.id) } }

    private func check(_ shots: [Shot]) {
        let limits = rating
        guard let session else { return }
        for shot in shots where !pending.contains(shot.id) {
            pending.insert(shot.id)
            checksTotal += 1
            checks.addOperation {
                let result = Result { try AutoRating.rate(shot, limits: limits) }
                Task { @MainActor [weak self] in self?.checked(shot.id, result, session: session) }
            }
        }
    }

    private func checked(_ id: String, _ result: Result<AutoCheck?, Error>, session: UUID) {
        guard session == self.session else { return }
        pending.remove(id)
        checksDone += 1
        switch result {
        case let .success(check?):
            grid.apply(check, to: id)
        case .success(nil):
            break
        case let .failure(error):
            checkProblems.append(error.localizedDescription)
            problem = "Couldn't check \(checkProblems.count) \(checkProblems.count == 1 ? "photo" : "photos"): \(checkProblems[0])"
        }
        if pending.isEmpty {
            checksDone = 0
            checksTotal = 0
        }
    }

    /// An earlier import back in the grid, with its stars, to carry on culling.
    /// Load Folder…, from the grid or the File menu: true when one was chosen.
    @discardableResult
    func chooseFolderToLoad() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose a card folder from an earlier import"
        panel.directoryURL = folder?.deletingLastPathComponent() ?? destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        load(url)
        return true
    }

    func load(_ folder: URL) {
        do {
            // Stars stay on this Mac: the server's copies are written once, by the backup and Sync.
            let shots = try ImportedFolder.shots(in: folder, backupRoot: nil, fileTypes: fileTypes)
            begin(UUID(), cardName: "Loaded", folder: folder)
            grid.add(contentsOf: shots)
            savedClips = Set(SavedClips.load(from: folder)?.rows.map { ($0.name.lowercased() as NSString).deletingPathExtension } ?? [])
            if shots.isEmpty { problem = "No photos or clips in \(folder.lastPathComponent)." }
        } catch {
            problem = "Couldn't load \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func begin(_ session: UUID, cardName: String, folder: URL?) {
        self.session = session
        // Sync covers every card, not just the grid's, so only a finished result is cleared.
        switch sync {
        case .done, .failed: sync = .idle
        default: break
        }
        // A check already running finishes, but its result is dropped from the new grid.
        checks.cancelAllOperations()
        pending = []
        checksDone = 0
        checksTotal = 0
        checkProblems = []
        grid = CullGrid()
        cache = ThumbnailCache()
        big = Self.bigCache()
        actualImages = [:]
        actualOrder = []
        actualLoading = [:]
        isViewing = false
        problem = nil
        self.cardName = cardName
        self.folder = folder
        savedClips = []
        clipSave = .idle
        // Another card in the grid: calibrating this one is over.
        stopCalibrating()
    }

    /// Calibrate…: scores the card in the grid and shows every photo with
    /// the chips the limits would give it, the limits in the side panel.
    func startCalibrating(settingsURL: URL) {
        guard let folder, rating.available else { return }
        if isViewing { closeView() }
        calibration?.stop()
        calibration = CalibrationModel(folder: folder, limits: rating, settingsURL: settingsURL)
        filter = .all
        sortForCalibration()
    }

    /// Calibrate… in the Job panel and the Photos menu: the card in the grid,
    /// or an earlier card chosen now.
    func calibrate(settingsURL: URL) {
        if folder == nil, !chooseFolderToLoad() { return }
        startCalibrating(settingsURL: settingsURL)
    }

    /// Photos › Calibrate on Another Card…
    func calibrateAnotherCard(settingsURL: URL) {
        if chooseFolderToLoad() { startCalibrating(settingsURL: settingsURL) }
    }

    func stopCalibrating() {
        guard calibration != nil else { return }
        calibration?.stop()
        calibration = nil
        grid.order = nil
    }

    /// By score once the scores are in; until then, and in shooting order, as they landed.
    func sortForCalibration() {
        guard let calibration, calibrationByScore else { return grid.order = nil }
        grid.order = calibration.byID.mapValues(\.sharpness)
    }

    /// The orange chips a shot shows: what the limits being tried would flag
    /// while calibrating, else what the checks flagged and nobody's rated since.
    func problems(of id: String) -> [QualityProblem] {
        if let calibration { return calibration.problems(id) }
        guard let check = check(of: id), check.isFlagged, grid.stars[id] == 0 else { return [] }
        return check.problems
    }

    /// The shot's 100% picture, from the two kept or made now.
    func actualPixels(_ shot: Shot) async -> CGImage? {
        if let image = actualImages[shot.id] { return image }
        if let task = actualLoading[shot.id] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { LargeImage.actualPixels(shot) }
        actualLoading[shot.id] = task
        let image = await task.value
        actualLoading[shot.id] = nil
        if let image {
            actualImages[shot.id] = image
            actualOrder.removeAll { $0 == shot.id }
            actualOrder.append(shot.id)
            while actualOrder.count > 2 { actualImages[actualOrder.removeFirst()] = nil }
        }
        return image
    }

    /// Loads the next and previous photos ahead (and the next one's 100%
    /// picture when looking at 100%), so the arrows don't wait.
    func loadAhead(of id: String) {
        let shown = grid.visible
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return }
        let next = shown.indices.contains(index + 1) ? shown[index + 1] : nil
        let previous = index > 0 ? shown[index - 1] : nil
        let big = big
        for shot in [next, previous].compactMap({ $0 }) {
            Task(priority: .utility) { _ = await big.thumbnail(for: shot) }
        }
        if actualSize, let next, next.isPhoto {
            Task(priority: .utility) { _ = await actualPixels(next) }
        }
    }

    func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        grid.click(id, shift: flags.contains(.shift), command: flags.contains(.command))
    }

    func move(by step: Int) { grid.move(by: step) }
    /// The settings Open and Load Folder use.
    func use(_ settings: IngestSettings) {
        openWith = settings.openWith
        destinationRoot = settings.destinationRootURL
        fileTypes = settings.fileTypes
        rating = settings.rating
        jobKeywords = settings.metadata.keywords
        serverRoot = settings.backupRootURL
        notifier = PhoneNotifier(settings.notifications)
        if !rating.available, grid.filter == .appFlagged { grid.filter = .all }
        refreshWaitingClips()
        if waitingTimer == nil {
            waitingTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWaitingClips() }
            }
        }
    }

    /// The sharpest frame of a burst, while auto-rating is available. While
    /// calibrating, from the scores just taken, so earlier cards show it too.
    func isBurstSharpest(_ id: String) -> Bool {
        guard rating.available else { return false }
        return calibration?.burstSharpest.contains(id) ?? grid.burstSharpest.contains(id)
    }

    /// What the checks found for a shot, as the grid shows it: nothing when
    /// auto-rating is turned off in the settings file.
    func check(of id: String) -> AutoCheck? {
        rating.available ? grid.checks[id] : nil
    }

    /// Up (-1) or down (+1) a row.
    func moveRow(by rows: Int) { grid.move(by: rows * max(1, columns)) }
    func selectAll() { grid.selectAll() }

    var filter: StarFilter {
        get { grid.filter }
        set {
            grid.filter = newValue
            if grid.focus == nil { isViewing = false }
        }
    }

    /// Opens the large view on a shot (or the focused one), fitted or at 100%.
    /// A clip asked for at 100% (Space in the grid) starts playing instead.
    func view(_ id: String? = nil, actualSize: Bool = false) {
        if let id, grid.focus != id { grid.click(id) }
        guard let focus = grid.focus, let shot = grid.shot(focus) else { return }
        self.actualSize = actualSize && shot.isPhoto
        playWhenShown = actualSize && shot.kind == .video
        isViewing = true
    }

    /// Set by Space in the grid on a clip; the large view plays it once and clears this.
    var playWhenShown = false

    func closeView() {
        isViewing = false
        actualSize = false
    }

    /// The app named by `openWith`, found by full path, bundle id, or name in
    /// the Applications folders (Adobe puts each app in a folder of its own).
    var application: URL? {
        let name = openWith.trimmingCharacters(in: .whitespaces)
        let fm = FileManager.default
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        let bare = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let folders = ["/Applications", "/Applications/\(bare)", "/Applications/Utilities", "/System/Applications",
                       ("~/Applications" as NSString).expandingTildeInPath]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(bare + ".app") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// "Adobe Lightroom Classic", for the button.
    var applicationName: String {
        application.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? openWith
    }

    /// Sends the selected shots, or all shown when none are, to the `openWith` app.
    func openInApplication() {
        let files = grid.toOpen
        guard !files.isEmpty else { return }
        guard let app = application else {
            problem = "Couldn't find \"\(openWith)\". Change openWith in the settings file to the app's name or bundle id."
            return
        }
        problem = nil
        // macOS answers on a thread of its own, not the main one: without @Sendable, Swift assumes
        // the main thread and stops the app when it isn't (the crash found 2026-10-23).
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
            guard let error else { return }
            let message = "Couldn't open the photos in \(app.lastPathComponent): \(error.localizedDescription)"
            Task { @MainActor [weak self] in self?.problem = message }
        }
    }

    /// The photographer's own keywords, newest first: the first few are offered
    /// as one-click buttons under the grid, and all of them fill in the keyword
    /// field as it's typed. In My Keywords.txt, not the settings file, which
    /// holds the job's.
    private(set) var recentKeywords: [String] = GridModel.savedRecentKeywords()
    /// The job's keywords from the settings file, also filled in as typed.
    private(set) var jobKeywords: [String] = []
    /// The keyword bar under the grid, shown and hidden with ⌘K; remembered.
    private(set) var keywordBarShown = UserDefaults.standard.object(forKey: GridModel.keywordBarShownKey) as? Bool ?? true
    /// Set when the keyword field should take the keys; it clears it once it has.
    var keywordFieldWantsFocus = false
    nonisolated private static let keywordBarShownKey = "keywordBarShown"

    /// Every keyword the field can fill in, the most recently used first.
    var knownKeywords: [String] {
        let onPhotos = grid.keywords.values.reduce(into: [String]()) { $0 = Keywords.merged($0, adding: $1) }
        return Keywords.merged(Keywords.merged(recentKeywords, adding: jobKeywords), adding: onPhotos.sorted())
    }

    /// File › Show My Keywords in Finder; made first if no keyword's been used yet.
    func showKeywordFile() {
        let url = KeywordHistory.defaultFileURL
        if !FileManager.default.fileExists(atPath: url.path) { try? KeywordHistory.save(recentKeywords, to: url) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Photos › Show/Hide Keywords (⌘K). Shown with photos selected, the field takes the keys.
    func toggleKeywordBar() {
        keywordBarShown.toggle()
        UserDefaults.standard.set(keywordBarShown, forKey: Self.keywordBarShownKey)
        if keywordBarShown, !grid.selectedForKeywords.isEmpty { keywordFieldWantsFocus = true }
    }

    /// K in the grid: shows the bar if it's hidden, and the field takes the keys.
    func typeKeywords() {
        guard !grid.selectedForKeywords.isEmpty else { return }
        if !keywordBarShown {
            keywordBarShown = true
            UserDefaults.standard.set(true, forKey: Self.keywordBarShownKey)
        }
        keywordFieldWantsFocus = true
    }

    /// The file, made the first time from the lists the app kept before in its
    /// preferences: one for `swift run`, one for the double-click app.
    nonisolated private static func savedRecentKeywords() -> [String] {
        let older = [UserDefaults.standard, UserDefaults(suiteName: "CardIngest"),
                     UserDefaults(suiteName: "com.capturecampmemories.cardingest")]
            .map { $0?.stringArray(forKey: "recentKeywords") ?? [] }
        return KeywordHistory.moveIn(older)
    }

    // MARK: Save to Clips

    enum ClipSave: Equatable {
        case idle
        case saving(done: Int, total: Int)
        case done(ClipSaver.Outcome)
    }

    var clipSave = ClipSave.idle
    /// The clips of the card in the grid that are saved and unchanged since.
    private var savedClips: Set<String> = []
    /// Every card with clips waiting, for the Server panel.
    var waitingClips: [SavedClips.Waiting] = []
    private var waitingTimer: Timer?
    private static let clipsAlertedKey = "clipsWaitingAlerted"

    /// The clips Save to Clips would save, in the order they landed.
    var clipsToSave: [Shot] { grid.shots.filter { $0.kind == .video && !savedClips.contains($0.id) } }

    var canSaveToClips: Bool {
        if case .saving = clipSave { return false }
        return licensed && folder != nil && !clipsToSave.isEmpty
    }

    /// Changed since it was saved, so the button offers it again.
    private func needSavingAgain(_ shots: [Shot]) {
        savedClips.subtract(shots.filter { $0.kind == .video }.map(\.id))
    }

    /// Writes the stars and keywords into the card's clips and sends them to
    /// the server, once told that can't be undone there.
    func saveToClips() {
        guard canSaveToClips, let folder else { return }
        let clips = clipsToSave
        let alert = NSAlert()
        alert.messageText = "Save to \(clips.count) \(clips.count == 1 ? "clip" : "clips")?"
        alert.informativeText = "Writes the stars and keywords inside each clip, then sends it to the Server, where it can't be changed afterwards. "
            + "The picture and sound aren't touched."
        alert.addButton(withTitle: "Save to Clips")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let root = serverRoot
        let total = clips.count
        clipSave = .saving(done: 0, total: total)
        Task {
            // After the stars' queue, so what's just been rated is in the sidecars it reads.
            let outcome = await withCheckedContinuation { (done: CheckedContinuation<ClipSaver.Outcome, Never>) in
                writes.async {
                    done.resume(returning: ClipSaver.save(clips, in: folder, root: root, progress: { count in
                        Task { @MainActor [weak self] in
                            if case .saving = self?.clipSave { self?.clipSave = .saving(done: count, total: total) }
                        }
                    }))
                }
            }
            guard self.folder == folder else { return refreshWaitingClips() }
            savedClips = Set(SavedClips.load(from: folder)?.rows.map { ($0.name.lowercased() as NSString).deletingPathExtension } ?? [])
            clipSave = .done(outcome)
            refreshWaitingClips()
        }
    }

    /// Looks for cards with clips waiting, and tells the phone once about any
    /// that have waited a day.
    func refreshWaitingClips() {
        let root = destinationRoot
        let types = fileTypes
        Task {
            let cards = await Task.detached(priority: .utility) { SavedClips.waitingCards(in: root, fileTypes: types) }.value
            waitingClips = cards
            var alerted = UserDefaults.standard.stringArray(forKey: Self.clipsAlertedKey) ?? []
            for card in cards where Date().timeIntervalSince(card.since) >= 24 * 3600 && !alerted.contains(card.folder.lastPathComponent) {
                notifier.send(.clipsWaiting(folder: card.folder.lastPathComponent, clips: card.clips))
                alerted.append(card.folder.lastPathComponent)
            }
            UserDefaults.standard.set(alerted, forKey: Self.clipsAlertedKey)
        }
    }

    /// Adds keywords to the selected photos' sidecars, on the stars' queue so
    /// changes to one sidecar are written in the order they were made.
    func addKeywords(_ words: [String]) {
        guard !words.isEmpty else { return }
        // Read afresh, so the file can be edited by hand while the app is open.
        recentKeywords = KeywordHistory.used(words, in: KeywordHistory.load())
        do {
            try KeywordHistory.save(recentKeywords)
        } catch {
            problem = "Couldn't save My Keywords.txt: \(error.localizedDescription)"
        }
        let shots = grid.addKeywords(words)
        needSavingAgain(shots)
        writeKeywords(shots) { try Keywords.add(words, to: $0) }
    }

    /// Takes a keyword off the selected photos.
    func removeKeyword(_ word: String) {
        let shots = grid.removeKeyword(word)
        needSavingAgain(shots)
        writeKeywords(shots) { try Keywords.remove([word], from: $0) }
    }

    private func writeKeywords(_ shots: [Shot], _ write: @escaping @Sendable (Shot) throws -> Void) {
        guard !shots.isEmpty else { return }
        writes.async {
            for shot in shots {
                do {
                    try write(shot)
                } catch {
                    let message = "Couldn't save the keywords for \(shot.baseName): \(error.localizedDescription)"
                    Task { @MainActor [weak self] in self?.problem = message }
                }
            }
        }
    }

    func rate(_ stars: Int) {
        let shots = grid.rate(stars)
        guard !shots.isEmpty else { return }
        needSavingAgain(shots)
        calibration?.setStars(stars, on: shots.map(\.id))
        writes.async {
            for shot in shots {
                do {
                    try Stars.set(stars, on: shot)
                } catch {
                    let message = "Couldn't save the stars for \(shot.baseName): \(error.localizedDescription)"
                    Task { @MainActor [weak self] in self?.problem = message }
                }
            }
        }
    }
}

/// Thumbnails of the card just copied, with their stars. Click to select;
/// 0 to 5 rate; the arrows move.
struct CullingView: View {
    var model: GridModel
    /// The settings file in use: calibrating keeps its disagreements beside it.
    var settings: SettingsModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.grid.visible.isEmpty {
                Spacer()
                Text(model.grid.shots.isEmpty
                     ? "Press Copy and the photos appear here as they land, or Load Folder… to carry on with an earlier card."
                     : "No photos with \(model.filter.label). Choose All to see every shot.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                            ForEach(model.grid.visible) { shot in
                                TileView(shot: shot, stars: model.grid.stars[shot.id], check: model.check(of: shot.id),
                                         keywords: model.grid.keywords[shot.id] ?? [],
                                         problems: model.problems(of: shot.id),
                                         disagreements: model.calibration?.labels(for: shot.id) ?? [],
                                         isBurstSharpest: model.isBurstSharpest(shot.id),
                                         isSelected: model.grid.selected.contains(shot.id), cache: model.cache)
                                    .id(shot.id)
                                    .onTapGesture {
                                        model.click(shot.id)
                                        focused = true
                                    }
                                    // Fires on the second click; the first has already selected it.
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.view(shot.id) })
                                    // Control-click or right-click: the shot's files (RAW, JPEG, sidecar) selected in Finder.
                                    .contextMenu {
                                        if let calibration = model.calibration, let photo = calibration.byID[shot.id] {
                                            Text(calibration.problems(shot.id).isEmpty ? "Should be flagged:" : "Flagged, but:")
                                            LabelMenuItems(photo: photo, labels: calibration.labels(for: shot.id)) {
                                                calibration.toggle($0, on: shot.id)
                                            }
                                            Divider()
                                        }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting(shot.files.compactMap(\.destinations.first))
                                        }
                                    }
                            }
                        }
                        .padding(8)
                    }
                    // How many tiles fit in a row (adaptive, 170 wide, 8 apart, 8 in from each side).
                    .onGeometryChange(for: Int.self) { geometry in
                        max(1, Int((geometry.size.width - 16 + 8) / (170 + 8)))
                    } action: { if model.columns != $0 { model.columns = $0 } }
                    .onChange(of: model.grid.focus) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                    // Sorted the other way: the photo being looked at stays in view.
                    .onChange(of: model.calibrationByScore) {
                        if let id = model.grid.focus { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.calibration?.phase) {
                        model.sortForCalibration()
                        if let id = model.grid.focus { proxy.scrollTo(id, anchor: .center) }
                    }
                    // Back from the large view: the keys work on the grid again straight away.
                    .onChange(of: model.isViewing) { _, viewing in
                        if !viewing { focused = true }
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
                    guard let stars = Int(press.characters) else { return .ignored }
                    model.rate(stars)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    model.move(by: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    model.move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.moveRow(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveRow(by: 1)
                    return .handled
                }
                .onKeyPress(.space) {
                    model.view(actualSize: true)
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.selectAll()
                    return .handled
                }
                // K: type keywords for the selection, as in Photo Mechanic's quick keywording.
                .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { press in
                    guard !press.modifiers.contains(.command), !model.grid.selectedForKeywords.isEmpty else { return .ignored }
                    model.typeKeywords()
                    return .handled
                }
            }
            if !model.grid.shots.isEmpty, model.keywordBarShown {
                KeywordBar(model: model) { giveKeysToGrid() }
            }
        }
        // Hidden with ⌘K while typing in it: the grid takes the keys back.
        .onChange(of: model.keywordBarShown) { _, shown in
            if !shown { giveKeysToGrid() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelEdge, lineWidth: 1))
    }

    /// Back to culling. The keyword field is AppKit's, outside SwiftUI's focus,
    /// so the grid's focus is set afresh once the field has let go.
    private func giveKeysToGrid() {
        focused = false
        DispatchQueue.main.async { focused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Photos")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if !model.grid.shots.isEmpty {
                    Text("\(model.cardName) · \(model.grid.shots.count) shots"
                         + (model.folder.map { " in \($0.lastPathComponent)" } ?? ""))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0–5 rate · K keywords (⌘K shows or hides them) · arrows move · double-click or Space to look closer · ⌘A all")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Spacer()
                }
                Button("Load Folder…", action: chooseFolder)
                    .help("Shows an earlier card's folder here with its stars, to carry on culling without the card.")
                    .helpSpot(.loadFolder)
            }
            if !model.grid.shots.isEmpty {
                HStack {
                    Picker("Show", selection: Binding(get: { model.filter }, set: { model.filter = $0 })) {
                        ForEach(StarFilter.choices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .helpSpot(.starFilter)
                    if model.calibration != nil {
                        Picker("Order", selection: Binding(get: { model.calibrationByScore }, set: { model.calibrationByScore = $0 })) {
                            Text("Shooting Order").tag(false)
                            Text("By Score, Softest First").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("Shooting order shows each photo beside the frames taken with it; by score puts the borderline ones together")
                    } else if model.rating.available, !model.grid.checks.isEmpty || model.isChecking {
                        Toggle(isOn: Binding(get: { model.filter == .appFlagged },
                                             set: { model.filter = $0 ? .appFlagged : .all })) {
                            Label("Flagged by app (\(model.grid.flaggedByApp))", systemImage: "exclamationmark.triangle")
                        }
                        .toggleStyle(.button)
                        .help("Only the photos the sharpness and exposure checks left at 0, to check the limits. "
                              + "Rating one takes it out.")
                        .helpSpot(.flaggedByApp)
                        if model.filter == .appFlagged {
                            Button("Calibrate…") { model.startCalibrating(settingsURL: settings.fileURL) }
                                .help("Shows every photo with the chips the limits would give it, to disagree where they're wrong")
                        }
                    }
                    Spacer()
                    if !model.grid.shots.filter({ $0.kind == .video }).isEmpty {
                        Button("Save to Clips") { model.saveToClips() }
                            .disabled(!model.canSaveToClips)
                            .help("Writes the stars and keywords inside each clip, where Premiere Pro reads them, "
                                  + "then sends it to the Server. Press it once you've been through the card's clips.")
                    }
                    let count = model.grid.toOpen.count
                    Button("Open \(count) in \(model.applicationName)") { model.openInApplication() }
                        .disabled(count == 0)
                        .help("Opens the selected photos, or all the photos shown when none are selected. "
                              + "The app is set by openWith in the settings file.")
                        .helpSpot(.openIn)
                }
            }
            // One line kept the same height whether checking, offering a Check or
            // neither: checks start and finish with each shot that lands, and a
            // line coming and going would bounce the grid up and down.
            if !model.grid.shots.isEmpty, model.rating.available {
                Group {
                    if model.isChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking sharpness and exposure: \(model.checksDone) of \(model.checksTotal)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else if model.uncheckedCount > 0 {
                        HStack {
                            Button("Check \(model.uncheckedCount) \(model.uncheckedCount == 1 ? "Photo" : "Photos")") {
                                model.checkUnchecked()
                            }
                            .helpSpot(.checkPhotos)
                            Text("Rates sharpness and exposure for the photos with no stars yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 24, alignment: .leading)
            }
            ClipSaveStatus(model: model)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func chooseFolder() {
        if model.chooseFolderToLoad() { focused = true }
    }
}

/// What Save to Clips is doing, or did.
struct ClipSaveStatus: View {
    var model: GridModel

    var body: some View {
        switch model.clipSave {
        case .idle:
            EmptyView()
        case let .saving(done, total):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                Text("Saving to clips and sending to the Server: \(done) of \(total)").foregroundStyle(.secondary).monospacedDigit()
            }
        case let .done(outcome):
            VStack(alignment: .leading, spacing: 2) {
                if outcome.saved > 0 {
                    Label(summary(outcome), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                if outcome.waitingForServer > 0 {
                    Text("The Server isn't connected: Sync With Server will send \(outcome.waitingForServer) once it is.")
                        .foregroundStyle(.orange)
                }
                ForEach(outcome.problems.prefix(5), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if outcome.problems.count > 5 { Text("and \(outcome.problems.count - 5) more").foregroundStyle(.orange) }
            }
        }
    }

    private func summary(_ outcome: ClipSaver.Outcome) -> String {
        "Saved \(outcome.saved) \(outcome.saved == 1 ? "clip" : "clips")"
            + (outcome.sent > 0 ? ", \(outcome.sent) sent to the Server and checked." : ".")
    }
}

/// Under the grid: the selected photos' and clips' keywords, a field to add more, and
/// the ones used lately, in type big enough to read and click on any screen.
/// Return adds what's typed and gives the keys back to the grid, so culling
/// carries on; Esc gives them back without adding. A keyword used before
/// fills itself in as it's typed: Tab, a comma or → takes it, typing on
/// replaces it. The arrows still move in the grid while typing (← → only
/// while the field is empty). ⌘K shows and hides the bar.
struct KeywordBar: View {
    var model: GridModel
    /// Back to the grid.
    var done: () -> Void
    @State private var text = ""

    var body: some View {
        let photos = model.grid.selectedForKeywords
        let onSelection = model.grid.selectionKeywords
        let recent = model.recentKeywords.filter { word in
            !onSelection.contains { $0.onAll && $0.keyword.caseInsensitiveCompare(word) == .orderedSame }
        }.prefix(12)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Keywords")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                KeywordField(text: $text,
                             placeholder: photos.isEmpty ? "Select photos, then press K to type keywords"
                                 : "Add to the \(photos.count) selected, commas between, then Return",
                             enabled: !photos.isEmpty,
                             suggestions: model.knownKeywords,
                             wantsFocus: Binding(get: { model.keywordFieldWantsFocus },
                                                 set: { model.keywordFieldWantsFocus = $0 }),
                             onSubmit: add,
                             onMove: { step in
                                 if abs(step) == 1 { model.move(by: step) } else { model.moveRow(by: step / 2) }
                             },
                             onCancel: {
                                 text = ""
                                 done()
                             })
                    .frame(height: 30)
                Button {
                    model.toggleKeywordBar()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Hides the keywords (⌘K brings them back)")
            }
            // One row of fixed height whatever is selected, so the grid above never moves.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if photos.isEmpty {
                        Text("Nothing selected").foregroundStyle(.tertiary)
                    }
                    ForEach(onSelection, id: \.self) { item in chip(item) }
                    if !photos.isEmpty, !recent.isEmpty {
                        Text(onSelection.isEmpty ? "Recent:" : "· Recent:").foregroundStyle(.tertiary)
                        ForEach(Array(recent), id: \.self) { word in
                            Button {
                                model.addKeywords([word])
                            } label: {
                                Text("+ \(word)")
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.18), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Adds \(word) to the selected photos")
                        }
                    }
                }
                .font(.body)
            }
            .frame(height: 32)
        }
    }

    /// A keyword on the selection: bright when every selected photo has it,
    /// dim when only some do (click it to give it to all), × to take it off.
    private func chip(_ item: SelectionKeyword) -> some View {
        HStack(spacing: 6) {
            Text(item.keyword)
                .onTapGesture { if !item.onAll { model.addKeywords([item.keyword]) } }
            Button {
                model.removeKeyword(item.keyword)
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Takes \(item.keyword) off the selected photos")
        }
        .font(.body)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(item.onAll ? 0.35 : 0.12), in: Capsule())
        .foregroundStyle(item.onAll ? .primary : .secondary)
        .help(item.onAll ? "On every selected photo" : "On some of the selected photos; click to add it to all")
    }

    private func add(_ typed: String) {
        let words = Keywords.parse(typed)
        if !words.isEmpty { model.addKeywords(words) }
        text = ""
        done()
    }
}

/// The keyword field, AppKit's own so it can fill in a keyword used before
/// as it's typed, with the rest selected (SwiftUI's text field can't select
/// before macOS 15).
struct KeywordField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var enabled: Bool
    /// Keywords to fill in, in order of preference.
    var suggestions: [String]
    @Binding var wantsFocus: Bool
    var onSubmit: (String) -> Void
    /// The arrows, passed on to the grid: -1 and 1 left and right, -2 and 2 a row up and down.
    var onMove: (Int) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 17)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.typed = text
            context.coordinator.pending = nil
        }
        field.placeholderString = placeholder
        field.isEnabled = enabled
        if wantsFocus, enabled {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                wantsFocus = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeywordField
        /// What was last typed, without a filled-in ending.
        var typed = ""
        /// The filled-in ending on show: what was typed, and the whole text.
        var pending: (typed: String, completed: String)?

        init(_ parent: KeywordField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.stringValue
            // A comma typed over the filled-in ending takes it, as Tab does.
            if let pending, value == pending.typed + "," || value == pending.typed + ";" {
                return accept(pending.completed, in: field)
            }
            pending = nil
            let grew = value.count > typed.count
            typed = value
            if grew, let editor = field.currentEditor(), editor.selectedRange.location == (value as NSString).length,
               let done = Keywords.completion(of: value, among: parent.suggestions) {
                field.stringValue = done.text
                editor.selectedRange = NSRange(location: done.typedLength,
                                               length: (done.text as NSString).length - done.typedLength)
                pending = (value, done.text)
            }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                guard let pending else { return false }
                accept(pending.completed, in: field)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let value = field.stringValue
                pending = nil
                field.window?.makeFirstResponder(nil)
                parent.onSubmit(value)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                pending = nil
                field.window?.makeFirstResponder(nil)
                parent.onCancel()
                return true
            // ↑ ↓ always move in the grid, the field being one line; ← → too
            // while it's empty, and move in the text once something's typed.
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-2)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(2)
                return true
            case #selector(NSResponder.moveLeft(_:)) where field.stringValue.isEmpty:
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveRight(_:)) where field.stringValue.isEmpty:
                parent.onMove(1)
                return true
            default:
                return false
            }
        }

        /// Keeps the filled-in keyword and starts the next one.
        private func accept(_ completed: String, in field: NSTextField) {
            let value = completed + ", "
            pending = nil
            typed = value
            field.stringValue = value
            field.currentEditor()?.selectedRange = NSRange(location: (value as NSString).length, length: 0)
            parent.text = value
        }
    }
}

/// One shot: its thumbnail, a badge for RAW+JPEG, its name and stars. Clips
/// show a play mark and their length instead of stars, and scrub under the
/// pointer: left edge the start, right edge the end.
struct TileView: View {
    let shot: Shot
    let stars: Int?
    /// What the sharpness and exposure checks found, if they've looked.
    let check: AutoCheck?
    /// Shown as a tag and a count on the picture.
    let keywords: [String]
    /// Why it's flagged: orange chips.
    var problems: [QualityProblem] = []
    /// While calibrating, where the photographer disagreed: blue chips.
    var disagreements: [PhotoLabel] = []
    /// The sharpest frame of a burst: a green chip.
    var isBurstSharpest = false
    let isSelected: Bool
    let cache: ThumbnailCache
    @State private var thumbnail: Thumbnail?
    @State private var tried = false
    /// Hover scrubbing: where the pointer is across the tile (0 to 1), the
    /// frame there, and the one asked for next while a frame is being made.
    @State private var frames: ClipFrames?
    @State private var hoverShare: Double?
    @State private var hoverFrame: CGImage?
    @State private var making = false
    @State private var wanted: Double?
    @State private var width: CGFloat = 1

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(white: 0.07)
                if let hoverFrame, hoverShare != nil {
                    Image(decorative: hoverFrame, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if let thumbnail {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if tried {
                    Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if shot.kind == .video && hoverShare == nil {
                    Image(systemName: "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 3)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .topLeading) {
                if let badge = shot.badge { tag(badge).padding(4) }
            }
            .overlay(alignment: .topTrailing) {
                if !problems.isEmpty || isBurstSharpest || !disagreements.isEmpty {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 3) {
                            if isBurstSharpest { BurstChip() }
                            ForEach(problems, id: \.self) { CalibrationChip(text: $0.label) }
                        }
                        ForEach(disagreements, id: \.self) { CalibrationChip(text: $0.title, color: .cyan) }
                    }
                    .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let seconds = thumbnail?.duration {
                    tag(hoverShare.map { Self.length($0 * seconds) } ?? Self.length(seconds)).padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let hoverShare {
                    Rectangle().fill(Color.accentColor).frame(width: width * hoverShare, height: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !keywords.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "tag.fill")
                        Text("\(keywords.count)")
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(4)
                    .help(keywords.joined(separator: ", "))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            .onContinuousHover { phase in
                guard shot.kind == .video else { return }
                switch phase {
                case .active(let point):
                    let share = min(max(point.x / width, 0), 1)
                    hoverShare = share
                    scrub(to: share)
                case .ended:
                    hoverShare = nil
                    hoverFrame = nil
                    wanted = nil
                }
            }

            Text(shot.baseName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if shot.takesStars {
                StarsView(stars: stars, byApp: check?.stars != nil && check?.stars == stars)
                    .help(check.map { "Checked: score \(Int($0.score.rounded()))"
                        + ($0.stars != nil ? ", stars given by the app" : ", rated since") } ?? "")
            } else {
                Text(" ").font(.caption)
            }
        }
        // Every tile the same height, stars or not: the grid lays out rows it
        // hasn't shown yet from their first tile, and a tile of another height
        // makes the rows below shift as they're scrolled to.
        .frame(height: Self.height, alignment: .top)
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color(white: 0.11),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(isSelected ? Color.accentColor : Theme.panelEdge, lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        // Made only while the tile is on screen; scrolling away cancels it.
        .task(id: shot.id) {
            if let ready = await cache.cached(shot) {
                thumbnail = ready
            } else {
                let made = await cache.thumbnail(for: shot)
                if !Task.isCancelled {
                    thumbnail = made
                    tried = true
                }
            }
        }
    }

    /// One frame at a time: moves made while one is being made only keep the
    /// latest, so the frame never lags far behind the pointer.
    private func scrub(to share: Double) {
        guard !making else { return wanted = share }
        guard let url = shot.primary.destinations.first else { return }
        let frames = frames ?? ClipFrames(url: url, maxPixels: 400)
        self.frames = frames
        making = true
        Task {
            let image = await frames.frame(at: share)
            making = false
            guard hoverShare != nil else { return }
            if let image { hoverFrame = image }
            if let next = wanted {
                wanted = nil
                scrub(to: next)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }

    /// The picture, the name and the stars, with the spacing between them.
    static let height: CGFloat = 140 + 6 + 16 + 6 + 16

    /// 0:07, 1:05:09
    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Five stars, as many filled as given. 0 (the app's flag, later) shows all
/// empty, in orange so it stands out from 1. Nil (not rated yet) shows all
/// empty in grey.
struct StarsView: View {
    let stars: Int?
    /// Given by the sharpness and exposure checks, not by hand: drawn in blue
    /// rather than yellow.
    var byApp = false

    var body: some View {
        let filled = stars ?? 0
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= filled ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(n <= filled ? (byApp ? Self.appBlue : Color.yellow)
                                     : (stars == 0 ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.5)))
            }
        }
        .accessibilityLabel((stars.map { "\($0) stars" } ?? "Not rated") + (byApp ? ", given by the app" : ""))
    }

    static let appBlue = Color(red: 0.45, green: 0.72, blue: 1)
}

/// One shot filling the window. Space switches between fitted and 100%
/// (actual pixels, to check focus); clicking a spot zooms to 100% right there;
/// drag to look around. A clip plays instead: Space plays and pauses, the bar
/// at the bottom scrubs. Arrows, 0 to 5 and auto-advance work as in the grid;
/// Esc goes back.
struct LargeView: View {
    var model: GridModel
    @FocusState private var focused: Bool
    @State private var fitted: Thumbnail?
    /// Which shot `fitted` and `actual` belong to, so a slow load for one
    /// photo never shows on the next.
    @State private var fittedFor: String?
    @State private var actual: CGImage?
    @State private var actualFor: String?
    @State private var loadingActual = false
    /// How far the 100% view is panned from the centre, in points.
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    /// A spot clicked in the fitted picture, as a share of it from its centre,
    /// waiting for the 100% image to centre on it.
    @State private var zoomTarget: CGPoint?
    /// The clip showing, if the shot is one.
    @State private var clip: (any ClipControls)?
    @State private var clipFor: String?

    private var shot: Shot? { model.grid.focus.flatMap { model.grid.shot($0) } }
    private var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let clip, clipFor == shot?.id {
                    // The tile's frame shows until the clip's first frame covers it.
                    if let fitted {
                        Image(decorative: fitted.image, scale: 1).resizable().scaledToFit().padding(.vertical, 44)
                    }
                    if let playback = clip as? ClipPlayback {
                        ClipLayer(player: playback.player)
                            .padding(.vertical, 44)
                            .contentShape(Rectangle())
                            .onTapGesture { clip.togglePlay() }
                    } else if let mxf = clip as? MXFPlayback {
                        if let picture = mxf.picture {
                            Image(decorative: picture, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .padding(.vertical, 44)
                                .contentShape(Rectangle())
                                .onTapGesture { clip.togglePlay() }
                        }
                        if mxf.unavailable {
                            Text("This kind of MXF can't be previewed here yet. The copy is fine, and it opens in Premiere.")
                                .padding()
                                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                } else if model.actualSize, let actual, actualFor == shot?.id {
                    actualPixels(actual, in: geometry.size)
                } else if let fitted {
                    Image(decorative: fitted.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(.vertical, 44)
                        .onTapGesture(coordinateSpace: .local) { point in zoom(at: point, in: geometry.size) }
                } else {
                    ProgressView()
                }
                if model.actualSize && loadingActual {
                    ProgressView("Loading every pixel…").padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .overlay(alignment: .top) { bar }
            .overlay(alignment: .bottom) {
                if let clip, clipFor == shot?.id { ScrubBar(clip: clip) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            model.closeView()
            return .handled
        }
        .onKeyPress(.space) {
            if let clip, clipFor == shot?.id {
                clip.togglePlay()
                return .handled
            }
            if shot?.isPhoto == true { model.actualSize.toggle() }
            if !model.actualSize { offset = .zero }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.move(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.move(by: 1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
            guard let stars = Int(press.characters) else { return .ignored }
            model.rate(stars)
            return .handled
        }
        // A clip: , and . one frame back and forward; with Shift (< and >) ten.
        .onKeyPress(characters: CharacterSet(charactersIn: ",.<>")) { press in
            guard let clip, clipFor == shot?.id else { return .ignored }
            let frames: [String: Int] = [",": -1, ".": 1, "<": -10, ">": 10]
            guard let count = frames[press.characters] else { return .ignored }
            clip.step(by: count)
            return .handled
        }
        // The fitted picture, at the screen's size. The grid's tile shows at once
        // (no black screen while waiting), then the sharp one replaces it.
        .task(id: shot?.id) {
            guard let shot else { return model.closeView() }
            if fittedFor != shot.id {
                if let ready = await model.big.cached(shot) {
                    fitted = ready
                    fittedFor = shot.id
                } else {
                    // Never the previous photo under this one's name.
                    fitted = await model.cache.cached(shot)
                }
            }
            model.loadAhead(of: shot.id)
            guard fittedFor != shot.id else { return }
            let made = await model.big.thumbnail(for: shot)
            if !Task.isCancelled, let made {
                fitted = made
                fittedFor = shot.id
            }
        }
        // A player for a clip, made as it comes up and stopped when moving on or going back.
        .onChange(of: shot?.id, initial: true) { _, _ in
            clip?.stop()
            clip = nil
            clipFor = nil
            guard let shot, shot.kind == .video, let url = shot.primary.destinations.first else { return }
            let playback = makeClipControls(url: url)
            clip = playback
            clipFor = shot.id
            if model.playWhenShown { playback.togglePlay() }
            model.playWhenShown = false
        }
        .onDisappear { clip?.stop() }
        // Every pixel, only when asked for. The same spot stays in view from photo to photo.
        .task(id: "\(shot?.id ?? "")-\(model.actualSize)") {
            guard model.actualSize, let shot, shot.isPhoto, actualFor != shot.id else { return }
            loadingActual = true
            let made = await model.actualPixels(shot)
            if !Task.isCancelled {
                actual = made
                actualFor = shot.id
                loadingActual = false
                if let made { centreOnTarget(made) }
                model.loadAhead(of: shot.id)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            if let shot {
                Text(shot.baseName).font(.headline)
                if shot.takesStars {
                    let check = model.check(of: shot.id)
                    StarsView(stars: model.grid.stars[shot.id], byApp: check?.stars != nil && check?.stars == model.grid.stars[shot.id])
                    if model.isBurstSharpest(shot.id) { BurstChip() }
                    ForEach(model.problems(of: shot.id), id: \.self) { CalibrationChip(text: $0.label) }
                    if let calibration = model.calibration, let photo = calibration.byID[shot.id] {
                        ForEach(calibration.labels(for: shot.id), id: \.self) { CalibrationChip(text: $0.title, color: .cyan) }
                        Text(ScoreText.details(photo)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Menu("Label") {
                            LabelMenuItems(photo: photo, labels: calibration.labels(for: shot.id)) {
                                calibration.toggle($0, on: shot.id)
                            }
                        }
                        .fixedSize()
                        .help("Where the chips are wrong: Looks Fine on a flagged photo, or what's wrong with one that isn't")
                    }
                }
                if let words = model.grid.keywords[shot.id] {
                    Label(words.joined(separator: ", "), systemImage: "tag")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                if let index = model.grid.visible.firstIndex(where: { $0.id == shot.id }) {
                    Text("\(index + 1) of \(model.grid.visible.count)").foregroundStyle(.secondary)
                }
                if model.actualSize && shot.isPhoto { Text("100%").font(.caption.bold()).foregroundStyle(.yellow) }
            }
            Spacer()
            Text(shot?.kind == .video
                 ? "Space play/pause · , . frame (⇧ ten) · drag the bar to scrub · ← → · Esc back"
                 : "Space 100% · click to zoom there · drag to look around · ← → · 0–5 · Esc back")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Back to Grid") { model.closeView() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7))
    }

    /// The image at one image pixel per screen pixel, panned by `offset`.
    private func actualPixels(_ image: CGImage, in view: CGSize) -> some View {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return Image(decorative: image, scale: scale)
            .frame(width: size.width, height: size.height)
            .offset(clamped(offset, image: size, view: view))
            .gesture(DragGesture()
                .onChanged { drag in
                    let start = dragStart ?? clamped(offset, image: size, view: view)
                    dragStart = start
                    offset = clamped(CGSize(width: start.width + drag.translation.width,
                                            height: start.height + drag.translation.height), image: size, view: view)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture {
                model.actualSize = false
                offset = .zero
            }
    }

    /// Clicked in the fitted picture: show that spot at 100%.
    private func zoom(at point: CGPoint, in view: CGSize) {
        guard let fitted, shot?.isPhoto == true else { return }
        let area = CGSize(width: view.width, height: view.height - 88)
        let ratio = min(area.width / CGFloat(fitted.image.width), area.height / CGFloat(fitted.image.height))
        let shown = CGSize(width: CGFloat(fitted.image.width) * ratio, height: CGFloat(fitted.image.height) * ratio)
        // Where the click was, from the picture's centre, as a share of the picture.
        zoomTarget = CGPoint(x: (point.x - view.width / 2) / shown.width,
                             y: (point.y - 44 - area.height / 2) / shown.height)
        model.actualSize = true
        if let actual { centreOnTarget(actual) }
    }

    private func centreOnTarget(_ image: CGImage) {
        guard let target = zoomTarget else { return }
        offset = CGSize(width: -target.x * CGFloat(image.width) / scale, height: -target.y * CGFloat(image.height) / scale)
        zoomTarget = nil
    }

    /// Keeps the picture covering the view: no panning past its edges.
    private func clamped(_ offset: CGSize, image: CGSize, view: CGSize) -> CGSize {
        let maxX = max(0, (image.width - view.width) / 2)
        let maxY = max(0, (image.height - view.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }
}
