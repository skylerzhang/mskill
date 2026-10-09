import AppKit

// The selected artwork has an opaque exterior. Use an inset squircle matte
// to retain the illustration while clearing the canvas around the app tile.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/prepare-app-icon.swift INPUT.png OUTPUT.png\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let sourceData = try Data(contentsOf: sourceURL)
guard let source = NSBitmapImageRep(data: sourceData),
      let sourceImage = source.cgImage,
      source.pixelsWide == source.pixelsHigh else {
    fatalError("The selected app icon must be a square image.")
}

let size = source.pixelsWide
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Cannot create the icon canvas.")
}

let canvas = CGRect(x: 0, y: 0, width: size, height: size)
context.clear(canvas)
context.setShouldAntialias(true)

// Fit the blue tile's silhouette and inset its edge slightly so none of the
// original white matte is included in anti-aliased pixels.
let center = CGFloat(size) / 2
let radius = CGFloat(size) * (561.5 / 1254.0)
let exponent = 2.0 / 4.8
let path = CGMutablePath()
for step in 0..<1024 {
    let angle = Double(step) * 2 * .pi / 1024
    let cosine = cos(angle)
    let sine = sin(angle)
    let x = center + radius * CGFloat(copysign(pow(abs(cosine), exponent), cosine))
    let y = center + radius * CGFloat(copysign(pow(abs(sine), exponent), sine))
    if step == 0 {
        path.move(to: CGPoint(x: x, y: y))
    } else {
        path.addLine(to: CGPoint(x: x, y: y))
    }
}
path.closeSubpath()
context.addPath(path)
context.clip()
context.draw(sourceImage, in: canvas)

let result = NSBitmapImageRep(cgImage: context.makeImage()!)
for point in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1),
              (size / 2, 0), (0, size / 2), (size - 1, size / 2), (size / 2, size - 1)] {
    precondition(result.colorAt(x: point.0, y: point.1)!.alphaComponent == 0)
}
let png = result.representation(using: .png, properties: [:])!
try png.write(to: outputURL, options: .atomic)
print("Saved transparent icon: \(outputURL.path)")
