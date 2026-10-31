import Foundation

/// Bursts: frames from one camera taken in quick succession, each within a
/// second of the one before, three or more in a row. The sharpest of each gets
/// a green "Subject Sharpest" chip in the grid. Only points it out: no stars
/// are given or taken.
public enum Bursts {
    /// The most time between two frames of a burst.
    public static let gap: TimeInterval = 1
    /// Fewer frames than this in a row aren't a burst.
    public static let minimumFrames = 3

    public struct Frame: Equatable, Sendable {
        public let id: String
        public let taken: Date
        public let camera: String?
        /// How sharp the subject is: nil when it hasn't been checked.
        public let subject: Double?
        public let subjectIsFace: Bool

        public init(id: String, taken: Date, camera: String?, subject: Double?, subjectIsFace: Bool) {
            self.id = id
            self.taken = taken
            self.camera = camera
            self.subject = subject
            self.subjectIsFace = subjectIsFace
        }
    }

    /// The frames that make up each burst, in the order they were taken. Each
    /// camera's frames are taken on their own, so a second camera firing at
    /// the same moment doesn't break a burst up.
    public static func groups(_ frames: [Frame]) -> [[Frame]] {
        var groups: [[Frame]] = []
        for cameraFrames in Dictionary(grouping: frames, by: \.camera).values {
            var run: [Frame] = []
            for frame in cameraFrames.sorted(by: { ($0.taken, $0.id) < ($1.taken, $1.id) }) {
                if let last = run.last, frame.taken.timeIntervalSince(last.taken) <= gap {
                    run.append(frame)
                } else {
                    if run.count >= minimumFrames { groups.append(run) }
                    run = [frame]
                }
            }
            if run.count >= minimumFrames { groups.append(run) }
        }
        return groups.sorted { ($0[0].taken, $0[0].id) < ($1[0].taken, $1[0].id) }
    }

    /// The sharpest frame of each burst. With a face in any of its frames, the
    /// burst is judged on the largest face, among the frames that have one; with
    /// none, on the sharpest area. Needs two checked frames to compare.
    public static func sharpest(_ frames: [Frame]) -> Set<String> {
        var winners: Set<String> = []
        for burst in groups(frames) {
            let checked = burst.filter { $0.subject != nil }
            let faces = checked.filter(\.subjectIsFace)
            let candidates = faces.isEmpty ? checked : faces
            guard candidates.count >= 2, let best = candidates.max(by: { $0.subject! < $1.subject! }) else { continue }
            winners.insert(best.id)
        }
        return winners
    }
}
