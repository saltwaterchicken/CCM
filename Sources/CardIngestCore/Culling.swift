import Foundation

/// Which shots the grid shows, by their stars.
public enum StarFilter: Hashable, Sendable {
    case all
    /// This many stars or more, e.g. 1: the keepers once the auto-checks flag the rest.
    case atLeast(Int)
    /// 0 stars: the ones the app (later) or the photographer flagged.
    case flagged

    public static let choices: [StarFilter] = [.all, .atLeast(1), .atLeast(2), .atLeast(3), .atLeast(4), .atLeast(5), .flagged]

    public var label: String {
        switch self {
        case .all: "All"
        case let .atLeast(n): n >= 5 ? "★5" : "★\(n)+"
        case .flagged: "0★"
        }
    }

    /// Videos and unrated photos have no stars, so they only show with All.
    func shows(_ shot: Shot, stars: Int?) -> Bool {
        switch self {
        case .all: true
        case let .atLeast(n): shot.isRatable && (stars ?? -1) >= n
        case .flagged: shot.isRatable && stars == 0
        }
    }
}

/// The culling grid's state: which shots are showing, their stars, and what's
/// selected. Clicks and keys work like Photo Mechanic's: click, Shift-click and
/// Cmd-click select; 0 to 5 set the stars of the selection, and with one photo
/// selected move on to the next photo; left and right arrows move along.
/// Writing the stars to the sidecars is the caller's job (see `rate`). With a
/// filter on, clicks, keys and Select All act only on the shots it shows.
public struct CullGrid: Equatable, Sendable {
    /// Every shot of the Copy, in the order they landed.
    public private(set) var shots: [Shot] = []
    /// What the grid shows; changing it drops hidden shots from the selection.
    public var filter: StarFilter = .all {
        didSet { keepSelectionVisible() }
    }
    public private(set) var stars: [String: Int] = [:]
    public private(set) var selected: Set<String> = []
    /// The shot the keys act from: the last one clicked or moved to.
    public private(set) var focus: String?
    /// Where a Shift-click range starts.
    private var anchor: String?
    private var positions: [String: Int] = [:]

    public init() {}

    public func shot(_ id: String) -> Shot? {
        shots.first { $0.id == id }
    }

    /// The shots the filter shows, in landing order.
    public var visible: [Shot] {
        shots.filter { filter.shows($0, stars: stars[$0.id]) }
    }

    /// What the Open button sends: the selected shots, or everything showing
    /// when nothing is selected. One file per shot (the RAW of a RAW+JPEG
    /// pair; editors find its JPEG and sidecar themselves).
    public var toOpen: [URL] {
        let showing = visible
        let picked = showing.filter { selected.contains($0.id) }
        return (picked.isEmpty ? showing : picked).compactMap { $0.primary.destinations.first }
    }

    /// A shot whose files are all in. Shots are kept in landing order even if
    /// two arrive the other way round.
    public mutating func add(_ landed: LandedShot) {
        let id = landed.shot.id
        if let stars = landed.stars { self.stars[id] = stars }
        if let existing = shots.firstIndex(where: { $0.id == id }) {
            shots[existing] = landed.shot
            return
        }
        positions[id] = landed.position
        let index = shots.firstIndex { positions[$0.id, default: .max] > landed.position } ?? shots.endIndex
        shots.insert(landed.shot, at: index)
    }

    public mutating func click(_ id: String, shift: Bool = false, command: Bool = false) {
        let shots = visible
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        if shift, let anchor, let start = shots.firstIndex(where: { $0.id == anchor }) {
            selected = Set(shots[min(start, index)...max(start, index)].map(\.id))
        } else if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        focus = id
    }

    /// Left (-1) or right (+1): selects just the next shot along. With nothing
    /// selected yet, starts at the first (or last) one.
    public mutating func move(by step: Int) {
        let shots = visible
        guard !shots.isEmpty else { return }
        let target: Int
        if let focus, let current = shots.firstIndex(where: { $0.id == focus }) {
            target = min(max(current + step, 0), shots.count - 1)
        } else {
            target = step >= 0 ? 0 : shots.count - 1
        }
        select(shots[target].id)
    }

    public mutating func selectAll() {
        let shots = visible
        selected = Set(shots.map(\.id))
        if focus == nil || !selected.contains(focus!) { focus = shots.first?.id }
    }

    /// Sets the stars of the selected photos (videos have none) and returns
    /// those shots, whose sidecars the caller then writes. With one photo
    /// selected, moves on to the next photo, skipping videos, so a card can be
    /// rated with the number keys alone. A photo rated out of the filter
    /// (0 with "★1+" on) disappears; the next photo shown is selected instead,
    /// or the one before it at the end.
    @discardableResult
    public mutating func rate(_ stars: Int) -> [Shot] {
        let stars = min(5, max(0, stars))
        let before = visible
        let targets = before.filter { selected.contains($0.id) && $0.isRatable }
        for shot in targets { self.stars[shot.id] = stars }
        guard let focus, let current = before.firstIndex(where: { $0.id == focus }) else { return targets }
        let after = visible
        let shown = Set(after.map(\.id))
        if selected.count == 1 || !shown.contains(focus) {
            let next = before[(current + 1)...].first { shown.contains($0.id) && $0.isRatable }
                ?? (shown.contains(focus) ? nil : before[..<current].last { shown.contains($0.id) })
            if let next { select(next.id) }
        }
        keepSelectionVisible()
        return targets
    }

    /// Drops hidden shots from the selection; the focus moves to a shown one.
    private mutating func keepSelectionVisible() {
        let shown = Set(visible.map(\.id))
        selected = selected.intersection(shown)
        if let focus, !shown.contains(focus) {
            self.focus = visible.first { selected.contains($0.id) }?.id
            anchor = self.focus
        }
    }

    private mutating func select(_ id: String) {
        selected = [id]
        anchor = id
        focus = id
    }
}

/// A card folder from an earlier import, back in the grid: after a crash, or
/// to carry on culling another day, without putting the card back in.
public enum ImportedFolder {
    /// The folder's shots, in name order, with the stars from their sidecars
    /// (or, for a JPEG or HEIC with no RAW and no sidecar, embedded in it).
    /// When the backup has a folder of the same name, its copies are included,
    /// so stars changed now are saved in both, as during a Copy.
    public static func shots(in folder: URL, backupRoot: URL?, fileTypes: FileTypes) throws -> [LandedShot] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                               options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
            .filter { fileTypes.includes($0) && !Receipt.isReceipt($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let backup = backupRoot.map { $0.appendingPathComponent(folder.lastPathComponent, isDirectory: true) }
            .flatMap { $0.standardizedFileURL == folder.standardizedFileURL ? nil : $0 }
        let files = names.map { name -> CopiedFile in
            let main = folder.appendingPathComponent(name)
            let size = (try? main.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            var destinations = [main]
            if let copy = backup?.appendingPathComponent(name), fm.fileExists(atPath: copy.path) { destinations.append(copy) }
            return CopiedFile(newName: name, originalPath: name, size: size, originalModified: nil, checksum: "",
                              destinations: destinations, alreadyThere: true)
        }
        // A sidecar with no picture of its own isn't a shot.
        let shots = ShotList(fileTypes: fileTypes, files: files).shots.filter { $0.kind != .sidecar && $0.kind != .other }
        return shots.enumerated().map { index, shot in
            LandedShot(shot: shot, stars: Stars.found(for: shot), position: index)
        }
    }
}
