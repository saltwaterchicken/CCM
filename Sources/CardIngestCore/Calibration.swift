import Foundation

/// A photo from a folder the photographer has already culled, with its score.
public struct ScoredShot: Sendable, Identifiable {
    public let shot: Shot
    /// Its stars in the folder; unrated counts as 0, and rejected (-1) stays -1.
    public let stars: Int
    public let score: QualityScore

    public var id: String { shot.id }
    /// 1 star or more: what the photographer kept (their call, 2026-10-26).
    public var isKeeper: Bool { stars >= 1 }
}

/// How a set of limits does against the photographer's own cull.
public struct CalibrationReport: Equatable, Sendable {
    public let keepers: Int
    public let outtakes: Int
    /// The keepers the limits would mark 0, the mistakes to keep near none.
    public let flaggedKeepers: [String]
    /// The outtakes they'd mark 0 too. Most outtakes are culled for the
    /// moment, not focus, so this is never expected to be most of them.
    public let flaggedOuttakes: [String]
    /// Why each flagged photo was flagged.
    public let problems: [String: [QualityProblem]]

    public var keeperShare: Double { keepers > 0 ? Double(flaggedKeepers.count) / Double(keepers) : 0 }
    public var outtakeShare: Double { outtakes > 0 ? Double(flaggedOuttakes.count) / Double(outtakes) : 0 }
}

/// The calibration window's arithmetic: score a culled folder once, then see
/// at once how any limits compare with the photographer's own stars.
public enum Calibration {
    /// The photos in a folder, with the stars in their sidecars (or inside a
    /// JPEG with no RAW), else in a Capture One session's settings. Clips are
    /// left out.
    public static func photos(in folder: URL, fileTypes: FileTypes) throws -> [LandedShot] {
        try ImportedFolder.shots(in: folder, backupRoot: nil, fileTypes: fileTypes).filter(\.shot.isRatable).map { landed in
            guard landed.stars == nil, let file = landed.shot.primary.destinations.first,
                  let stars = captureOneStars(for: file) else { return landed }
            return LandedShot(shot: landed.shot, stars: stars, position: landed.position)
        }
    }

    /// The rating Capture One shows for a photo, from its session's
    /// `CaptureOne/Settings*/NAME.cos`. One entry per variant; the last is the
    /// one shown (matched every JPEG exported from a session, 2026-10-26).
    public static func captureOneStars(for photo: URL) -> Int? {
        let sessions = photo.deletingLastPathComponent().appendingPathComponent("CaptureOne", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        for settings in folders.sorted() where settings.hasPrefix("Settings") {
            let cos = sessions.appendingPathComponent(settings).appendingPathComponent(photo.lastPathComponent + ".cos")
            guard let text = try? String(contentsOf: cos, encoding: .utf8),
                  let last = text.matches(of: /K="Basic_Rating" V="(-?\d)"/).last else { continue }
            return Int(last.1)
        }
        return nil
    }

    /// Scores every photo, several at a time. Only reads them. A photo that
    /// can't be read or whose face search fails is listed by name instead.
    public static func score(_ photos: [LandedShot], progress: @Sendable (Int) -> Void = { _ in },
                             isCancelled: @Sendable () -> Bool = { false }) -> (scored: [ScoredShot], failed: [String]) {
        let tally = Tally(count: photos.count)
        DispatchQueue.concurrentPerform(iterations: photos.count) { i in
            guard !isCancelled() else { return }
            let landed = photos[i]
            let score = landed.shot.primary.destinations.first.flatMap { try? QualityCheck.score($0) }
            let done = tally.add(i, score.map { ScoredShot(shot: landed.shot, stars: landed.stars ?? 0, score: $0) },
                                 name: landed.shot.primary.newName)
            progress(done)
        }
        return tally.results
    }

    /// The scores coming in from several threads at once.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var scored: [ScoredShot?]
        private var failed: [String] = []
        private var done = 0

        init(count: Int) { scored = Array(repeating: nil, count: count) }

        /// Records one photo and says how many are done.
        func add(_ index: Int, _ photo: ScoredShot?, name: String) -> Int {
            lock.withLock {
                if let photo { scored[index] = photo } else { failed.append(name) }
                done += 1
                return done
            }
        }

        var results: (scored: [ScoredShot], failed: [String]) {
            lock.withLock { (scored.compactMap { $0 }, failed.sorted()) }
        }
    }

    public static func report(_ scored: [ScoredShot], limits: RatingSettings) -> CalibrationReport {
        var flaggedKeepers: [String] = [], flaggedOuttakes: [String] = []
        var problems: [String: [QualityProblem]] = [:]
        for photo in scored {
            let found = limits.problems(photo.score)
            guard !found.isEmpty else { continue }
            problems[photo.id] = found
            if photo.isKeeper { flaggedKeepers.append(photo.id) } else { flaggedOuttakes.append(photo.id) }
        }
        let keepers = scored.filter(\.isKeeper).count
        return CalibrationReport(keepers: keepers, outtakes: scored.count - keepers, flaggedKeepers: flaggedKeepers,
                                 flaggedOuttakes: flaggedOuttakes, problems: problems)
    }

    /// Sharpness limits that would flag about `keeperShare` of the keepers
    /// (with faces, and without), leaning towards keeping: with few keepers
    /// it flags none. Exposure limits are left as they are.
    public static func suggested(_ scored: [ScoredShot], from limits: RatingSettings,
                                 keeperShare: Double = 0.01) -> RatingSettings {
        var suggested = limits
        let keepers = scored.filter(\.isKeeper)
        if let face = limit(keepers.compactMap(\.score.faceScore), share: keeperShare) {
            suggested.minimumSharpnessFaces = face
        }
        if let area = limit(keepers.filter { $0.score.faceScore == nil }.map(\.score.areaSharpness), share: keeperShare) {
            suggested.minimumSharpnessNoFaces = area
        }
        return suggested
    }

    /// The score that this share of the values falls under, rounded down to
    /// a whole number; nil with nothing to go on.
    private static func limit(_ values: [Double], share: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(share * Double(sorted.count)))].rounded(.down)
    }
}
