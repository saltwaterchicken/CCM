import AVFoundation
import Foundation
import ImageIO

/// Reads when a picture or clip was taken, from the file itself.
public enum CaptureDate {
    /// EXIF DateTimeOriginal for photos and RAW, the creation date for video.
    /// Nil when the file doesn't say; the caller falls back to the modified date.
    /// `timeZone` is the one the camera's clock was set to (EXIF has no zone).
    public static func read(_ url: URL, kind: FileKind, timeZone: TimeZone = .current) -> Date? {
        switch kind {
        case .raw, .photo: return fromImage(url, timeZone: timeZone)
        case .video: return fromVideo(url)
        case .sidecar, .other: return nil
        }
    }

    static func fromImage(_ url: URL, timeZone: TimeZone) -> Date? {
        // Only the metadata is read, never the picture itself.
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// When a photo was taken to the hundredth of a second, where the camera
    /// records it (EXIF SubSecTimeOriginal), to tell the frames of a burst.
    /// Nil when the photo doesn't say when it was taken.
    public static func moment(_ url: URL, timeZone: TimeZone = .current) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let taken = fromImage(url, timeZone: timeZone) else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var date = taken
        if let digits = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)?.trimmingCharacters(in: .whitespaces),
           !digits.isEmpty, digits.allSatisfy(\.isNumber), let fraction = Double("0." + digits) {
            date += fraction
        }
        return date
    }

    static func fromVideo(_ url: URL) -> Date? {
        final class Box: @unchecked Sendable { var date: Date? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            if let item = try? await asset.load(.creationDate) {
                box.date = try? await item.load(.dateValue)
            }
            done.signal()
        }
        done.wait()
        return box.date
    }
}
