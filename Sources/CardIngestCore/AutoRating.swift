import Foundation
import ImageIO

/// What the auto-rating checks found for one photo, as kept in its sidecar.
public struct AutoCheck: Equatable, Sendable {
    /// The stars the checks gave, while they still stand: nil once the
    /// photographer has rated it, here or in another app.
    public let stars: Int?
    /// Why it was left at 0; empty for a keeper.
    public let problems: [QualityProblem]
    /// The number its sharpness limit was compared with: the face score, or
    /// the sharpest area's when there's no face.
    public let score: Double

    public init(stars: Int?, problems: [QualityProblem], score: Double) {
        self.stars = stars
        self.problems = problems
        self.score = score
    }

    /// Left at 0 by the checks, and not rated since.
    public var isFlagged: Bool { stars == 0 }

    /// The same check once the photographer has rated the photo.
    public var handRated: AutoCheck { AutoCheck(stars: nil, problems: problems, score: score) }
}

/// Gives each photo that lands unrated its first stars from its sharpness and
/// exposure: 1 to keepers, 0 to the rest, with a private marker in the sidecar
/// saying it was checked, why, and what it scored. Lightroom, Bridge and Photo
/// Mechanic ignore the marker. Never touches a photo that already has stars
/// (the photographer's or the camera's), and only reads the copies, never the card.
public enum AutoRating {
    public static let namespace = "http://ns.cardingest.app/autorating/1.0/"
    public static let prefix = "cardingest"
    /// The stars the checks gave. Taken out when the photographer rates the
    /// photo in this app; another app changing the rating shows as a rating
    /// that no longer matches it.
    public static let starsField = "cardingest:Stars"
    static let checkedField = "cardingest:Checked"
    static let problemsField = "cardingest:Problems"
    static let scoreField = "cardingest:Score"
    static let facesField = "cardingest:Faces"
    static let blownField = "cardingest:Blown"
    static let crushedField = "cardingest:Crushed"

    /// The check recorded in a sidecar, or nil when the checks haven't
    /// looked at this photo.
    public static func check(in xmp: URL) -> AutoCheck? {
        guard let data = try? Data(contentsOf: xmp),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        let value = { (path: String) in
            CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
        }
        guard value(checkedField) != nil else { return nil }
        let problems = (value(problemsField) ?? "").split(separator: ",").compactMap { QualityProblem(rawValue: String($0)) }
        let given = value(starsField).flatMap { Int($0) }
        // Stars the checks gave stand only while the rating still says so.
        let stars = given != nil && given == Stars.rating(in: metadata) ? given : nil
        return AutoCheck(stars: stars, problems: problems, score: value(scoreField).flatMap { Double($0) } ?? 0)
    }

    /// The check recorded for a shot, from its sidecar in the destination or backup.
    public static func check(of shot: Shot) -> AutoCheck? {
        guard shot.isRatable else { return nil }
        return Stars.sidecars(of: shot).lazy.compactMap { check(in: $0) }.first
    }

    /// Checks a photo and writes its first stars and the marker into its
    /// sidecars, returning what it found. Nil when it was left alone: a clip,
    /// already checked, or already rated (by hand, in the camera or in an
    /// editor, 0 included) before or while it was being checked. Throws when
    /// it couldn't be read or checked, so it's never taken for a keeper.
    public static func rate(_ shot: Shot, limits: RatingSettings, now: Date = Date()) throws -> AutoCheck? {
        guard shot.isRatable, check(of: shot) == nil, Stars.found(for: shot) == nil,
              let url = shot.primary.destinations.first else { return nil }
        guard let score = try QualityCheck.score(url) else { throw AutoRatingError.unreadable(shot.primary.newName) }
        let problems = limits.problems(score)
        let stars = problems.isEmpty ? 1 : 0
        // To one decimal, as it's kept in the sidecar.
        let measured = ((score.faceScore ?? score.areaSharpness) * 10).rounded() / 10
        // Rated while it was being checked: theirs wins.
        guard Stars.found(for: shot) == nil else { return nil }
        let marker = [
            checkedField: ISO8601DateFormatter().string(from: now),
            starsField: String(stars),
            problemsField: problems.map(\.rawValue).joined(separator: ","),
            scoreField: String(format: "%.1f", measured),
            facesField: String(score.faces),
            blownField: String(format: "%.3f", score.blown),
            crushedField: String(format: "%.3f", score.crushed),
        ]
        for (sidecar, raw) in zip(Stars.sidecars(of: shot), Stars.raws(of: shot)) {
            try Stars.write(stars, toXMP: sidecar, raw: raw, now: now, extra: marker)
        }
        return AutoCheck(stars: stars, problems: problems, score: measured)
    }
}

public enum AutoRatingError: Error, LocalizedError, Equatable {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(name): "\(name) couldn't be read, so it wasn't checked."
        }
    }
}
