import Foundation

/// What macOS tells us about a mounted volume, plus whether it has a DCIM folder
/// (shown for information only; it doesn't decide anything).
public struct VolumeInfo: Equatable, Sendable {
    public var url: URL
    public var name: String
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isLocal: Bool
    public var isRootFileSystem: Bool
    public var hasDCIM: Bool

    public init(url: URL, name: String, isRemovable: Bool, isEjectable: Bool, isInternal: Bool,
                isLocal: Bool, isRootFileSystem: Bool, hasDCIM: Bool) {
        self.url = url
        self.name = name
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRootFileSystem = isRootFileSystem
        self.hasDCIM = hasDCIM
    }

    /// Reads the volume's properties from macOS.
    public static func read(_ url: URL) throws -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        var isDirectory: ObjCBool = false
        let dcim = url.appendingPathComponent("DCIM", isDirectory: true)
        let hasDCIM = FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return VolumeInfo(
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            // Unknown counts as internal, so we never guess our way onto a drive.
            isInternal: values.volumeIsInternal ?? true,
            isLocal: values.volumeIsLocal ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? true,
            hasDCIM: hasDCIM
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
        if !volume.isRemovable && !volume.isEjectable { return .ignored("This drive isn't removable media.") }
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

    public init(relativePath: String, size: Int64) {
        self.relativePath = relativePath
        self.size = size
    }
}

public enum CardScanner {
    /// Lists every camera file anywhere on the card, sorted by path. That covers
    /// DCIM and the other folders some cameras use for video (such as Sony's
    /// PRIVATE/M4ROOT). Hidden files and folders (macOS's "._" files, .Trashes,
    /// .Spotlight-V100) and other file types are skipped.
    public static func scan(cardRoot: URL, fileTypes: FileTypes) throws -> [CardFile] {
        let root = cardRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
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
            files.append(CardFile(relativePath: String(path.dropFirst(root.path.count + 1)),
                                  size: Int64(values.fileSize ?? 0)))
        }
        if let failure = failure ?? readError.error { throw failure }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
