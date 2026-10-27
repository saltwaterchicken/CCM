import Foundation
import ImageIO

/// Star ratings, kept as the standard `xmp:Rating` in each shot's `.xmp`
/// sidecar next to its copies, so Lightroom, Bridge and Photo Mechanic all see
/// them. RAW files are never rewritten. Only the sidecars in the destination
/// and backup are written, never anything on the card. Every RAW gets a
/// sidecar as it lands, so a folder of 350 RAWs holds 700 files and the
/// sidecar is there for keywords later; it carries only a rating the shot
/// already had (the camera's), else none.
public enum Stars {
    /// The stars in a sidecar, or nil when it has none (or doesn't exist).
    public static func read(xmp url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return rating(in: metadata)
    }

    /// A rating set in the camera, read from the photo itself.
    public static func inCamera(_ photo: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, nil) else { return nil }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let stars = rating(in: metadata) {
            return stars
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let iptc = properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        return (iptc?[kCGImagePropertyIPTCStarRating] as? NSNumber).map { clamp($0.intValue) }
    }

    /// Sets the stars in a sidecar, keeping everything else in it, or makes
    /// the sidecar if there isn't one; nil leaves its rating as it is. Written atomically, so a sidecar is
    /// never left half-written. With the RAW it belongs to, it also records
    /// the RAW's embedded-XMP digest, without which Lightroom ignores the
    /// sidecar's stars (see RawXMP).
    /// `extra` adds other fields (the auto-rating marker) and `removing`
    /// takes fields out.
    public static func write(_ stars: Int?, toXMP url: URL, raw: URL? = nil, now: Date = Date(),
                             extra: [String: String] = [:], removing: [String] = []) throws {
        var metadata = CGImageMetadataCreateMutable()
        if let data = try? Data(contentsOf: url) {
            guard let existing = CGImageMetadataCreateFromXMPData(data as CFData),
                  let copy = CGImageMetadataCreateMutableCopy(existing) else {
                throw StarsError.unreadableSidecar(url.lastPathComponent)
            }
            metadata = copy
        }
        if !extra.isEmpty || !removing.isEmpty {
            CGImageMetadataRegisterNamespaceForPrefix(metadata, AutoRating.namespace as CFString, AutoRating.prefix as CFString, nil)
        }
        for path in removing {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
        var values = extra.merging(["xmp:MetadataDate": metadataDate(now)]) { _, date in date }
        if let stars { values["xmp:Rating"] = String(clamp(stars)) }
        if let raw {
            values["photoshop:SidecarForExtension"] = raw.pathExtension
            if let digest = RawXMP.digest(of: raw) { values["photoshop:EmbeddedXMPDigest"] = digest }
        }
        for (path, value) in values.sorted(by: { $0.key < $1.key }) {
            guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString) else {
                throw StarsError.couldNotWrite(url.lastPathComponent)
            }
        }
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) else {
            throw StarsError.couldNotWrite(url.lastPathComponent)
        }
        try (xmp as Data).write(to: url, options: .atomic)
    }

    /// The shot's sidecar in each destination (main, then backup).
    public static func sidecars(of shot: Shot) -> [URL] {
        shot.primary.destinations.map { $0.deletingLastPathComponent().appendingPathComponent(shot.xmpName) }
    }

    /// The RAW copy next to each sidecar, when the shot has one.
    public static func raws(of shot: Shot) -> [URL?] {
        shot.primary.destinations.map { shot.kind == .raw ? $0 : nil }
    }

    /// The form Adobe writes, e.g. 2026-10-22T23:20:29-05:00.
    private static func metadataDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }

    /// The stars a shot already has, without writing anything: its sidecar's
    /// in any destination, else the rating inside the photo (the RAW of a
    /// RAW+JPEG pair). A JPEG or HEIC keeps a 0 as it is, since Lightroom and
    /// Capture One write 0s there; inside a RAW only the camera writes, and its
    /// 0 means "not rated". Nil for videos and unrated photos.
    public static func found(for shot: Shot) -> Int? {
        guard shot.isRatable else { return nil }
        if let stars = sidecars(of: shot).lazy.compactMap({ read(xmp: $0) }).first { return stars }
        let inside = shot.primary.destinations.lazy.compactMap(inCamera).first
        return shot.kind == .raw && inside == 0 ? nil : inside
    }

    /// Gives a RAW shot that just landed its sidecar in each destination that
    /// has none, holding the rating set in the camera if there is one (the
    /// camera's 0 means unrated, so it's left out). A sidecar copied from the
    /// card is kept as it is. JPEG, HEIC and video get nothing.
    public static func giveSidecar(to shot: Shot) throws {
        guard shot.kind == .raw else { return }
        let stars = found(for: shot).flatMap { $0 == 0 ? nil : $0 }
        for (url, raw) in zip(sidecars(of: shot), raws(of: shot))
        where !FileManager.default.fileExists(atPath: url.path) {
            try write(stars, toXMP: url, raw: raw)
        }
    }

    /// Sets the photographer's stars on a shot, in every destination. From
    /// then on the stars are theirs: the stars the checks gave are dropped
    /// from the marker (its reason and score stay, for the record).
    public static func set(_ stars: Int, on shot: Shot) throws {
        guard shot.isRatable else { return }
        for (url, raw) in zip(sidecars(of: shot), raws(of: shot)) {
            try write(stars, toXMP: url, raw: raw, removing: [AutoRating.starsField])
        }
    }

    /// `.xmp` sidecars hold stars, so they change after they're verified and
    /// are matched by name, not by size or checksum, once copied.
    public static func isSidecar(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "xmp"
    }

    /// Lightroom uses -1 for rejected; anything else is 0 to 5.
    static func clamp(_ stars: Int) -> Int { min(5, max(-1, stars)) }

    static func rating(in metadata: CGImageMetadata) -> Int? {
        guard let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?,
              let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return clamp(Int(value.rounded()))
    }
}

public enum StarsError: Error, LocalizedError, Equatable {
    case unreadableSidecar(String)
    case couldNotWrite(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableSidecar(name):
            return "\(name) isn't a sidecar the app can read, so its stars weren't changed."
        case let .couldNotWrite(name):
            return "Couldn't write \(name)."
        }
    }
}

/// A shot whose files are all in, ready for the grid.
public struct LandedShot: Sendable {
    public let shot: Shot
    /// The stars it already had; nil for videos and unrated photos.
    public let stars: Int?
    /// 0 for the first shot of the Copy to land, then 1, 2 ...
    public let position: Int
    /// What the auto-rating checks found, when they've looked at it.
    public let check: AutoCheck?

    public init(shot: Shot, stars: Int?, position: Int, check: AutoCheck? = nil) {
        self.shot = shot
        self.stars = stars
        self.position = position
        self.check = check
    }
}

/// The shots of one Copy as their files land, each handed to the grid as soon
/// as all of its files are in. Safe to call from the copying thread.
public final class LiveShots: @unchecked Sendable {
    private let lock = NSLock()
    private var list: ShotList
    private var expected: [String: Int]
    private var completed = 0
    private var problems: [String] = []

    /// - Parameter planned: everything this Copy will bring in, so a shot is
    ///   shown only once its last file (often the camera's own `.xmp`) is in.
    public init(planned: [PlannedFile], fileTypes: FileTypes) {
        list = ShotList(fileTypes: fileTypes)
        expected = Dictionary(planned.map { (($0.newName as NSString).deletingPathExtension.lowercased(), 1) },
                              uniquingKeysWith: +)
    }

    /// For `CardCopier.copy(fileVerified:)`.
    public func landed(_ file: CopiedFile) {
        _ = complete(file)
    }

    /// Adds a verified copy to its shot. When that was the shot's last file,
    /// gives a RAW its sidecar and returns the shot for the grid with the stars
    /// it came with (its card sidecar's or the camera's), a 0 counting as
    /// unrated since cameras write 0 for that.
    public func complete(_ file: CopiedFile) -> LandedShot? {
        lock.withLock {
            let index = list.add(file)
            let shot = list.shots[index]
            guard shot.files.count == expected[shot.id, default: 1] else { return nil }
            completed += 1
            do {
                try Stars.giveSidecar(to: shot)
            } catch {
                problems.append(error.localizedDescription)
            }
            let stars = Stars.found(for: shot).flatMap { $0 == 0 ? nil : $0 }
            return LandedShot(shot: shot, stars: stars, position: completed - 1)
        }
    }

    public var shots: [Shot] { lock.withLock { list.shots } }

    /// Why sidecars couldn't be written, one line per shot.
    public var sidecarProblems: [String] { lock.withLock { problems } }
}
