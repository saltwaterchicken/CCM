import CardIngestCore
import Foundation

// Scores every RAW in the folders given, for calibrating auto-rating. Only
// reads: nothing in the folders is changed. Prints one CSV line per photo
// with the stars its sidecar holds, so scores can be compared with a cull.
// Capture One sessions' ratings are read from CaptureOne/Settings*/NAME.cos.
// --decode scores the RAW itself, drawn at the working size, instead of the
// preview the camera built in, to check that preview is good enough.
//   swift run -c release score-folder [--decode] FOLDER... > scores.csv
import ImageIO

let raws: Set<String> = ["nef", "cr3", "cr2", "arw", "raf", "dng", "orf", "rw2"]
var photos: [(folder: String, url: URL)] = []
let decode = CommandLine.arguments.contains("--decode")
for path in CommandLine.arguments.dropFirst() where path != "--decode" {
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names.sorted() where !name.hasPrefix(".") && raws.contains((name as NSString).pathExtension.lowercased()) {
        photos.append((folder.lastPathComponent, folder.appendingPathComponent(name)))
    }
}

func stars(for raw: URL) -> Int? {
    let base = raw.deletingPathExtension()
    if let stars = ["xmp", "XMP"].lazy.compactMap({ Stars.read(xmp: base.appendingPathExtension($0)) }).first {
        return stars
    }
    let sessions = raw.deletingLastPathComponent().appendingPathComponent("CaptureOne")
    for settings in (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [] where settings.hasPrefix("Settings") {
        let cos = sessions.appendingPathComponent(settings).appendingPathComponent(raw.lastPathComponent + ".cos")
        // One entry per variant; the last is the one Capture One shows (checked against an export).
        guard let text = try? String(contentsOf: cos, encoding: .utf8),
              let range = text.range(of: #"K="Basic_Rating" V="(-?\d)""#, options: [.regularExpression, .backwards])
        else { continue }
        return Int(text[range].filter { $0.isNumber || $0 == "-" })
    }
    return nil
}

/// The RAW itself, drawn at the working size.
func decoded(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceThumbnailMaxPixelSize: QualityCheck.workingSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)
}

func text(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "" }

var lines = [String](repeating: "", count: photos.count)
let lock = NSLock()
let start = Date()
DispatchQueue.concurrentPerform(iterations: photos.count) { i in
    let (folder, url) = photos[i]
    let began = Date()
    var score: QualityScore?
    do {
        score = try decode ? decoded(url).flatMap { try QualityCheck.score($0) } : QualityCheck.score(url)
    } catch {
        FileHandle.standardError.write("\(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
    }
    let ms = Date().timeIntervalSince(began) * 1000
    let line = [folder, url.lastPathComponent, stars(for: url).map(String.init) ?? "",
                score.map { String($0.faces) } ?? "ERROR", text(score?.faceSharpness), text(score?.areaSharpness),
                text(score?.blown), text(score?.crushed), text(score?.faceQuality),
                text(score?.faceBrightness), text(score?.faceContrast), text(score?.areaBrightness), text(score?.areaContrast),
                text(score?.faceSharpnessScaled), score?.facePixels.map(String.init) ?? "",
                score.map { String($0.measuredAt) } ?? "", String(format: "%.0f", ms)].joined(separator: ",")
    lock.withLock { lines[i] = line }
}
print("folder,file,stars,faces,face_sharpness,area_sharpness,blown,crushed,face_quality,face_brightness,face_contrast,area_brightness,area_contrast,face_scaled,face_pixels,measured_at,ms")
lines.forEach { print($0) }
FileHandle.standardError.write("\(photos.count) photos in \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n".data(using: .utf8)!)
