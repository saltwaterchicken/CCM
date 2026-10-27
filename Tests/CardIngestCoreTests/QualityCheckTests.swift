import CoreGraphics
import CoreImage
import XCTest
@testable import CardIngestCore

final class QualityCheckTests: XCTestCase {
    /// Random grey speckle, like fine detail in focus, at a brightness scale.
    private func speckle(width: Int = 1200, height: Int = 800, scale: Double = 1, seed: UInt64 = 7) throws -> CGImage {
        var state = seed
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in pixels.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            // Blocks of 4 pixels, so the detail survives drawing it at the working size.
            let block = (i / width / 4) * 1000 + (i % width) / 4
            var b = UInt64(block) &* 0x9E3779B97F4A7C15 ^ seed
            b ^= b >> 29
            pixels[i] = UInt8(Double(40 + Int(b % 176)) * scale)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func blurred(_ image: CGImage, radius: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return try XCTUnwrap(CIContext().createCGImage(output, from: input.extent))
    }

    private func flat(_ value: UInt8, width: Int = 800, height: Int = 600) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: value, count: width * height) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testASharpPictureScoresFarAboveTheSameOneOutOfFocus() throws {
        let sharp = try XCTUnwrap(try QualityCheck.score(try speckle()))
        let soft = try XCTUnwrap(try QualityCheck.score(try blurred(try speckle(), radius: 4)))
        XCTAssertEqual(sharp.faces, 0)
        XCTAssertNil(sharp.faceSharpness)
        XCTAssertGreaterThan(sharp.areaSharpness, soft.areaSharpness * 10)
    }

    func testOneSharpAreaIsEnoughWithNoFace() throws {
        // A landscape with a soft sky and a sharp subject in one part is still sharp.
        let sharp = try speckle()
        let soft = try blurred(sharp, radius: 6)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(soft, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.clip(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        context.draw(sharp, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let mixed = try XCTUnwrap(try QualityCheck.score(try XCTUnwrap(context.makeImage())))
        let allSoft = try XCTUnwrap(try QualityCheck.score(soft))
        XCTAssertGreaterThan(mixed.areaSharpness, allSoft.areaSharpness * 10)
    }

    func testADarkPictureHasLessEdgeContrastAndSaysHowDarkItIs() throws {
        // Why faces are judged with their brightness: the same detail, a quarter as bright.
        let bright = try XCTUnwrap(try QualityCheck.score(try speckle()))
        let dark = try XCTUnwrap(try QualityCheck.score(try speckle(scale: 0.25)))
        XCTAssertLessThan(dark.areaSharpness, bright.areaSharpness / 8)
        XCTAssertLessThan(dark.areaBrightness, bright.areaBrightness / 3)
        XCTAssertEqual(dark.areaSharpness * pow(bright.areaBrightness / dark.areaBrightness, 2), bright.areaSharpness,
                       accuracy: bright.areaSharpness * 0.25)
    }

    func testBlownAndCrushedShares() throws {
        let white = try XCTUnwrap(try QualityCheck.score(try flat(255)))
        XCTAssertEqual(white.blown, 1, accuracy: 0.001)
        XCTAssertEqual(white.crushed, 0)
        XCTAssertEqual(white.areaSharpness, 0, accuracy: 0.001)
        let black = try XCTUnwrap(try QualityCheck.score(try flat(0)))
        XCTAssertEqual(black.crushed, 1, accuracy: 0.001)
        let grey = try XCTUnwrap(try QualityCheck.score(try flat(128)))
        XCTAssertEqual(grey.blown + grey.crushed, 0)
    }

    func testMeasuredAtTheWorkingSizeWhateverTheCamera() throws {
        let big = try XCTUnwrap(try QualityCheck.score(try speckle(width: 3000, height: 2000)))
        XCTAssertEqual(big.measuredAt, QualityCheck.workingSize)
        let small = try XCTUnwrap(try QualityCheck.score(try speckle(width: 1000, height: 700)))
        XCTAssertEqual(small.measuredAt, 1000, "Never enlarged")
    }

    func testAnUnreadableFileHasNoScore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QualityCheck-\(UUID().uuidString).NEF")
        try Data("not a photo".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(try QualityCheck.score(url))
    }
}
