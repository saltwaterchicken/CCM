import Foundation

/// What the photographer says about a photo in the calibration window, by
/// right-clicking it. Each one but "fine" asks for photos like it to be
/// flagged; "fine" asks for it never to be.
public enum PhotoLabel: String, Codable, Sendable, CaseIterable, Comparable {
    case imageTooDark, subjectTooDark, imageTooLight, subjectTooLight, imageTooSoft, faceTooSoft, fine

    public var title: String {
        switch self {
        case .imageTooDark: "Image Too Dark"
        case .subjectTooDark: "Subject Too Dark"
        case .imageTooLight: "Image Too Light"
        case .subjectTooLight: "Subject Too Light"
        case .imageTooSoft: "Image Too Soft"
        case .faceTooSoft: "Face Too Soft"
        case .fine: "Looks Fine"
        }
    }

    /// A photo with a face is judged on its face, one without on its sharpest area.
    public func applies(toFace hasFace: Bool) -> Bool {
        switch self {
        case .imageTooSoft: !hasFace
        case .faceTooSoft: hasFace
        default: true
        }
    }

    public static func < (a: PhotoLabel, b: PhotoLabel) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A labelled photo with the scores it had, so labels from past cards keep
/// counting once their folders are gone.
public struct LabelledPhoto: Codable, Equatable, Sendable {
    public let folder: String
    public let name: String
    public var labels: [PhotoLabel]
    public let faceScore: Double?
    public let areaSharpness: Double
    public let blown: Double
    public let crushed: Double
    public let subjectBrightness: Double
    public var date: Date

    public init(folder: String, name: String, labels: [PhotoLabel], score: QualityScore, date: Date) {
        self.folder = folder
        self.name = name
        self.labels = labels
        faceScore = score.faceScore
        areaSharpness = score.areaSharpness
        blown = score.blown
        crushed = score.crushed
        subjectBrightness = score.subjectBrightness
        self.date = date
    }

    var key: String { folder + "/" + name }
}

/// Every label a photographer has given, over the summer. Kept in
/// "Calibration Labels.json" beside the settings file, so each photographer's
/// settings file has its own.
public struct PhotoLabels: Codable, Equatable, Sendable {
    public var photos: [LabelledPhoto] = []

    public init(photos: [LabelledPhoto] = []) { self.photos = photos }

    public static func fileURL(besideSettings settings: URL) -> URL {
        settings.deletingLastPathComponent().appendingPathComponent("Calibration Labels.json")
    }

    /// No file yet means no labels.
    public static func load(from url: URL) throws -> PhotoLabels {
        guard FileManager.default.fileExists(atPath: url.path) else { return PhotoLabels() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PhotoLabels.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func labels(folder: URL, name: String) -> [PhotoLabel] {
        photos.first { $0.folder == folder.path && $0.name == name }?.labels ?? []
    }

    /// Gives or takes away a label. "Looks fine" and the others rule each
    /// other out; a photo left with none is forgotten.
    public mutating func toggle(_ label: PhotoLabel, for photo: ScoredShot, folder: URL, now: Date = Date()) {
        let index = photos.firstIndex { $0.folder == folder.path && $0.name == photo.id }
        var labels = index.map { photos[$0].labels } ?? []
        if labels.contains(label) {
            labels.removeAll { $0 == label }
        } else {
            labels.removeAll { label == .fine || $0 == .fine }
            labels.append(label)
            labels.sort()
        }
        if let index { photos.remove(at: index) }
        if !labels.isEmpty {
            photos.append(LabelledPhoto(folder: folder.path, name: photo.id, labels: labels, score: photo.score, date: now))
        }
    }

    public var folderCount: Int { Set(photos.map(\.folder)).count }
}

/// A label the limits couldn't follow: how many photos with it are still
/// passing, and why.
public struct UnmetLabel: Equatable, Sendable {
    public let label: PhotoLabel
    public let stillPassing: Int
    /// The keepers in this folder that would also be flagged to catch them all.
    public let keepersInTheWay: Int
    /// A photo marked "Looks fine" is in the way.
    public let fineInTheWay: Bool
}

extension Calibration {
    /// Moves each limit the least it takes to flag the photos labelled for it,
    /// without flagging more than `keeperShare` of this folder's keepers, and
    /// loosens it if it would flag a photo marked "Looks fine". Limits with no
    /// labels stay where they are. The same labels from the same limits always
    /// give the same result; from Starting Values, it's what the labels alone say.
    public static func learned(from labels: PhotoLabels, folder: URL?, scored: [ScoredShot], limits: RatingSettings,
                               keeperShare: Double = 0.01) -> (limits: RatingSettings, unmet: [UnmetLabel]) {
        var learned = limits
        var unmet: [UnmetLabel] = []
        let byKey = Dictionary(labels.photos.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let keepers = scored.filter(\.isKeeper).map { photo in
            (labels: folder.flatMap { byKey[$0.path + "/" + photo.id] }?.labels ?? [], photo: LabelledPhoto(
                folder: folder?.path ?? "", name: photo.id, labels: [], score: photo.score, date: .distantPast))
        }

        /// One limit, in whole steps of its slider. A photo is flagged when its
        /// value is under the limit, so "too much" measures go in negated.
        func learn(_ label: PhotoLabel, current: Double, inScope: (LabelledPhoto) -> Bool,
                   value measured: (LabelledPhoto) -> Double) -> Double {
            // Without the rounding error of a share times 100, so 0.6 is 60, not 60.000000000000007.
            let value = { (($0 * 1e6).rounded() / 1e6) }
            let targets = labels.photos.filter { $0.labels.contains(label) && inScope($0) }.map { value(measured($0)) }
            let fine = labels.photos.filter { $0.labels.contains(.fine) && inScope($0) }.map { value(measured($0)) }
            guard !targets.isEmpty || !fine.isEmpty else { return current }
            // Keepers labelled for this, or "Looks fine" (counted above), aren't in the way.
            let protected = keepers.filter { !$0.labels.contains(label) && !$0.labels.contains(.fine) && inScope($0.photo) }
                .map { value(measured($0.photo)) }.sorted()
            let allowed = Int(keeperShare * Double(protected.count))
            let keeperCeiling = allowed < protected.count ? protected[allowed].rounded(.down) : .infinity
            let fineCeiling = fine.map { $0.rounded(.down) }.min() ?? .infinity
            var limit = current
            if let highest = targets.max() {
                limit = max(limit, min(highest.rounded(.down) + 1, keeperCeiling))
            }
            limit = min(limit, fineCeiling)
            let passing = targets.filter { $0 >= limit }.count
            if passing > 0, let highest = targets.max() {
                let needed = highest.rounded(.down) + 1
                unmet.append(UnmetLabel(label: label, stillPassing: passing,
                                        keepersInTheWay: protected.filter { $0 < needed }.count,
                                        fineInTheWay: fineCeiling < needed))
            }
            return limit
        }

        let hasFace = { (p: LabelledPhoto) in p.faceScore != nil }
        learned.minimumSharpnessFaces = learn(.faceTooSoft, current: limits.minimumSharpnessFaces.rounded(),
                                              inScope: hasFace, value: { $0.faceScore ?? 0 })
        learned.minimumSharpnessNoFaces = learn(.imageTooSoft, current: limits.minimumSharpnessNoFaces.rounded(),
                                                inScope: { !hasFace($0) }, value: \.areaSharpness)
        learned.minimumBrightness = min(128, max(0, learn(.subjectTooDark, current: limits.minimumBrightness.rounded(),
                                                          inScope: { _ in true }, value: \.subjectBrightness)))
        learned.maximumBrightness = min(255, max(128, -learn(.subjectTooLight, current: -limits.maximumBrightness.rounded(),
                                                             inScope: { _ in true }, value: { -$0.subjectBrightness })))
        learned.maximumCrushed = min(100, max(0, -learn(.imageTooDark, current: -(limits.maximumCrushed * 100).rounded(),
                                                        inScope: { _ in true }, value: { -$0.crushed * 100 }))) / 100
        learned.maximumBlown = min(100, max(0, -learn(.imageTooLight, current: -(limits.maximumBlown * 100).rounded(),
                                                      inScope: { _ in true }, value: { -$0.blown * 100 }))) / 100
        return (learned, unmet)
    }
}
