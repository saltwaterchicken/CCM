import AppKit
import CardIngestCore
import SwiftUI

/// The calibration window's state: one culled folder scored once, and the
/// limits being tried against it. Nothing in the folder is changed.
@MainActor
@Observable
final class CalibrationModel {
    enum Phase: Equatable {
        case idle
        case scoring(done: Int, total: Int)
        case ready
        case failed(String)
    }

    private(set) var folder: URL?
    private(set) var phase = Phase.idle
    private(set) var scored: [ScoredShot] = []
    /// Photos that couldn't be read or checked.
    private(set) var unreadable: [String] = []
    /// The limits being tried; saved only with Save.
    var limits = RatingSettings()
    /// Which flagged photos the grid shows.
    var showing = Showing.keepers
    /// The photo open in the large view.
    var viewing: ScoredShot?
    private var flag: StopFlag?

    enum Showing: Hashable { case keepers, outtakes }

    var report: CalibrationReport { Calibration.report(scored, limits: limits) }

    /// The flagged photos the grid shows, softest first.
    var flagged: [ScoredShot] {
        let report = report
        let ids = Set(showing == .keepers ? report.flaggedKeepers : report.flaggedOuttakes)
        return scored.filter { ids.contains($0.id) }
            .sorted { ($0.score.faceScore ?? $0.score.areaSharpness) < ($1.score.faceScore ?? $1.score.areaSharpness) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Score"
        panel.message = "Choose a folder you've already culled, with its stars saved to the files"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { score(url) }
    }

    func score(_ url: URL) {
        flag?.stop()
        let flag = StopFlag()
        self.flag = flag
        folder = url
        scored = []
        unreadable = []
        viewing = nil
        phase = .scoring(done: 0, total: 0)
        // Holds the model until scoring ends; closing the window stops it (see onDisappear).
        Task.detached(priority: .userInitiated) { [self] in
            let photos: [LandedShot]
            do {
                photos = try Calibration.photos(in: url, fileTypes: FileTypes())
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
        phase = scored.isEmpty ? .idle : .ready
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
            showing = .keepers
        }
    }
}

/// Score a folder you've already culled, then move the limits and see at once
/// how many of your keepers they'd flag, and which.
struct CalibrationView: View {
    @Bindable var settings: SettingsModel
    @State private var model = CalibrationModel()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderPanel
                    if model.phase == .ready, !model.scored.isEmpty {
                        limitsPanel
                        resultsPanel
                    }
                }
            }
            .frame(width: 380)
            flaggedGrid
        }
        .padding(16)
        .onAppear { model.limits = settings.settings.rating }
        .onDisappear { model.stop() }
        .sheet(item: $model.viewing) { photo in
            CalibrationPhotoView(photo: photo, problems: model.report.problems[photo.id] ?? []) { model.viewing = nil }
        }
    }

    // MARK: Folder

    private var folderPanel: some View {
        GroupBox("Culled Folder") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a job you've already culled. Its stars need to be in the files: in Lightroom, "
                     + "select all and choose Metadata › Save Metadata to File. 1 star or more counts as a keeper.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let folder = model.folder {
                    Text(folder.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                switch model.phase {
                case .idle:
                    Button("Choose Folder…") { model.choose() }
                case let .scoring(done, total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    HStack {
                        Text(total == 0 ? "Reading the folder…" : "Checking \(done) of \(total) photos…")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Stop") { model.stop() }
                    }
                case .ready:
                    summary
                    Button("Choose Another Folder…") { model.choose() }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Choose Folder…") { model.choose() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Label("No photo here has a star, so there's nothing to compare with. Save the stars to the files and choose it again.",
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
                sharpnessSlider("Faces", help: "Faces scoring under this are flagged as soft.",
                                value: $model.limits.minimumSharpnessFaces)
                sharpnessSlider("No face", help: "Photos with no face are judged on their sharpest area.",
                                value: $model.limits.minimumSharpnessNoFaces)
                shareSlider("Blown to white", help: "Flagged when more of the picture than this is pure white.",
                            value: $model.limits.maximumBlown)
                shareSlider("Black", help: "Flagged when more of the picture than this is pure black.",
                            value: $model.limits.maximumCrushed)
                HStack {
                    Button("Suggest") { model.limits = Calibration.suggested(model.scored, from: model.limits) }
                        .help("Sets both sharpness limits so about 1 in 100 of this folder's keepers would be flagged")
                    Button("Starting Values") {
                        let d = RatingSettings()
                        model.limits.minimumSharpnessFaces = d.minimumSharpnessFaces
                        model.limits.minimumSharpnessNoFaces = d.minimumSharpnessNoFaces
                        model.limits.maximumBlown = d.maximumBlown
                        model.limits.maximumCrushed = d.maximumCrushed
                    }
                    .help("The limits set from 34,000 camp photos")
                    Spacer()
                }
                HStack {
                    Button("Save to Settings") {
                        let tried = model.limits
                        settings.change {
                            $0.rating.minimumSharpnessFaces = tried.minimumSharpnessFaces
                            $0.rating.minimumSharpnessNoFaces = tried.minimumSharpnessNoFaces
                            $0.rating.maximumBlown = tried.maximumBlown
                            $0.rating.maximumCrushed = tried.maximumCrushed
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
    }

    /// Sharpness scores run from about 1 to 1,000, so the slider moves along
    /// a log scale: as fine around 20 as around 500.
    private func sharpnessSlider(_ title: String, help: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(Int(value.wrappedValue.rounded()))).monospacedDigit()
            }
            Slider(value: Binding(get: { log10(max(value.wrappedValue, 1)) / 3 },
                                  set: { value.wrappedValue = pow(10, $0 * 3).rounded() }),
                   in: 0...1)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func shareSlider(_ title: String, help: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit()
            }
            Slider(value: value, in: 0.5...1, step: 0.01)
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

    // MARK: Flagged photos

    private var flaggedGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase == .ready, !model.scored.isEmpty {
                let report = model.report
                Picker("", selection: $model.showing) {
                    Text("Keepers it would flag (\(report.flaggedKeepers.count))").tag(CalibrationModel.Showing.keepers)
                    Text("Outtakes it would flag (\(report.flaggedOuttakes.count))").tag(CalibrationModel.Showing.outtakes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                let photos = model.flagged
                if photos.isEmpty {
                    Text(model.showing == .keepers ? "None of your keepers would be flagged." : "None of your outtakes would be flagged.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                            ForEach(photos) { photo in
                                CalibrationTile(photo: photo, problems: report.problems[photo.id] ?? [])
                                    .onTapGesture { model.viewing = photo }
                            }
                        }
                    }
                }
            } else {
                Text("Flagged photos show here once a folder is checked.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One flagged photo: its picture, stars, why it was flagged and its score.
struct CalibrationTile: View {
    let photo: ScoredShot
    let problems: [QualityProblem]
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 120)
            .clipped()
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    ForEach(problems, id: \.self) { CalibrationChip(text: $0.label) }
                }
                .padding(4)
            }
            Text(photo.shot.baseName).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            HStack {
                Text(photo.stars > 0 ? String(repeating: "★", count: photo.stars) : photo.stars < 0 ? "Rejected" : "0★")
                    .font(.caption).foregroundStyle(photo.stars > 0 ? .yellow : .secondary)
                Spacer()
                Text(CalibrationPhotoView.scoreText(photo.score)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.panelEdge, lineWidth: 1))
        .contentShape(Rectangle())
        .help("Click to see it larger")
        // Made only while the tile is on screen.
        .task(id: photo.id) {
            guard let url = photo.shot.primary.destinations.first else { return }
            let made = await Task.detached(priority: .utility) { ThumbnailMaker.photo(url, maxPixels: 340) }.value
            if !Task.isCancelled { image = made }
        }
    }
}

struct CalibrationChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}

/// A flagged photo large enough to judge its focus, with its scores.
struct CalibrationPhotoView: View {
    let photo: ScoredShot
    let problems: [QualityProblem]
    let close: () -> Void
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            HStack(spacing: 8) {
                ForEach(problems, id: \.self) { CalibrationChip(text: $0.label) }
                Text(photo.shot.baseName)
                Text(Self.details(photo)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Show in Finder") {
                    if let url = photo.shot.primary.destinations.first { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .background(Theme.window)
        .task {
            guard let url = photo.shot.primary.destinations.first else { return }
            image = await Task.detached(priority: .userInitiated) { ThumbnailMaker.photo(url, maxPixels: 2400) }.value
        }
    }

    /// The number its limit is compared with.
    static func scoreText(_ score: QualityScore) -> String {
        if let face = score.faceScore { return "face \(Int(face.rounded()))" }
        return "area \(Int(score.areaSharpness.rounded()))"
    }

    static func details(_ photo: ScoredShot) -> String {
        let s = photo.score
        let faces = s.faces == 0 ? "no face" : s.faces == 1 ? "1 face" : "\(s.faces) faces"
        return "\(scoreText(s)) · \(faces) · \(Int((s.blown * 100).rounded()))% white · \(Int((s.crushed * 100).rounded()))% black"
    }
}
