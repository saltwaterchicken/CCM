import Foundation

/// What macOS tells us about a mounted volume, plus whether it has a DCIM folder
/// (it doesn't decide what counts as a card, only whether files may go to its Trash).
public struct VolumeInfo: Equatable, Sendable {
    public var url: URL
    public var name: String
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isLocal: Bool
    public var isRootFileSystem: Bool
    public var hasDCIM: Bool
    /// Has a folder cameras keep video in (see `videoFolders`).
    public var hasVideoFolder: Bool
    /// True for a locked card (the switch on an SD card's side).
    public var isReadOnly: Bool

    public init(url: URL, name: String, isRemovable: Bool, isEjectable: Bool, isInternal: Bool,
                isLocal: Bool, isRootFileSystem: Bool, hasDCIM: Bool, hasVideoFolder: Bool = false, isReadOnly: Bool = false) {
        self.url = url
        self.name = name
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRootFileSystem = isRootFileSystem
        self.hasDCIM = hasDCIM
        self.hasVideoFolder = hasVideoFolder
        self.isReadOnly = isReadOnly
    }

    /// Where cameras that shoot video can keep it outside DCIM: Sony, Canon Cinema,
    /// Panasonic and AVCHD. Specific paths, as "PRIVATE" or "CONTENTS" alone could
    /// be on any drive.
    public static let videoFolders = [
        "PRIVATE/M4ROOT", "PRIVATE/XDROOT", "XDROOT", "PRIVATE/AVCHD", "AVCHD",
        "CONTENTS/CLIPS001", "CONTENTS/VIDEO",
    ]

    /// Reads the volume's properties from macOS.
    public static func read(_ url: URL) throws -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        func hasFolder(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            let folder = url.appendingPathComponent(path, isDirectory: true)
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return VolumeInfo(
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            // Unknown counts as internal, so we never guess our way onto a drive.
            isInternal: values.volumeIsInternal ?? true,
            isLocal: values.volumeIsLocal ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? true,
            hasDCIM: hasFolder("DCIM"),
            hasVideoFolder: videoFolders.contains(where: hasFolder),
            isReadOnly: values.volumeIsReadOnly ?? false
        )
    }
}

/// Why a volume is or isn't treated as a camera card.
public enum CardVerdict: Equatable, Sendable {
    case card
    case ignored(String)

    public var isCard: Bool { self == .card }
}

/// The one place that decides whether a volume is a camera card. Any removable
/// or ejectable drive counts, with or without a DCIM folder, except the Mac's
/// own drives, network volumes, and drives holding the destination or backup.
/// So does an external drive that's neither, if it has a camera's folders:
/// CFexpress and XQD cards in a PCIe or Thunderbolt reader report as fixed and
/// not ejectable, exactly as a Thunderbolt SSD does.
/// Everything else in the app goes through this, so the rule lives in one spot.
public enum CardRules {
    /// - Parameter protectedFolders: the destination and backup folders. A volume
    ///   that holds either of them is never a card.
    public static func verdict(for volume: VolumeInfo, protectedFolders: [URL]) -> CardVerdict {
        if volume.isRootFileSystem { return .ignored("This is the Mac's startup drive.") }
        if !volume.isLocal { return .ignored("This is a network volume.") }
        // A Mac's built-in SD slot reports its cards as internal, so "internal"
        // only rules a drive out when the media isn't removable.
        if volume.isInternal && !volume.isRemovable { return .ignored("This is an internal drive.") }
        if !volume.isRemovable && !volume.isEjectable && !volume.hasDCIM && !volume.hasVideoFolder {
            return .ignored("This external drive has no camera folders (DCIM or a camera's video folder).")
        }
        let volumePath = volume.url.standardizedFileURL.path
        for folder in protectedFolders {
            let path = folder.standardizedFileURL.path
            if path == volumePath || path.hasPrefix(volumePath.hasSuffix("/") ? volumePath : volumePath + "/") {
                return .ignored("This drive holds your destination or backup folder.")
            }
        }
        return .card
    }
}

/// One file found on a card.
public struct CardFile: Equatable, Sendable {
    /// Path inside the card, for example "DCIM/100CANON/IMG_0001.CR3".
    public var relativePath: String
    public var size: Int64
    /// When the camera last wrote the file; together with the path and size it
    /// recognises a file an earlier import already brought in.
    public var modified: Date?

    public init(relativePath: String, size: Int64, modified: Date? = nil) {
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
    }
}

public enum CardScanner {
    /// Lists every camera file anywhere on the card, sorted by path. That covers
    /// DCIM and the other folders some cameras use for video (such as Sony's
    /// PRIVATE/M4ROOT). Hidden files and folders (macOS's "._" files, .Trashes,
    /// .Spotlight-V100), other file types and the camera's own index files
    /// (see `isCameraIndex`) are skipped.
    public static func scan(cardRoot: URL, fileTypes: FileTypes) throws -> [CardFile] {
        let root = cardRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        // A folder that can't be read must stop the scan, not be quietly skipped.
        final class FirstError: @unchecked Sendable { var error: Error? }
        let readError = FirstError()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                readError.error = readError.error ?? error
                return false
            }
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var failure: Error?
        var files: [CardFile] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, fileTypes.includes(url.lastPathComponent) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path + "/") else {
                failure = CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: path])
                break
            }
            let relativePath = String(path.dropFirst(root.path.count + 1))
            if isCameraIndex(relativePath) { continue }
            files.append(CardFile(relativePath: relativePath,
                                  size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
        }
        if let failure = failure ?? readError.error { throw failure }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// True for files the camera keeps for itself, which are never copied or
    /// trashed: inside Sony's video folders (M4ROOT, and XDROOT on pro
    /// cameras) only CLIP and SUB hold clips and their .XML sidecars; the rest
    /// is the camera's index (MEDIAPRO.XML, STATUS.BIN, CUEUP.XML) and clip
    /// thumbnails (THMBNL), which it rebuilds or complains about if they go.
    public static func isCameraIndex(_ relativePath: String) -> Bool {
        let folders = relativePath.split(separator: "/").dropLast().map { $0.uppercased() }
        guard let root = folders.lastIndex(where: { $0 == "M4ROOT" || $0 == "XDROOT" }) else { return false }
        let inside = folders.dropFirst(root + 1)
        return !(inside.first == "CLIP" || inside.first == "SUB")
    }
}
