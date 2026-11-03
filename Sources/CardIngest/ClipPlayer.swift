import AVFoundation
import AppKit
import CardIngestCore
import SwiftUI

/// What the large view and its bar ask of a clip, however it's shown.
@MainActor
protocol ClipControls: AnyObject {
    var time: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    /// Said beside the bar, when something about this clip differs.
    var note: String? { get }
    func togglePlay()
    func scrub(to share: Double)
    func step(by frames: Int)
    func endScrub()
    func stop()
}

/// The way to show this clip: only MXF differs.
@MainActor
func makeClipControls(url: URL) -> any ClipControls {
    MXFClip.handles(url) ? MXFPlayback(url: url) : ClipPlayback(url: url)
}

/// Plays one clip in the large view: Space plays and pauses, the bar under it
/// scrubs. Made for each clip shown; `stop()` before dropping it.
@MainActor
@Observable
final class ClipPlayback: ClipControls {
    let note: String? = nil
    let player: AVPlayer
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private var observer: Any?
    private var scrubbing = false
    /// Playing when the scrub began, so it carries on once the bar is let go.
    private var wasPlaying = false

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        Task { [weak self] in
            guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite else { return }
            self?.duration = seconds
        }
    }

    private func tick(_ now: CMTime) {
        isPlaying = player.rate != 0
        if !scrubbing, now.seconds.isFinite { time = now.seconds }
    }

    /// Plays from the start again once it has reached the end.
    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, time >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = !isPlaying
    }

    /// To a share (0 to 1) of the clip, frame-exact, paused while the bar is held.
    func scrub(to share: Double) {
        if !scrubbing {
            scrubbing = true
            wasPlaying = isPlaying
            player.pause()
            isPlaying = false
        }
        seek(to: min(max(share, 0), 1) * duration)
    }

    /// Forward (+) or back (-) by frames, pausing first.
    func step(by frames: Int) {
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        player.currentItem?.step(byCount: frames)
    }

    func endScrub() {
        scrubbing = false
        if wasPlaying { togglePlay() }
    }

    private func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// An MXF clip in the large view, which AVFoundation can't open: frames complete
/// in themselves (see `MXFClip`) are decoded and shown as pictures, with no sound.
/// One at a time, so frames are skipped rather than falling behind, and it keeps
/// the clip's pace when playing on a slower Mac.
@MainActor
@Observable
final class MXFPlayback: ClipControls {
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var picture: CGImage?
    /// This MXF can't be shown (see `MXFError`), though the copy itself is fine.
    private(set) var unavailable = false
    var note: String? {
        guard !unavailable else { return nil }
        guard let clip, !clip.showsEveryFrame else { return "No sound in MXF previews" }
        return "No sound, moves in \(String(format: "%.1f", clip.stepSeconds))-second steps"
    }

    private var clip: MXFClip?
    private var current = 0
    private var wanted: Int?
    private var decoding = false
    private var playTask: Task<Void, Never>?
    private var scrubbing = false
    private var wasPlaying = false
    private var stopped = false
    /// Plenty to check a clip by, and quicker through a 4K one.
    nonisolated private static let maxPixels = 2560

    init(url: URL) {
        Task { [weak self] in
            let opened = await Task.detached(priority: .userInitiated) {
                try? MXFClip(url: url, maxPixels: Self.maxPixels)
            }.value
            guard let self else { return }
            guard let opened else {
                self.unavailable = true
                return
            }
            self.clip = opened
            self.duration = opened.duration
            if self.startWhenOpen { self.togglePlay() } else { self.show(opened.index(at: min(1, opened.duration / 2))) }
        }
    }

    /// Play was pressed before the clip had opened.
    private var startWhenOpen = false

    private func decode(_ clip: MXFClip, _ index: Int) async -> Thumbnail? {
        await Task.detached(priority: .userInitiated) {
            clip.image(frame: index).map { Thumbnail(image: $0) }
        }.value
    }

    /// Shows a frame; moves made while one decodes only keep the latest.
    private func show(_ index: Int) {
        wanted = index
        current = index
        guard !decoding, let clip else { return }
        decoding = true
        Task {
            while let next = wanted, !stopped {
                wanted = nil
                if let made = await decode(clip, next), !stopped, !isPlaying {
                    picture = made.image
                }
            }
            decoding = false
        }
    }

    func togglePlay() {
        guard let clip else {
            startWhenOpen.toggle()
            return
        }
        if isPlaying { return pause() }
        isPlaying = true
        wanted = nil
        let from = current >= clip.frameCount - 1 ? 0 : current
        playTask = Task {
            let began = Date()
            var shown: Int?
            while isPlaying, !Task.isCancelled {
                let due = from + Int(Date().timeIntervalSince(began) * clip.frameRate)
                guard due < clip.frameCount else {
                    time = duration
                    current = clip.frameCount - 1
                    isPlaying = false
                    break
                }
                // Long GOP: the picture only changes on a complete frame.
                let key = clip.keyFrame(atOrBefore: due)
                if key != shown {
                    let made = await decode(clip, key)
                    guard isPlaying, !Task.isCancelled else { break }
                    if let made { picture = made.image }
                    shown = key
                }
                current = due
                time = Double(due) / clip.frameRate
                // Decoding faster than the clip runs: wait for the next frame's turn.
                let next = began.addingTimeInterval(Double(due + 1 - from) / clip.frameRate).timeIntervalSinceNow
                if next > 0 { try? await Task.sleep(for: .seconds(next)) }
            }
        }
    }

    private func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    func scrub(to share: Double) {
        guard let clip else { return }
        if !scrubbing {
            scrubbing = true
            wasPlaying = isPlaying
            pause()
        }
        time = min(max(share, 0), 1) * duration
        show(clip.index(at: time))
    }

    func endScrub() {
        scrubbing = false
        if wasPlaying { togglePlay() }
    }

    func step(by frames: Int) {
        guard let clip else { return }
        pause()
        let next = clip.keyFrame(from: current, by: frames)
        time = Double(next) / clip.frameRate
        show(next)
    }

    func stop() {
        stopped = true
        pause()
    }
}

/// Small frames of one clip, for scrubbing its tile under the pointer, as in
/// Premiere. Close enough rather than frame-exact, so they come quickly.
/// AVAssetImageGenerator takes requests from any thread.
final class ClipFrames: @unchecked Sendable {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    /// MXF, which AVFoundation can't open, comes through `MXFClip` instead.
    private let mxf: Task<MXFClip?, Never>?

    init(url: URL, maxPixels: Int) {
        mxf = MXFClip.handles(url) ? Task.detached { try? MXFClip(url: url, maxPixels: maxPixels) } : nil
        asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let tolerance = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    /// The frame at a share (0 to 1) of the clip.
    func frame(at share: Double) async -> CGImage? {
        if let mxf {
            guard let clip = await mxf.value else { return nil }
            let index = clip.index(at: min(max(share, 0), 1) * clip.duration)
            return await Task.detached { clip.image(frame: index).map { Thumbnail(image: $0) } }.value?.image
        }
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return nil }
        let time = CMTime(seconds: min(max(share, 0), 1) * seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

/// The clip's picture, fitted. A plain layer, so it never takes the keyboard
/// from the large view.
struct ClipLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let layer = view.layer as? AVPlayerLayer, layer.player !== player { layer.player = player }
    }
}

/// Play/pause, the time so far, a bar to drag through the clip, and its length.
struct ScrubBar: View {
    var clip: any ClipControls

    private var share: Double { clip.duration > 0 ? min(clip.time / clip.duration, 1) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button { clip.togglePlay() } label: {
                Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.plain)
            .focusable(false)
            Text(TileView.length(clip.time)).monospacedDigit()
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Color.accentColor).frame(width: width * share, height: 4)
                    Circle().fill(.white).frame(width: 12, height: 12).offset(x: width * share - 6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in clip.scrub(to: drag.location.x / max(width, 1)) }
                    .onEnded { _ in clip.endScrub() })
            }
            .frame(height: 20)
            Text(TileView.length(clip.duration)).monospacedDigit().foregroundStyle(.secondary)
            if let note = clip.note {
                Text(note).foregroundStyle(.secondary).fixedSize()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.7))
    }
}
