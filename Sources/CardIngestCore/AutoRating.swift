import Foundation
import ImageIO

/// What the auto-rating checks found for one photo, as kept in its sidecar.
public struct AutoCheck: Equatable, Sendable {
    /// The stars the checks gave, while they still stand: nil once the
    /// photographer has rated it, here or in another app.
    public private(set) var stars: Int?
    /// Why it was left at 0; empty for a keeper.
    public let problems: [QualityProblem]
    /// The number its sharpness limit was compared with: the face score, or
    /// the sharpest area's when there's no face.
    public let score: Double
    /// How sharp the subject is, to find the sharpest frame of a burst: the
    /// largest face (`subjectIsFace`), else the sharpest area.
    public var subject: Double?
    public var subjectIsFace = false
    /// When it was taken, to the hundredth of a second where the camera says,
    /// and which camera: what tells the frames of a burst.
    public var taken: Date?
    public var camera: String?

    public init(stars: Int?, problems: [QualityProblem], score: Double, subject: Double? = nil,
                subjectIsFace: Bool = false, taken: Date? = nil, camera: String? = nil) {
        self.stars = stars
        self.problems = problems
        self.score = score
        self.subject = subject
        self.subjectIsFace = subjectIsFace
        self.taken = taken
        self.camera = camera
    }

    /// Left at 0 by the checks, and not rated since.
    public var isFlagged: Bool { stars == 0 }

    /// The same check once the photographer has rated the photo.
    public var handRated: AutoCheck {
        var check = self
        check.stars = nil
        return check
    }
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
    static let brightnessField = "cardingest:Brightness"
    static let subjectField = "cardingest:Subject"
    static let takenField = "cardingest:Taken"
    static let cameraField = "cardingest:Camera"
    /// The capture time as kept in the marker, to the hundredth of a second.
    static func takenFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

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
        let score = value(scoreField).flatMap { Double($0) } ?? 0
        let faces = value(facesField).flatMap { Int($0) } ?? 0
        // Checked before bursts were looked at: the score stands in for the subject.
        return AutoCheck(stars: stars, problems: problems, score: score,
                         subject: value(subjectField).flatMap { Double($0) } ?? score, subjectIsFace: faces > 0,
                         taken: value(takenField).flatMap { takenFormatter().date(from: $0) }, camera: value(cameraField))
    }

    /// The check recorded for a shot, from its sidecar in the destination or backup.
    public static func check(of shot: Shot) -> AutoCheck? {
        guard shot.isRatable, var found = Stars.sidecars(of: shot).lazy.compactMap({ check(in: $0) }).first else { return nil }
        // Checked before the capture time was kept: read from the photo itself.
        if found.taken == nil, let url = shot.primary.destinations.first, let moment = CaptureDate.moment(url) {
            found.taken = moment.taken
            found.camera = moment.camera
        }
        return found
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
        let subject = (score.subjectSharpness * 10).rounded() / 10
        let moment = CaptureDate.moment(url)
        // Rated while it was being checked: theirs wins.
        guard Stars.found(for: shot) == nil else { return nil }
        var marker = [
            checkedField: ISO8601DateFormatter().string(from: now),
            starsField: String(stars),
            problemsField: problems.map(\.rawValue).joined(separator: ","),
            scoreField: String(format: "%.1f", measured),
            facesField: String(score.faces),
            blownField: String(format: "%.3f", score.blown),
            crushedField: String(format: "%.3f", score.crushed),
            brightnessField: String(format: "%.0f", score.subjectBrightness),
            subjectField: String(format: "%.1f", subject),
        ]
        if let moment {
            marker[takenField] = takenFormatter().string(from: moment.taken)
            if let camera = moment.camera { marker[cameraField] = camera }
        }
        for (sidecar, raw) in zip(Stars.sidecars(of: shot), Stars.raws(of: shot)) {
            try Stars.write(stars, toXMP: sidecar, raw: raw, now: now, extra: marker)
        }
        return AutoCheck(stars: stars, problems: problems, score: measured, subject: subject,
                         subjectIsFace: score.largestFaceScore != nil, taken: moment?.taken, camera: moment?.camera)
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
