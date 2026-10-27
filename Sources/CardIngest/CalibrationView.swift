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
    /// The card just imported and reviewed in the grid, with the app's own
    /// stars counted where the photographer left them.
    private(set) var isThisCard = false
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

    enum Showing: Hashable { case keepers, outtakes, rescued }

    var report: CalibrationReport { Calibration.report(scored, limits: limits) }

    /// The flagged photos the grid shows, softest first.
    var flagged: [ScoredShot] {
        let report = report
        let ids = Set(showing == .keepers ? report.flaggedKeepers : showing == .outtakes ? report.flaggedOuttakes : report.rescued)
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

    func score(_ url: URL, thisCard: Bool = false) {
        flag?.stop()
        let flag = StopFlag()
        self.flag = flag
        folder = url
        isThisCard = thisCard
        scored = []
        unreadable = []
        viewing = nil
        phase = .scoring(done: 0, total: 0)
        // Holds the model until scoring ends; closing the window stops it (see onDisappear).
        Task.detached(priority: .userInitiated) { [self] in
            let photos: [LandedShot]
            do {
                photos = try Calibration.photos(in: url, fileTypes: FileTypes(), includingAppStars: thisCard)
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
            showing = result.scored.contains(where: \.rescued) ? .rescued : .keepers
        }
    }
}

/// Score a folder you've already culled, then move the limits and see at once
/// how many of your keepers they'd flag, and which.
struct CalibrationView: View {
    @Bindable var settings: SettingsModel
    /// The grid, for its card: Calibrate… there asks for it to be scored here.
    var grid: GridModel
    @State private var model = CalibrationModel()

    var body: some View {
        if settings.settings.rating.available {
            calibration
        } else {
            Text("Auto-rating is turned off in the settings file (rating › available).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var calibration: some View {
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
        .onAppear {
            model.limits = settings.settings.rating
            scoreRequestedCard()
        }
        .onChange(of: grid.calibrationRequest) { scoreRequestedCard() }
        .onDisappear { model.stop() }
        .sheet(item: $model.viewing) { photo in
            CalibrationPhotoView(photo: photo, problems: model.report.problems[photo.id] ?? []) { model.viewing = nil }
        }
    }

    private func scoreRequestedCard() {
        guard let card = grid.calibrationRequest else { return }
        grid.calibrationRequest = nil
        model.score(card, thisCard: true)
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
                    if model.isThisCard {
                        Text("The card in the grid. Your stars count as they are, and so do the app's where you left them.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                switch model.phase {
                case .idle:
                    HStack {
                        Button("Choose Folder…") { model.choose() }
                        thisCardButton
                    }
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
                    HStack {
                        Button("Choose Another Folder…") { model.choose() }
                        thisCardButton
                    }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    HStack {
                        Button("Choose Folder…") { model.choose() }
                        thisCardButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The card in the grid, while it's fresh: rescue the flagged keepers
    /// there, then come here to see what limits would have kept them.
    @ViewBuilder
    private var thisCardButton: some View {
        if let card = grid.folder, !(model.isThisCard && model.folder == card) {
            Button("Use \(card.lastPathComponent)") { model.score(card, thisCard: true) }
                .help("The card in the grid. Rate the flagged photos you'd keep first, then check them here.")
        } else if let card = grid.folder, model.phase == .ready {
            Button("Check Again") { model.score(card, thisCard: true) }
                .help("Reads the card's stars again, after rating more photos in the grid")
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

    /// The most of the picture allowed, 50 to 100%: right allows more, so keeps more.
    private func shareSlider(_ title: String, help: String, value: Binding<Double>) -> some View {
        limitSlider(title, help: help, shown: "up to \(Int((value.wrappedValue * 100).rounded()))%") {
            Slider(value: value, in: 0.5...1, step: 0.01)
        }
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
                    Text("The app's mistakes you fixed in the grid. Slide right until the ones you'd keep are no longer flagged, "
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

    // MARK: Flagged photos

    private var flaggedGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase == .ready, !model.scored.isEmpty {
                let report = model.report
                Picker("", selection: $model.showing) {
                    Text("Keepers it would flag (\(report.flaggedKeepers.count))").tag(CalibrationModel.Showing.keepers)
                    Text("Outtakes it would flag (\(report.flaggedOuttakes.count))").tag(CalibrationModel.Showing.outtakes)
                    if !report.rescued.isEmpty {
                        Text("Rescued by you (\(report.rescued.count))").tag(CalibrationModel.Showing.rescued)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 700)
                let photos = model.flagged
                if photos.isEmpty {
                    Text(model.showing == .keepers ? "None of your keepers would be flagged."
                         : model.showing == .outtakes ? "None of your outtakes would be flagged." : "Nothing rescued.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                            ForEach(photos) { photo in
                                CalibrationTile(photo: photo, problems: report.problems[photo.id] ?? [],
                                                showsKept: model.showing == .rescued)
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
    /// In the Rescued list, a passing photo says so instead of showing nothing.
    var showsKept = false
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
                    if showsKept && problems.isEmpty { CalibrationChip(text: "Kept now", color: .green) }
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

/// A label with its icon after the text, for "Keep more →".
struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
