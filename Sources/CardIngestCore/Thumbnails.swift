import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// A tile's picture, and a clip's length for its label.
public struct Thumbnail: @unchecked Sendable {
    // CGImage never changes once made, so it's safe to share between threads.
    public let image: CGImage
    /// Seconds, for videos; nil for photos.
    public let duration: Double?

    public init(image: CGImage, duration: Double? = nil) {
        self.image = image
        self.duration = duration
    }
}

/// Makes thumbnails from the verified copies in the destination, never from
/// the card. All Apple frameworks: ImageIO for photos and RAWs, AVFoundation
/// for clips.
public enum ThumbnailMaker {
    /// A photo or RAW, its longest side at most `maxPixels`, turned the right
    /// way up. RAWs use the preview the camera built into them (10 to 60 ms,
    /// measured on Sony, Nikon, Canon and Fuji files) instead of decoding the
    /// RAW (100 to 500 ms). A JPEG's built-in thumbnail is only 160 pixels,
    /// so anything smaller than asked for is drawn again from the full image.
    /// `goodEnough` lowers that bar: 0.45 takes a built-in preview a bit under
    /// half the size asked for (Sony's 1,616 pixels for a 3,456-pixel screen).
    public static func photo(_ url: URL, maxPixels: Int, goodEnough: Double = 1) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let base: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        let builtIn = CGImageSourceCreateThumbnailAtIndex(
            source, 0, base.merging([kCGImageSourceCreateThumbnailFromImageIfAbsent: true]) { a, _ in a } as CFDictionary)
        if let builtIn, Double(max(builtIn.width, builtIn.height)) >= goodEnough * Double(min(maxPixels, fullSize(source))) {
            return builtIn
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, base.merging([kCGImageSourceCreateThumbnailFromImageAlways: true]) { a, _ in a } as CFDictionary)
            ?? builtIn
    }

    /// A frame from early in the clip, and the clip's length.
    public static func video(_ url: URL, maxPixels: Int) async -> Thumbnail? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        // A second in, past a black first frame, unless the clip is shorter.
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return Thumbnail(image: image, duration: duration)
    }

    /// The shot's tile: from its RAW, JPEG or clip. If that one can't be read
    /// (a RAW from a camera newer than this Mac knows), the shot's other
    /// files are tried: the JPEG of a pair, a clip's .THM.
    public static func make(for shot: Shot, maxPixels: Int, fileTypes: FileTypes = FileTypes(),
                            goodEnough: Double = 1) async -> Thumbnail? {
        let others = shot.files.filter { $0 != shot.primary }
            .sorted { fileTypes.kind(of: $0.newName).rank < fileTypes.kind(of: $1.newName).rank }
        var duration: Double?
        for file in [shot.primary] + others {
            guard let url = file.destinations.first else { continue }
            switch fileTypes.kind(of: file.newName) {
            case .raw, .photo:
                if let image = photo(url, maxPixels: maxPixels, goodEnough: goodEnough) {
                    return Thumbnail(image: image, duration: duration)
                }
            case .video:
                if let clip = await video(url, maxPixels: maxPixels) { return clip }
                // No frame, but the length can still go on the .THM's tile.
                duration = try? await AVURLAsset(url: url).load(.duration).seconds
            case .sidecar where ["thm", "jpg"].contains((file.newName as NSString).pathExtension.lowercased()):
                // Canon's .THM is a small JPEG of the clip's first frame.
                if let image = photo(url, maxPixels: maxPixels) { return Thumbnail(image: image, duration: duration) }
            default:
                continue
            }
        }
        return nil
    }

    private static func fullSize(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? .max
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? .max
        return max(width, height)
    }
}

/// Thumbnails for the grid, made in the background a few at a time so a
/// 2,000-file card doesn't slow the copy, and kept while they fit in
/// `byteLimit`, least recently shown going first. Asking twice for a
/// thumbnail that's still being made waits for the same one.
public actor ThumbnailCache {
    public typealias Maker = @Sendable (Shot, Int) async -> Thumbnail?

    public let maxPixels: Int
    private let byteLimit: Int
    private let concurrent: Int
    private let maker: Maker

    private var stored: [String: (thumbnail: Thumbnail, bytes: Int)] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var bytes = 0
    private var inFlight: [String: Task<Thumbnail?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - maxPixels: longest side of a tile.
    ///   - byteLimit: about 300 tiles of 400 pixels by default.
    ///   - concurrent: thumbnails made at once.
    public init(maxPixels: Int = 400, byteLimit: Int = 128 * 1024 * 1024, concurrent: Int = 3,
                maker: Maker? = nil) {
        self.maxPixels = maxPixels
        self.byteLimit = byteLimit
        self.concurrent = max(1, concurrent)
        self.maker = maker ?? { shot, pixels in await ThumbnailMaker.make(for: shot, maxPixels: pixels) }
    }

    /// The shot's tile, made if needed. Nil when none of its files can be
    /// shown, or when the asking task was cancelled (the tile scrolled away)
    /// before its turn came.
    public func thumbnail(for shot: Shot) async -> Thumbnail? {
        let key = Self.key(shot)
        if let hit = stored[key] {
            touch(key)
            return hit.thumbnail
        }
        if let task = inFlight[key] { return await task.value }
        await takeTurn()
        defer { endTurn() }
        if Task.isCancelled { return nil }
        // Someone else may have made it while this one waited.
        if let hit = stored[key] {
            touch(key)
            return hit.thumbnail
        }
        if let task = inFlight[key] { return await task.value }
        let maker = maker
        let pixels = maxPixels
        let task = Task.detached(priority: .utility) { await maker(shot, pixels) }
        inFlight[key] = task
        let made = await task.value
        inFlight[key] = nil
        if let made { store(made, key) }
        return made
    }

    /// What's already made, without waiting; for drawing a tile straight away.
    public func cached(_ shot: Shot) -> Thumbnail? {
        stored[Self.key(shot)]?.thumbnail
    }

    /// Bytes held, for tests.
    var storedBytes: Int { bytes }

    /// Each shot's tile file in the main destination: one copy, one key.
    static func key(_ shot: Shot) -> String {
        shot.primary.destinations.first?.path ?? shot.id
    }

    private func store(_ thumbnail: Thumbnail, _ key: String) {
        let size = thumbnail.image.bytesPerRow * thumbnail.image.height
        if let old = stored[key] { bytes -= old.bytes }
        stored[key] = (thumbnail, size)
        bytes += size
        touch(key)
        while bytes > byteLimit, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = stored.removeValue(forKey: oldest) { bytes -= gone.bytes }
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func takeTurn() async {
        if running < concurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            running -= 1
        } else {
            // Hand the turn straight to the next one waiting.
            waiting.removeFirst().resume()
        }
    }
}

/// The larger view: the photo filling the window, and every pixel the camera
/// recorded for checking focus. Read from the copies, never the card.
public enum LargeImage {
    /// To fill the window: the camera's biggest built-in preview, or the photo
    /// itself, at most `maxPixels` on its longest side; clips show a frame. A
    /// preview at least half that size is used as it is: decoding a Sony RAW
    /// just to fill the window made every photo wait (found 2026-10-23).
    public static func fit(_ shot: Shot, maxPixels: Int) async -> Thumbnail? {
        await ThumbnailMaker.make(for: shot, maxPixels: maxPixels, goodEnough: 0.45)
    }

    /// One image pixel for every pixel the camera recorded (100%), the right
    /// way up. A RAW uses its built-in preview only when that's full size;
    /// otherwise the RAW itself is decoded with Core Image, which takes a
    /// second or two for big files. Nil for clips, or if nothing can be read.
    public static func actualPixels(_ shot: Shot, fileTypes: FileTypes = FileTypes()) -> CGImage? {
        let pictures = ([shot.primary] + shot.files.filter { $0 != shot.primary })
            .filter { [.raw, .photo].contains(fileTypes.kind(of: $0.newName)) }
        for file in pictures {
            guard let url = file.destinations.first,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let full = fullSize(source) else { continue }
            let isRaw = fileTypes.kind(of: file.newName) == .raw
            // A JPEG or HEIC (or a RAW whose preview is full size) at its own size, turned upright.
            let options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: full,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            isRaw ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                                                  : kCGImageSourceCreateThumbnailFromImageAlways: true]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               Double(max(image.width, image.height)) >= Double(full) * 0.9 {
                return image
            }
            if isRaw, let image = decodeRaw(url) { return image }
        }
        return nil
    }

    private static func decodeRaw(_ url: URL) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: output.extent)
    }

    private static func fullSize(_ source: CGImageSource) -> Int? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }
}
