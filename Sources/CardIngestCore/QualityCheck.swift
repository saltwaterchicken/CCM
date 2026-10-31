import CoreGraphics
import Foundation
import ImageIO
import Vision

/// How sharp and how well exposed one photo is, measured on the copy, never
/// the card. All on the Mac: ImageIO for the RAW's built-in preview, Vision
/// for faces, plain arithmetic for the rest.
public struct QualityScore: Sendable, Equatable {
    /// Faces big enough to judge.
    public let faces: Int
    /// Edge contrast (variance of the Laplacian) on the sharpest face, or nil
    /// when there's none. Skin is smooth, so this runs lower than `area` for
    /// the same focus and gets its own limit.
    public let faceSharpness: Double?
    /// The same on the sharpest area of the picture, faces or not.
    public let areaSharpness: Double
    /// Share of the picture blown to white, and crushed to black (0 to 1).
    public let blown: Double
    public let crushed: Double
    /// Vision's own face quality (blur, light, pose), 0 to 1, on the best face.
    public let faceQuality: Double?
    /// Average brightness (0 to 255) and contrast (standard deviation) of
    /// the sharpest face and of the sharpest area.
    public let faceBrightness: Double?
    public let faceContrast: Double?
    public let areaBrightness: Double
    public let areaContrast: Double
    /// The sharpest face measured after shrinking it to `faceWidth` pixels
    /// across, so a close-up and a face across the field compare fairly; and
    /// how wide it was at the working size.
    public let faceSharpnessScaled: Double?
    public let facePixels: Int?
    /// The longest side the scores were measured at.
    public let measuredAt: Int
    /// The largest face, most likely the subject, scored the way `faceScore`
    /// scores the sharpest: what the frames of a burst are compared on. Nil
    /// with no face.
    public var largestFaceScore: Double? = nil
}

extension QualityScore {
    /// What the face limit is compared with: the sharpest face measured at
    /// 64 pixels across, allowing for its brightness, since a face in shade
    /// has less edge contrast than the same face in sun. Nil with no face.
    public var faceScore: Double? {
        guard let scaled = faceSharpnessScaled else { return nil }
        return Self.faceScore(scaled: scaled, brightness: faceBrightness ?? 128)
    }

    /// How bright the subject is (0 to 255): the sharpest face, else the
    /// sharpest area. A lit face on a black stage stays bright here; an
    /// underexposed shot doesn't, however little of it is pure black.
    public var subjectBrightness: Double { faceBrightness ?? areaBrightness }

    /// What the frames of a burst are compared on: the largest face, else the
    /// sharpest area when there's no face.
    public var subjectSharpness: Double { largestFaceScore ?? areaSharpness }

    /// How a face's sharpness at `faceWidth` pixels is allowed for its brightness.
    static func faceScore(scaled: Double, brightness: Double) -> Double {
        scaled * pow(128 / max(brightness, 12), 2)
    }
}

public enum QualityCheck {
    /// Every photo is measured at the same size, so scores compare across
    /// cameras. Sony's built-in preview is 1,616 pixels, so a bigger size
    /// would mean decoding its RAWs.
    public static let workingSize = 1600
    /// Faces smaller than this (pixels across, at the working size) are too
    /// small to judge their focus.
    static let smallestFace = 48
    /// The sharpest-area search: the picture in a grid of this many squares across.
    static let grid = 8
    /// Faces are measured at this width.
    static let faceWidth = 64

    /// Scores a photo or RAW; nil if it can't be read. Throws when Vision
    /// couldn't look for faces, so a failure is never taken for "no face".
    public static func score(_ url: URL) throws -> QualityScore? {
        guard let image = ThumbnailMaker.photo(url, maxPixels: workingSize, goodEnough: 0.95) else { return nil }
        return try score(image)
    }

    public static func score(_ image: CGImage) throws -> QualityScore? {
        guard let gray = Gray(image, longest: workingSize) else { return nil }
        let faces = try findFaces(in: image).filter { CGFloat(gray.width) * $0.box.width >= CGFloat(smallestFace) }
        let faceScores = faces.map { face -> (sharpness: Double, mean: Double, deviation: Double, scaled: Double, pixels: Int) in
            // Vision's box is 0 to 1 from the bottom left; the buffer runs from the top.
            let box = face.box
            let x = Int(box.minX * CGFloat(gray.width)), w = Int(box.width * CGFloat(gray.width))
            let y = Int((1 - box.maxY) * CGFloat(gray.height)), h = Int(box.height * CGFloat(gray.height))
            let (mean, deviation) = gray.brightness(x: x, y: y, width: w, height: h)
            let crop = image.cropping(to: CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                                                 width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)))
            let small = crop.flatMap { Gray($0, width: faceWidth, height: max(1, faceWidth * $0.height / max($0.width, 1))) }
            let scaled = small.map { $0.laplacianVariance(x: 0, y: 0, width: $0.width, height: $0.height) } ?? 0
            return (gray.laplacianVariance(x: x, y: y, width: w, height: h), mean, deviation, scaled, w)
        }
        let bestFace = faceScores.max { $0.sharpness < $1.sharpness }
        let largestFace = faceScores.max { $0.pixels < $1.pixels }
        let side = max(gray.width, gray.height) / grid
        var areas: [(sharpness: Double, x: Int, y: Int)] = []
        for y in stride(from: 0, to: gray.height - side / 2, by: side) {
            for x in stride(from: 0, to: gray.width - side / 2, by: side) {
                areas.append((gray.laplacianVariance(x: x, y: y, width: side, height: side), x, y))
            }
        }
        // The second sharpest, so one square of noise or a bright edge doesn't decide it.
        let sorted = areas.sorted { $0.sharpness > $1.sharpness }
        let area = sorted.count > 1 ? sorted[1] : sorted.first ?? (0, 0, 0)
        let (areaMean, areaDeviation) = gray.brightness(x: area.x, y: area.y, width: side, height: side)
        let (blown, crushed) = gray.clipped()
        return QualityScore(faces: faces.count, faceSharpness: bestFace?.sharpness, areaSharpness: area.sharpness,
                            blown: blown, crushed: crushed, faceQuality: faces.compactMap(\.quality).max(),
                            faceBrightness: bestFace?.mean, faceContrast: bestFace?.deviation,
                            areaBrightness: areaMean, areaContrast: areaDeviation,
                            faceSharpnessScaled: bestFace?.scaled, facePixels: bestFace?.pixels,
                            measuredAt: max(gray.width, gray.height),
                            largestFaceScore: largestFace.map { QualityScore.faceScore(scaled: $0.scaled, brightness: $0.mean) })
    }

    private struct Face {
        let box: CGRect
        let quality: Double?
    }

    private static func findFaces(in image: CGImage) throws -> [Face] {
        let quality = VNDetectFaceCaptureQualityRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([quality])
        return (quality.results ?? []).map { Face(box: $0.boundingBox, quality: $0.faceCaptureQuality.map(Double.init)) }
    }
}

/// An 8-bit grey copy of a picture, for the arithmetic.
struct Gray {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage, longest: Int) {
        let scale = min(1, Double(longest) / Double(max(image.width, image.height)))
        self.init(image, width: max(1, Int((Double(image.width) * scale).rounded())),
                  height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    init?(_ image: CGImage, width: Int, height: Int) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Variance of the 4-neighbour Laplacian inside a rectangle: high where
    /// edges are crisp, low where they're soft.
    func laplacianVariance(x: Int, y: Int, width w: Int, height h: Int) -> Double {
        let x0 = max(1, x), y0 = max(1, y)
        let x1 = min(width - 1, x + w), y1 = min(height - 1, y + h)
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0, squares = 0.0
        pixels.withUnsafeBufferPointer { p in
            for row in y0..<y1 {
                let i = row * width
                for col in x0..<x1 {
                    let c = i + col
                    let l = Int(p[c - 1]) + Int(p[c + 1]) + Int(p[c - width]) + Int(p[c + width]) - 4 * Int(p[c])
                    sum += Double(l)
                    squares += Double(l * l)
                }
            }
        }
        let n = Double((x1 - x0) * (y1 - y0))
        let mean = sum / n
        return squares / n - mean * mean
    }

    /// Mean and standard deviation of the pixels inside a rectangle.
    func brightness(x: Int, y: Int, width w: Int, height h: Int) -> (mean: Double, deviation: Double) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return (0, 0) }
        var sum = 0.0, squares = 0.0
        pixels.withUnsafeBufferPointer { p in
            for row in y0..<y1 {
                for col in x0..<x1 {
                    let v = Double(p[row * width + col])
                    sum += v
                    squares += v * v
                }
            }
        }
        let n = Double((x1 - x0) * (y1 - y0))
        let mean = sum / n
        return (mean, (max(0, squares / n - mean * mean)).squareRoot())
    }

    /// Shares of pixels at the very top and very bottom of the range.
    func clipped() -> (blown: Double, crushed: Double) {
        var high = 0, low = 0
        for value in pixels {
            if value >= 250 { high += 1 } else if value <= 5 { low += 1 }
        }
        let n = Double(pixels.count)
        return (Double(high) / n, Double(low) / n)
    }
}
