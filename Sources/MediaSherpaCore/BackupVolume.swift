import Foundation

/// Where the backup folder is right now, for the server light before Copy.
public enum BackupVolume: Equatable, Sendable {
    /// No backup folder in the settings.
    case notSet
    /// Its drive or share isn't mounted.
    case missing
    /// The share isn't mounted, but a plain folder of the same name sits in
    /// /Volumes on the Mac's own drive (left by something that wrote there
    /// while it was away), so a copy would fill the Mac instead of the server.
    case standIn
    /// On a drive plugged into this Mac, not a server.
    case localDrive(name: String)
    /// On a mounted network share: the server.
    case server(name: String)

    /// Looks at the backup folder, or the nearest folder above it that
    /// exists (the card folders inside it are made on Copy). Can take a
    /// moment on a network share, so call it off the main thread.
    public static func check(_ folder: URL?) -> BackupVolume {
        guard let folder else { return .notSet }
        var existing = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { return .missing }
            existing = parent
        }
        // "/Volumes/Macintosh HD" is a shortcut to the Mac's own drive, so follow shortcuts first.
        existing = existing.resolvingSymlinksInPath()
        let parts = existing.pathComponents
        let inVolumes = parts.count >= 2 && parts[1] == "Volumes"
        // /Volumes itself is on every Mac: the share is missing when that's as far as it got.
        if inVolumes && parts.count < 3 { return .missing }
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIsLocalKey, .volumeNameKey]
        guard let values = try? existing.resourceValues(forKeys: keys), let volume = values.volume else { return .missing }
        if inVolumes && volume.path == "/" { return .standIn }
        let name = values.volumeName ?? volume.lastPathComponent
        return values.volumeIsLocal == false ? .server(name: name) : .localDrive(name: name)
    }
}
