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
    return Calibration.captureOneStars(for: raw)
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
        if decode {
            if let image = decoded(url) { score = try QualityCheck.score(image) }
        } else {
            score = try QualityCheck.score(url)
        }
    } catch {
        FileHandle.standardError.write("\(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
    }
    let ms: Double = Date().timeIntervalSince(began) * 1000
    // Built a piece at a time: as one array literal the compiler gives up
    // type-checking it.
    var fields: [String] = [folder, url.lastPathComponent]
    fields.append(stars(for: url).map(String.init) ?? "")
    if let score {
        fields.append(String(score.faces))
    } else {
        fields.append("ERROR")
    }
    let measures: [Double?] = [score?.faceSharpness, score?.areaSharpness, score?.blown, score?.crushed,
                               score?.faceQuality, score?.faceBrightness, score?.faceContrast,
                               score?.areaBrightness, score?.areaContrast, score?.faceSharpnessScaled]
    fields += measures.map(text)
    let facePixels: Int? = score?.facePixels
    fields.append(facePixels.map(String.init) ?? "")
    let measuredAt: Int? = score?.measuredAt
    fields.append(measuredAt.map(String.init) ?? "")
    fields.append(String(format: "%.0f", ms))
    let line = fields.joined(separator: ",")
    lock.withLock { lines[i] = line }
}
print("folder,file,stars,faces,face_sharpness,area_sharpness,blown,crushed,face_quality,face_brightness,face_contrast,area_brightness,area_contrast,face_scaled,face_pixels,measured_at,ms")
lines.forEach { print($0) }
FileHandle.standardError.write("\(photos.count) photos in \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n".data(using: .utf8)!)
