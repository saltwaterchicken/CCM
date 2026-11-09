import AppKit
import MediaSherpaCore
import SwiftUI

/// Calibrating in the grid: the card in the grid scored once, every photo
/// shown with the orange chips the limits being tried would give it, and the
/// photographer disagreeing where they're wrong (right-click, or Label in the
/// large view). Disagreements are labels: they move the limits live, the least
/// they need to and never past flagging 1% of the keepers, and build up across
/// cards in Calibration Labels.json. Nothing reaches the settings file until
/// Save to Settings; nothing in the folder is changed.
@MainActor
@Observable
final class CalibrationModel {
    enum Phase: Equatable {
        case scoring(done: Int, total: Int)
        case ready
        case failed(String)
    }

    let folder: URL
    private(set) var phase = Phase.scoring(done: 0, total: 0)
    private(set) var scored: [ScoredShot] = [] {
        didSet {
            burstSharpest = ScoredShot.burstSharpest(scored)
            byID = Dictionary(scored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            report = Calibration.report(scored, limits: limits)
        }
    }
    private(set) var byID: [String: ScoredShot] = [:]
    /// The sharpest frame of each burst, for the green chip.
    private(set) var burstSharpest: Set<String> = []
    /// Photos that couldn't be read or checked.
    private(set) var unreadable: [String] = []
    /// The limits being tried; saved only with Save to Settings.
    var limits: RatingSettings {
        didSet { report = Calibration.report(scored, limits: limits) }
    }
    /// What these limits flag, and why; kept, as every tile asks.
    private(set) var report = Calibration.report([], limits: RatingSettings())
    private var flag: StopFlag?
    /// Every label given so far, from any folder, and the file they're kept
    /// in; nil when it couldn't be read, so it's never written over.
    private(set) var labels = PhotoLabels()
    private(set) var labelsURL: URL?
    private(set) var labelError: String?
    /// The labels the limits couldn't follow, after the last disagreement.
    private(set) var unmet: [UnmetLabel] = []
    /// What the last disagreement or Learn from Labels moved, or that it moved nothing.
    private(set) var learnedNote: String?

    /// Starts scoring `folder` straight away, trying `limits`.
    init(folder: URL, limits: RatingSettings, settingsURL: URL) {
        self.folder = folder
        self.limits = limits
        loadLabels(besideSettings: settingsURL)
        score()
    }

    func problems(_ id: String) -> [QualityProblem] { report.problems[id] ?? [] }

    func loadLabels(besideSettings settingsURL: URL) {
        let url = PhotoLabels.fileURL(besideSettings: settingsURL)
        do {
            labels = try PhotoLabels.load(from: url)
            labelsURL = url
            labelError = nil
        } catch {
            labels = PhotoLabels()
            labelsURL = nil
            labelError = "Couldn't read \(url.path), so disagreeing is off: \(error.localizedDescription)"
        }
    }

    func labels(for id: String) -> [PhotoLabel] {
        labels.labels(folder: folder, name: id)
    }

    /// Gives or takes away a label, saves it, and moves the limits to follow.
    func toggle(_ label: PhotoLabel, on id: String) {
        guard let photo = byID[id], let labelsURL else { return }
        labels.toggle(label, for: photo, folder: folder)
        do {
            try labels.save(to: labelsURL)
            labelError = nil
        } catch {
            labelError = "Couldn't save the labels: \(error.localizedDescription)"
        }
        learn()
    }

    func learn() {
        let result = Calibration.learned(from: labels, folder: folder, scored: scored, limits: limits)
        let moved = Self.moves(from: limits, to: result.limits)
        learnedNote = moved.isEmpty ? "No change: the limits already follow you." : "Moved " + moved.joined(separator: ", ") + "."
        limits = result.limits
        unmet = result.unmet
    }

    /// Rated in the grid while calibrating: keepers and outtakes follow.
    func setStars(_ stars: Int, on ids: [String]) {
        guard !ids.isEmpty else { return }
        let changing = Set(ids)
        scored = scored.map { photo in
            guard changing.contains(photo.id) else { return photo }
            var photo = photo
            photo.stars = stars
            return photo
        }
    }

    /// Each limit that differs, as its slider shows it: "Dark subject off → 31".
    static func moves(from old: RatingSettings, to new: RatingSettings) -> [String] {
        let percent = { (v: Double) in "\(Int((v * 100).rounded()))%" }
        let whole = { (v: Double) in "\(Int(v.rounded()))" }
        let limits: [(String, Double, Double, (Double) -> String)] = [
            ("Soft faces", old.minimumSharpnessFaces, new.minimumSharpnessFaces, whole),
            ("Soft, no face", old.minimumSharpnessNoFaces, new.minimumSharpnessNoFaces, whole),
            ("Too bright", old.maximumBlown, new.maximumBlown, percent),
            ("Too dark", old.maximumCrushed, new.maximumCrushed, percent),
            ("Dark subject", old.minimumBrightness, new.minimumBrightness, { $0 < 1 ? "off" : whole($0) }),
            ("Bright subject", old.maximumBrightness, new.maximumBrightness, { $0 >= 255 ? "off" : whole($0) }),
        ]
        return limits.filter { $0.1 != $0.2 }.map { "\($0.0) \($0.3($0.1)) → \($0.3($0.2))" }
    }

    /// Every photo, the app's own stars included: they stand for "looked at
    /// and left as it is", as on a card culled in the grid.
    private func score() {
        let flag = StopFlag()
        self.flag = flag
        let url = folder
        // Holds the model until scoring ends; Done Calibrating stops it.
        Task.detached(priority: .userInitiated) { [self] in
            let photos: [LandedShot]
            do {
                photos = try Calibration.photos(in: url, fileTypes: FileTypes(), includingAppStars: true)
            } catch {
                await finish(flag, failure: "Couldn't read the folder: \(error.localizedDescription)")
                return
            }
            await progress(flag, done: 0, total: photos.count)
            let total = photos.count
            let result = Calibration.score(photos, progress: { done in
                // A few updates a second is plenty for the bar.
                if done % 10 == 0 || done == total {
                    Task { @MainActor in self.progress(flag, done: done, total: total) }
                }
            }, isCancelled: { flag.isStopped })
            await finish(flag, result: result)
        }
    }

    func stop() {
        flag?.stop()
        flag = nil
    }

    private func progress(_ from: StopFlag, done: Int, total: Int) {
        guard from === flag, case .scoring = phase else { return }
        phase = .scoring(done: done, total: total)
    }

    private func finish(_ from: StopFlag, result: (scored: [ScoredShot], failed: [String])? = nil, failure: String? = nil) {
        guard from === flag else { return }
        flag = nil
        if let failure {
            phase = .failed(failure)
        } else if let result {
            scored = result.scored
            unreadable = result.failed
            phase = .ready
        }
    }
}

/// In place of the cards and the Job panel while calibrating: the limits, how
/// they do against the photographer's stars, and Save.
struct CalibrationPanel: View {
    @Bindable var settings: SettingsModel
    @Bindable var model: CalibrationModel
    var grid: GridModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Calibrating") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.folder.lastPathComponent).font(.headline)
                    Text("Every photo shows the chips these limits would give it. Where they're wrong, right-click the photo "
                         + "(or use Label in the large view) and say so: on a flagged one, Looks Fine; on another, what's wrong "
                         + "with it. The limits move to follow, live. Your stars don't teach it anything.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    switch model.phase {
                    case let .scoring(done, total):
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text(total == 0 ? "Reading the folder…" : "Checking \(done) of \(total) photos…")
                            .foregroundStyle(.secondary).monospacedDigit()
                    case .ready:
                        summary
                    case let .failed(message):
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("Done Calibrating") { grid.stopCalibrating() }
                            .help(changed ? "Leaves the limits you haven't saved behind" : "Back to the cards and the Job panel")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.phase == .ready, !model.scored.isEmpty {
                limitsPanel
                resultsPanel
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let report = model.report
        if model.scored.isEmpty {
            Label("No photos in this folder could be checked.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text("\(model.scored.count) photos: \(report.keepers) keepers (1★ or more), \(report.outtakes) outtakes.")
            if report.keepers == 0 {
                Label("No photo here has a star yet, so the 1% safety limit has nothing to go on. Rate the keepers first, "
                      + "here or in Lightroom (then Metadata › Save Metadata to File).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let first = model.unreadable.first {
            Text("\(model.unreadable.count) couldn't be checked (\(first)\(model.unreadable.count > 1 ? " …" : "")).")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Limits

    private var limitsPanel: some View {
        GroupBox("Limits") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Slide left to flag more photos, right to keep more.")
                    .font(.caption).foregroundStyle(.secondary)
                sharpnessSlider("Soft faces", help: "How soft a face can be before the photo is flagged.",
                                value: $model.limits.minimumSharpnessFaces)
                sharpnessSlider("Soft, no face", help: "How soft the sharpest part can be, for photos with no face.",
                                value: $model.limits.minimumSharpnessNoFaces)
                shareSlider("Too bright", help: "How much of the picture can be pure white.",
                            value: $model.limits.maximumBlown)
                shareSlider("Too dark", help: "How much of the picture can be pure black.",
                            value: $model.limits.maximumCrushed)
                brightnessSlider("Dark subject", help: "How dim the face (or the sharpest part, with no face) can be. A lit face on a black stage passes.",
                                 value: $model.limits.minimumBrightness)
                brightSubjectSlider(value: $model.limits.maximumBrightness)
                HStack {
                    Button("Suggest") { model.limits = Calibration.suggested(model.scored, from: model.limits) }
                        .help("Sets both sharpness limits so about 1 in 100 of this card's keepers would be flagged")
                    Button("Starting Values") {
                        let d = RatingSettings()
                        model.limits.minimumSharpnessFaces = d.minimumSharpnessFaces
                        model.limits.minimumSharpnessNoFaces = d.minimumSharpnessNoFaces
                        model.limits.maximumBlown = d.maximumBlown
                        model.limits.maximumCrushed = d.maximumCrushed
                        model.limits.minimumBrightness = d.minimumBrightness
                        model.limits.maximumBrightness = d.maximumBrightness
                    }
                    .help("The limits set from 34,000 camp photos")
                    Spacer()
                }
                labelsSummary
                HStack {
                    Button("Save to Settings") {
                        let tried = model.limits
                        settings.change {
                            $0.rating.minimumSharpnessFaces = tried.minimumSharpnessFaces
                            $0.rating.minimumSharpnessNoFaces = tried.minimumSharpnessNoFaces
                            $0.rating.maximumBlown = tried.maximumBlown
                            $0.rating.maximumCrushed = tried.maximumCrushed
                            $0.rating.minimumBrightness = tried.minimumBrightness
                            $0.rating.maximumBrightness = tried.maximumBrightness
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed)
                    Button("Undo Changes") { model.limits = settings.settings.rating }
                        .disabled(!changed)
                    Spacer()
                }
                Text(changed ? "Not saved yet." : "Saved in \(settings.fileURL.lastPathComponent).")
                    .foregroundStyle(.secondary)
                if let error = settings.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var changed: Bool {
        let saved = settings.settings.rating, tried = model.limits
        return saved.minimumSharpnessFaces != tried.minimumSharpnessFaces
            || saved.minimumSharpnessNoFaces != tried.minimumSharpnessNoFaces
            || saved.maximumBlown != tried.maximumBlown || saved.maximumCrushed != tried.maximumCrushed
            || saved.minimumBrightness != tried.minimumBrightness || saved.maximumBrightness != tried.maximumBrightness
    }

    /// The lowest score that passes, from about 1 to 1,000 on a log scale (as
    /// fine around 20 as around 500), turned round so that, like the exposure
    /// sliders, right keeps more: a lower limit flags fewer photos.
    private func sharpnessSlider(_ title: String, help: String, value: Binding<Double>) -> some View {
        limitSlider(title, help: help, shown: "limit \(Int(value.wrappedValue.rounded()))") {
            Slider(value: Binding(get: { 1 - log10(max(value.wrappedValue, 1)) / 3 },
                                  set: { value.wrappedValue = pow(10, (1 - $0) * 3).rounded() }),
                   in: 0...1)
        }
    }

    /// The most of the picture allowed, 0 to 100%: right allows more, so keeps more.
    private func shareSlider(_ title: String, help: String, value: Binding<Double>) -> some View {
        limitSlider(title, help: help, shown: "up to \(Int((value.wrappedValue * 100).rounded()))%") {
            Slider(value: value, in: 0...1, step: 0.01)
        }
    }

    /// The dimmest subject that passes, 0 (off) to 128 (mid grey), turned
    /// round like the sharpness sliders so that right keeps more.
    private func brightnessSlider(_ title: String, help: String, value: Binding<Double>) -> some View {
        limitSlider(title, help: help, shown: value.wrappedValue < 1 ? "off" : "below \(Int(value.wrappedValue.rounded()))") {
            Slider(value: Binding(get: { 128 - value.wrappedValue }, set: { value.wrappedValue = 128 - $0 }),
                   in: 0...128, step: 1)
        }
    }

    /// The brightest subject that passes, 128 (mid grey) to 255 (off): right keeps more.
    private func brightSubjectSlider(value: Binding<Double>) -> some View {
        limitSlider("Bright subject", help: "How bright the face (or the sharpest part, with no face) can be.",
                    shown: value.wrappedValue >= 255 ? "off" : "above \(Int(value.wrappedValue.rounded()))") {
            Slider(value: value, in: 128...255, step: 1)
        }
    }

    /// The labels given so far and any the limits couldn't follow.
    private var labelsSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            let count = model.labels.photos.count
            Text(count == 0 ? "No disagreements yet. Right-click a photo to disagree with it; the limits move to follow."
                 : "\(count) disagreement\(count == 1 ? "" : "s"), from \(model.labels.folderCount) card\(model.labels.folderCount == 1 ? "" : "s"). "
                    + "Each moves the limits the least they need to, never past flagging 1 in 100 of your keepers.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = model.learnedNote {
                Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.unmet, id: \.label) { unmet in
                Label(unmetText(unmet), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if count > 0 {
                Button("Learn from Disagreements") { model.learn() }
                    .help("Moves the limits to follow every disagreement so far, from every card. After Starting Values, "
                          + "it's what your disagreements alone say.")
            }
            if let error = model.labelError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unmetText(_ unmet: UnmetLabel) -> String {
        let photos = unmet.stillPassing == 1 ? "1 photo still passes" : "\(unmet.stillPassing) photos still pass"
        var why: [String] = []
        if unmet.keepersInTheWay > 0 {
            why.append("catching \(unmet.stillPassing == 1 ? "it" : "them") would flag \(unmet.keepersInTheWay) of your keepers here")
        }
        if unmet.fineInTheWay { why.append("a photo you said Looks Fine is in the way") }
        return "\(unmet.label.title): \(photos)" + (why.isEmpty ? "." : "; " + why.joined(separator: ", and ") + ".")
    }

    private func limitSlider(_ title: String, help: String, shown: String, slider: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(shown).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            slider()
            HStack {
                Label("Flag more", systemImage: "arrow.left")
                Spacer()
                Label("Keep more", systemImage: "arrow.right").labelStyle(TrailingIcon())
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Results

    private var resultsPanel: some View {
        let report = model.report
        return GroupBox("With These Limits") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your keepers flagged")
                    Spacer()
                    Text("\(report.flaggedKeepers.count) of \(report.keepers) (\(percent(report.keeperShare)))")
                        .monospacedDigit()
                        .foregroundStyle(report.keeperShare > 0.02 ? .orange : .green)
                }
                Text("The mistakes. Aim for about 1 in 100; the ones that are soft but kept for the moment can be rated by hand.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Text("Your outtakes flagged")
                    Spacer()
                    Text("\(report.flaggedOuttakes.count) of \(report.outtakes) (\(percent(report.outtakeShare)))")
                        .monospacedDigit()
                }
                Text("Most outtakes are culled for the moment or a near-duplicate, not focus, so this stays a small share. "
                     + "Check the flagged ones look soft.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !report.rescued.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Flagged photos you starred")
                        Spacer()
                        Text("\(report.rescuedStillFlagged.count) of \(report.rescued.count) still flagged")
                            .monospacedDigit()
                            .foregroundStyle(report.rescuedStillFlagged.isEmpty ? .green : .orange)
                    }
                    Text("The app's mistakes you fixed by rating them. Right-click them and choose Looks Fine to let them through, "
                         + "if that doesn't flag too many of your other keepers.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let counts = Dictionary(grouping: report.problems.values.flatMap { $0 }, by: { $0 }).mapValues(\.count)
                if !counts.isEmpty {
                    Text(QualityProblem.allCases.compactMap { p in counts[p].map { "\(p.label): \($0)" } }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func percent(_ share: Double) -> String {
        share > 0 && share < 0.001 ? "<0.1%" : String(format: "%.1f%%", share * 100)
    }
}

/// The right-click labels for a photo, ticked where given. Only the soft one
/// that fits: a photo with a face is judged on its face.
struct LabelMenuItems: View {
    let photo: ScoredShot
    let labels: [PhotoLabel]
    let toggle: (PhotoLabel) -> Void

    var body: some View {
        ForEach(PhotoLabel.allCases.filter { $0.applies(toFace: photo.score.faceScore != nil) }, id: \.self) { label in
            if label == .fine { Divider() }
            Toggle(label.title, isOn: Binding(get: { labels.contains(label) }, set: { _ in toggle(label) }))
        }
    }
}

/// On the sharpest frame of a burst: green, as it's good news.
struct BurstChip: View {
    var body: some View {
        CalibrationChip(text: "Subject Sharpest", color: .green)
            .help("The sharpest of a burst: three or more frames, each within a second of the one before. "
                  + "Judged on the largest face, or the sharpest area with no face.")
    }
}

struct CalibrationChip: View {
    let text: String
    var color = Color.orange

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}

/// What a photo scored, for the large view while calibrating.
enum ScoreText {
    /// The number its limit is compared with.
    static func scoreText(_ score: QualityScore) -> String {
        if let face = score.faceScore { return "face \(Int(face.rounded()))" }
        return "area \(Int(score.areaSharpness.rounded()))"
    }

    static func details(_ photo: ScoredShot) -> String {
        let s = photo.score
        let faces = s.faces == 0 ? "no face" : s.faces == 1 ? "1 face" : "\(s.faces) faces"
        return "\(scoreText(s)) · \(faces) · \(Int((s.blown * 100).rounded()))% white · \(Int((s.crushed * 100).rounded()))% black · subject \(Int(s.subjectBrightness.rounded()))"
    }
}

/// A label with its icon after the text, for "Keep more →".
struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
