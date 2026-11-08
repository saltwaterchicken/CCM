// Turns a square logo that fills its whole image (no clear background) into
// the usual Mac icon shape: a rounded square with a margin, clear outside.
// make-app.sh runs it only for a logo with no transparency.
// Usage: swift shape-icon.swift in.png out.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let image = NSImage(contentsOfFile: args[1]),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Can't read the logo.\n".data(using: .utf8)!)
    exit(1)
}

// Apple's icon grid at 1024: an 824-point rounded square, corner radius about 185.
let size = 1024
let inset: CGFloat = 100
let radius: CGFloat = 185
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
let box = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.draw(source, in: box)

guard let out = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: args[2]))
} catch {
    FileHandle.standardError.write("Can't write the icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
