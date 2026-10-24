import AVFoundation
import AppKit
import SwiftUI

/// Plays one clip in the large view: Space plays and pauses, the bar under it
/// scrubs. Made for each clip shown; `stop()` before dropping it.
@MainActor
@Observable
final class ClipPlayback {
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

/// Small frames of one clip, for scrubbing its tile under the pointer, as in
/// Premiere. Close enough rather than frame-exact, so they come quickly.
/// AVAssetImageGenerator takes requests from any thread.
final class ClipFrames: @unchecked Sendable {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator

    init(url: URL, maxPixels: Int) {
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
    var clip: ClipPlayback

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
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.7))
    }
}
