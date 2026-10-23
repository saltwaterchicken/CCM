import Foundation

/// One card file and the name its copy gets.
public struct PlannedFile: Equatable, Sendable {
    public var source: CardFile
    /// Name inside the card folder, e.g. "2026-10-14-ES_1234.CR3".
    public var newName: String

    public init(source: CardFile, newName: String) {
        self.source = source
        self.newName = newName
    }
}

/// Where a card goes and what every file is called, worked out before copying.
public struct ImportPlan: Sendable {
    /// The `{iseq}` this card uses.
    public var importNumber: Int
    /// The card folder: in the destination, then in the backup if set.
    public var folders: [URL]
    /// Only the files no earlier import brought in. Empty when the card has
    /// nothing new; then `folders` is empty too and there's nothing to copy.
    public var files: [PlannedFile]
    /// What's new on the card and what was already imported (and is skipped).
    public var check: CardCheck

    public var nothingNew: Bool { files.isEmpty }

    /// What `nextImportNumber` becomes once this copy has verified. It never
    /// goes down, and a card with nothing new doesn't use up a number.
    public func nextImportNumber(after current: Int) -> Int {
        nothingNew ? current : max(current, importNumber + 1)
    }
}

public enum PlanError: Error, LocalizedError, Equatable {
    case folderHoldsAnotherCard(folder: String)

    public var errorDescription: String? {
        switch self {
        case let .folderHoldsAnotherCard(folder):
            return "\(folder) already holds files from another card, and the folder name has no {iseq} to make a new one. "
                + "Add {iseq} to the folder name so each card gets its own folder."
        }
    }
}

extension IngestSettings {
    /// The card folder's name, e.g. 2026-10-23-ES001.
    public func cardFolderName(importNumber: Int? = nil, today: Date = Date(), calendar: Calendar = .current) throws -> String {
        try NameTemplate(folderName).render(
            TemplateValues(today: today, importNumber: importNumber ?? nextImportNumber), calendar: calendar)
    }
}

/// Decides the card folder, the import number and every file's new name.
/// It only reads: the card, and what's already in the destination.
public enum ImportPlanner {
    /// Reads when a file was taken; nil when it can't tell.
    public typealias CaptureDateReader = @Sendable (URL, FileKind) -> Date?

    public static func plan(
        cardRoot: URL,
        cardName: String,
        files: [CardFile],
        settings: IngestSettings,
        today: Date = Date(),
        calendar: Calendar = .current,
        captureDate: CaptureDateReader? = nil,
        history: ImportHistory? = nil
    ) throws -> ImportPlan {
        // Catch typos before anything is read or copied.
        _ = try settings.cardFolderName(today: today, calendar: calendar)
        try NameTemplate(settings.renamePattern).validate(forFiles: true)

        // Files an earlier import brought in are skipped (card put back in, or Copy pressed twice).
        let check = (history ?? ImportHistory.load(from: settings.destinationRootURL)).check(files)
        if check.newFiles.isEmpty {
            return ImportPlan(importNumber: settings.nextImportNumber, folders: [], files: [], check: check)
        }

        let read = captureDate ?? { url, kind in CaptureDate.read(url, kind: kind, timeZone: calendar.timeZone) }
        let groups = group(check.newFiles, cardRoot: cardRoot, fileTypes: settings.fileTypes, today: today, read: read)
        let names = { (number: Int) in
            try rename(groups, pattern: settings.renamePattern, today: today, importNumber: number, calendar: calendar)
        }
        let roots = [settings.destinationRootURL] + [settings.backupRootURL].compactMap { $0 }

        var number = settings.nextImportNumber
        while true {
            let folderName = try settings.cardFolderName(importNumber: number, today: today, calendar: calendar)
            let folders = roots.map { $0.appendingPathComponent(folderName, isDirectory: true) }
            let planned = try names(number)
            if let taken = folders.first(where: { !holdsNothingElse($0, planned) }) {
                // Without {iseq} the next number gives the same folder.
                let next = try settings.cardFolderName(importNumber: number + 1, today: today, calendar: calendar)
                if next == folderName { throw PlanError.folderHoldsAnotherCard(folder: taken.path) }
                number += 1
                continue
            }
            return ImportPlan(importNumber: number, folders: folders, files: planned, check: check)
        }
    }

    /// Files that share a folder and base name on the card (RAW+JPEG,
    /// sidecars), with the capture date of the picture or clip they belong to.
    struct Group {
        var members: [CardFile]
        /// The picture or clip the others belong to; its camera name gives `{frame4}`.
        var primary: CardFile
        var capture: Date
    }

    static func group(_ files: [CardFile], cardRoot: URL, fileTypes: FileTypes, today: Date,
                      read: CaptureDateReader) -> [Group] {
        let byKey = Dictionary(grouping: files) { file in
            ((file.relativePath as NSString).deletingPathExtension).lowercased()
        }
        let groups = byKey.values.map { members -> Group in
            let rank = { (f: CardFile) in fileTypes.kind(of: f.relativePath).rank }
            let ordered = members.sorted { (rank($0), $0.relativePath) < (rank($1), $1.relativePath) }
            let primary = ordered[0]
            // The RAW's date, else the JPEG's, else the clip's; sidecars have none.
            var fromFile: Date?
            for f in ordered where fromFile == nil {
                let kind = fileTypes.kind(of: f.relativePath)
                if kind != .sidecar { fromFile = read(cardRoot.appendingPathComponent(f.relativePath), kind) }
            }
            let modified = (try? FileManager.default.attributesOfItem(
                atPath: cardRoot.appendingPathComponent(primary.relativePath).path)[.modificationDate]) as? Date
            return Group(members: members.sorted { $0.relativePath < $1.relativePath },
                         primary: primary, capture: fromFile ?? modified ?? today)
        }
        // Earlier pictures claim a name first, so a later clash gets the -2.
        return groups.sorted { ($0.capture, $0.primary.relativePath) < ($1.capture, $1.primary.relativePath) }
    }

    static func rename(_ groups: [Group], pattern: String, today: Date, importNumber: Int,
                       calendar: Calendar) throws -> [PlannedFile] {
        let template = NameTemplate(pattern)
        var taken = Set<String>()
        var planned: [PlannedFile] = []
        for group in groups {
            let original = (group.primary.relativePath as NSString).lastPathComponent
            let base = try template.render(TemplateValues(today: today, importNumber: importNumber,
                                                          capture: group.capture, originalName: original),
                                           calendar: calendar)
            var unique = base
            var n = 2
            // Mac drives usually ignore case, so IMG and img would clash.
            while taken.contains(unique.lowercased()) {
                unique = "\(base)-\(n)"
                n += 1
            }
            taken.insert(unique.lowercased())
            for file in group.members {
                let ext = (file.relativePath as NSString).pathExtension
                planned.append(PlannedFile(source: file, newName: ext.isEmpty ? unique : "\(unique).\(ext)"))
            }
        }
        return planned.sorted { $0.newName.localizedStandardCompare($1.newName) == .orderedAscending }
    }

    /// True when the folder doesn't exist yet, or only holds this card's own
    /// files from an earlier, unfinished copy (same names and sizes).
    static func holdsNothingElse(_ folder: URL, _ planned: [PlannedFile]) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        else { return true }
        let sizes = Dictionary(planned.map { ($0.newName.lowercased(), $0.source.size) }, uniquingKeysWith: { a, _ in a })
        return entries.allSatisfy { url in
            let name = url.lastPathComponent
            if Receipt.isReceipt(name) { return true }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return false }
            return sizes[name.lowercased()] == Int64(values.fileSize ?? -1)
        }
    }
}

/// What kind of camera file a name is, by its extension.
public enum FileKind: Sendable {
    case raw, photo, video, sidecar, other

    /// Which file in a RAW+JPEG+sidecar set the others belong to: lowest first.
    var rank: Int {
        switch self {
        case .raw: 0
        case .photo: 1
        case .video: 2
        case .sidecar: 3
        case .other: 4
        }
    }
}

extension FileTypes {
    public func kind(of fileName: String) -> FileKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let has = { (list: [String]) in list.contains { $0.lowercased() == ext } }
        if has(raw) { return .raw }
        if has(photo) { return .photo }
        if has(video) { return .video }
        if has(sidecar) { return .sidecar }
        return .other
    }
}
