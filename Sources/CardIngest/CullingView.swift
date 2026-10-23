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
    var backupRoot: URL?
    var fileTypes = FileTypes()
    private var session: UUID?
    private let writes = DispatchQueue(label: "Card Ingest stars", qos: .userInitiated)

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
    }

    /// An earlier import back in the grid, with its stars, to carry on culling.
    func load(_ folder: URL) {
        do {
            let shots = try ImportedFolder.shots(in: folder, backupRoot: backupRoot, fileTypes: fileTypes)
            begin(UUID(), cardName: "Loaded", folder: folder)
            for shot in shots { grid.add(shot) }
            if shots.isEmpty { problem = "No photos or clips in \(folder.lastPathComponent)." }
        } catch {
            problem = "Couldn't load \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func begin(_ session: UUID, cardName: String, folder: URL?) {
        self.session = session
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
        if actualSize, let next, next.isRatable {
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
        backupRoot = settings.backupRootURL
        fileTypes = settings.fileTypes
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
    func view(_ id: String? = nil, actualSize: Bool = false) {
        if let id, grid.focus != id { grid.click(id) }
        guard grid.focus != nil else { return }
        self.actualSize = actualSize
        isViewing = true
    }

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

    func rate(_ stars: Int) {
        let shots = grid.rate(stars)
        guard !shots.isEmpty else { return }
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
                                TileView(shot: shot, stars: model.grid.stars[shot.id],
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
                    } action: { model.columns = $0 }
                    .onChange(of: model.grid.focus) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
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
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelEdge, lineWidth: 1))
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
                    Text("0–5 rate · arrows move · double-click or Space to look closer · ⌘A all")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Spacer()
                }
                Button("Load Folder…", action: chooseFolder)
                    .help("Shows an earlier card's folder here with its stars, to carry on culling without the card.")
            }
            if !model.grid.shots.isEmpty {
                HStack {
                    Picker("Show", selection: Binding(get: { model.filter }, set: { model.filter = $0 })) {
                        ForEach(StarFilter.choices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    let count = model.grid.toOpen.count
                    Button("Open \(count) in \(model.applicationName)") { model.openInApplication() }
                        .disabled(count == 0)
                        .help("Opens the selected photos, or all the photos shown when none are selected. "
                              + "The app is set by openWith in the settings file.")
                }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose a card folder from an earlier import"
        panel.directoryURL = model.folder?.deletingLastPathComponent() ?? model.destinationRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url)
            focused = true
        }
    }
}

/// One shot: its thumbnail, a badge for RAW+JPEG, its name and stars. Clips
/// show a play mark and their length instead of stars.
struct TileView: View {
    let shot: Shot
    let stars: Int?
    let isSelected: Bool
    let cache: ThumbnailCache
    @State private var thumbnail: Thumbnail?
    @State private var tried = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(white: 0.07)
                if let thumbnail {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if tried {
                    Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if shot.kind == .video {
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
            .overlay(alignment: .bottomTrailing) {
                if let seconds = thumbnail?.duration { tag(Self.length(seconds)).padding(4) }
            }

            Text(shot.baseName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if shot.isRatable {
                StarsView(stars: stars)
            } else {
                Text(" ").font(.caption)
            }
        }
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

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }

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

    var body: some View {
        let filled = stars ?? 0
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= filled ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(n <= filled ? Color.yellow : (stars == 0 ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.5)))
            }
        }
        .accessibilityLabel(stars.map { "\($0) stars" } ?? "Not rated")
    }
}

/// One shot filling the window. Space switches between fitted and 100%
/// (actual pixels, to check focus); clicking a spot zooms to 100% right there;
/// drag to look around. Arrows, 0 to 5 and auto-advance work as in the grid;
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

    private var shot: Shot? { model.grid.focus.flatMap { model.grid.shot($0) } }
    private var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if model.actualSize, let actual, actualFor == shot?.id {
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
            if shot?.isRatable == true { model.actualSize.toggle() }
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
        // Every pixel, only when asked for. The same spot stays in view from photo to photo.
        .task(id: "\(shot?.id ?? "")-\(model.actualSize)") {
            guard model.actualSize, let shot, actualFor != shot.id else { return }
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
                if shot.isRatable { StarsView(stars: model.grid.stars[shot.id]) }
                if let index = model.grid.visible.firstIndex(where: { $0.id == shot.id }) {
                    Text("\(index + 1) of \(model.grid.visible.count)").foregroundStyle(.secondary)
                }
                if model.actualSize { Text("100%").font(.caption.bold()).foregroundStyle(.yellow) }
            }
            Spacer()
            Text("Space 100% · click to zoom there · drag to look around · ← → · 0–5 · Esc back")
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
        guard let fitted, shot?.isRatable == true else { return }
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
