import Foundation
import ImageIO

/// Star ratings, kept as the standard `xmp:Rating` in each shot's `.xmp`
/// sidecar next to its copies, so Lightroom, Bridge and Photo Mechanic all see
/// them. RAW files are never rewritten. Only the sidecars in the destination
/// and backup are written, never anything on the card.
public enum Stars {
    /// What every photo gets when it lands. 0 is kept for the automatic checks.
    public static let landing = 1

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
    /// the sidecar if there isn't one. Written atomically, so a sidecar is
    /// never left half-written. With the RAW it belongs to, it also records
    /// the RAW's embedded-XMP digest, without which Lightroom ignores the
    /// sidecar's stars (see RawXMP).
    public static func write(_ stars: Int, toXMP url: URL, raw: URL? = nil, now: Date = Date()) throws {
        var metadata = CGImageMetadataCreateMutable()
        if let data = try? Data(contentsOf: url) {
            guard let existing = CGImageMetadataCreateFromXMPData(data as CFData),
                  let copy = CGImageMetadataCreateMutableCopy(existing) else {
                throw StarsError.unreadableSidecar(url.lastPathComponent)
            }
            metadata = copy
        }
        var values = ["xmp:Rating": String(clamp(stars)), "xmp:MetadataDate": metadataDate(now)]
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
    static func raws(of shot: Shot) -> [URL?] {
        shot.primary.destinations.map { shot.kind == .raw ? $0 : nil }
    }

    /// The form Adobe writes, e.g. 2026-10-22T23:20:29-05:00.
    private static func metadataDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Gives a shot that just landed its first stars, in every destination,
    /// and says what they are; nil for videos. Stars already in its sidecar
    /// (from the card, or an earlier interrupted copy) are kept, then a rating
    /// set in the camera, then 1 star. Cameras write 0 for "not rated", so a
    /// 0 found here counts as no rating (0 is kept for the automatic checks).
    @discardableResult
    public static func rateOnLanding(_ shot: Shot) throws -> Int? {
        guard shot.isRatable else { return nil }
        let urls = sidecars(of: shot)
        let rated = { (stars: Int?) in stars == 0 ? nil : stars }
        let stars = urls.lazy.compactMap { rated(read(xmp: $0)) }.first
            ?? rated(shot.primary.destinations.first.flatMap(inCamera))
            ?? landing
        for (url, raw) in zip(urls, raws(of: shot)) {
            try write(stars, toXMP: url, raw: raw)
        }
        return stars
    }

    /// Sets the photographer's stars on a shot, in every destination.
    public static func set(_ stars: Int, on shot: Shot) throws {
        guard shot.isRatable else { return }
        for (url, raw) in zip(sidecars(of: shot), raws(of: shot)) { try write(stars, toXMP: url, raw: raw) }
    }

    /// `.xmp` sidecars hold stars, so they change after they're verified and
    /// are matched by name, not by size or checksum, once copied.
    public static func isSidecar(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "xmp"
    }

    /// Lightroom uses -1 for rejected; anything else is 0 to 5.
    static func clamp(_ stars: Int) -> Int { min(5, max(-1, stars)) }

    private static func rating(in metadata: CGImageMetadata) -> Int? {
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
            return "Couldn't write the stars into \(name)."
        }
    }
}

/// A shot whose files are all in, ready for the grid.
public struct LandedShot: Sendable {
    public let shot: Shot
    /// Its first stars; nil for videos, or if its sidecar couldn't be written.
    public let stars: Int?
    /// 0 for the first shot of the Copy to land, then 1, 2 ...
    public let position: Int
}

/// The shots of one Copy as their files land, rating each one as soon as all
/// of its files are in. Safe to call from the copying thread.
public final class LiveShots: @unchecked Sendable {
    private let lock = NSLock()
    private var list: ShotList
    private var expected: [String: Int]
    private var stars: [String: Int] = [:]
    private var problems: [String] = []
    private var completed = 0

    /// - Parameter planned: everything this Copy will bring in, so a shot is
    ///   rated only once its last file (often the camera's own `.xmp`) is in.
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
    /// gives it its first stars and returns it for the grid.
    public func complete(_ file: CopiedFile) -> LandedShot? {
        lock.withLock {
            let index = list.add(file)
            let shot = list.shots[index]
            guard shot.files.count == expected[shot.id, default: 1] else { return nil }
            do {
                if let given = try Stars.rateOnLanding(shot) { stars[shot.id] = given }
            } catch {
                problems.append(error.localizedDescription)
            }
            completed += 1
            return LandedShot(shot: shot, stars: stars[shot.id], position: completed - 1)
        }
    }

    public var shots: [Shot] { lock.withLock { list.shots } }
    /// Stars by shot id, for shots that have them so far.
    public var ratings: [String: Int] { lock.withLock { stars } }
    /// Sidecars that couldn't be written. The copies themselves are fine.
    public var starProblems: [String] { lock.withLock { problems } }
}
