import Foundation

/// One picture or clip as the photographer sees it: the copies that share a
/// new base name, e.g. `2026-10-14-ES_1234.CR3`, `.JPG` and `.xmp`. The planner
/// gives a RAW+JPEG pair and its sidecars the same base name, so that is what
/// ties them together here.
public struct Shot: Equatable, Sendable, Identifiable {
    /// The new name without its extension, e.g. "2026-10-14-ES_1234".
    public var baseName: String
    /// Every copy in the shot, in the order they were verified.
    public var files: [CopiedFile]
    /// The file the tile shows: the RAW, else the JPEG/HEIC, else the clip,
    /// else (until one of those lands) a sidecar.
    public var primary: CopiedFile
    public var kind: FileKind
    /// What the tile's badge says when a shot is more than one picture file,
    /// e.g. "RAW+JPG"; nil for a single file. Sidecars don't count.
    public var badge: String?

    /// Mac drives usually ignore case, so the id does too.
    public var id: String { baseName.lowercased() }

    /// Videos get no star.
    public var isRatable: Bool { kind == .raw || kind == .photo }

    /// The sidecar that holds the shot's stars: the `.xmp` that came off the
    /// card if there is one (its rating is updated inside it), otherwise a new
    /// one named after the shot.
    public var xmpName: String {
        files.first { ($0.newName as NSString).pathExtension.lowercased() == "xmp" }?.newName ?? baseName + ".xmp"
    }
}

/// The shots of one Copy, built up file by file as each copy is verified.
public struct ShotList: Equatable, Sendable {
    public private(set) var shots: [Shot] = []
    private var positions: [String: Int] = [:]
    private let fileTypes: FileTypes

    public init(fileTypes: FileTypes, files: [CopiedFile] = []) {
        self.fileTypes = fileTypes
        for file in files { add(file) }
    }

    /// Adds a verified copy to its shot, making the shot if it's the first of
    /// its files, and says where that shot is in `shots`. Shots stay in the
    /// order their first file landed, so tiles don't jump around.
    @discardableResult
    public mutating func add(_ file: CopiedFile) -> Int {
        let base = (file.newName as NSString).deletingPathExtension
        let kind = fileTypes.kind(of: file.newName)
        guard let index = positions[base.lowercased()] else {
            shots.append(Shot(baseName: base, files: [file], primary: file, kind: kind, badge: nil))
            positions[base.lowercased()] = shots.count - 1
            return shots.count - 1
        }
        var shot = shots[index]
        shot.files.append(file)
        if kind.rank < shot.kind.rank {
            shot.primary = file
            shot.kind = kind
        }
        shot.badge = badge(for: shot.files)
        shots[index] = shot
        return index
    }

    /// "RAW+JPG", "RAW+HEIC", "JPG+MOV" ...: the picture and clip files,
    /// RAW first. Nil when there's only one of them.
    private func badge(for files: [CopiedFile]) -> String? {
        let pictures = files
            .map { (file: $0, kind: fileTypes.kind(of: $0.newName)) }
            .filter { $0.kind != .sidecar && $0.kind != .other }
            .sorted { ($0.kind.rank, $0.file.newName) < ($1.kind.rank, $1.file.newName) }
        guard pictures.count > 1 else { return nil }
        return pictures.map { $0.kind == .raw ? "RAW" : ($0.file.newName as NSString).pathExtension.uppercased() }
            .joined(separator: "+")
    }
}
