import AppKit

// Draws the app icon: a dark rounded square with a waveform in the app's accent colour.
//   swift Tools/make-icon.swift Transcripts/Assets.xcassets/AppIcon.appiconset
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(size: Int) -> Data {
    // A bitmap of exactly `size` pixels; drawing into an NSImage would follow the screen's scale.
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    // Apple's icon grid: an 824 pt square with a 185 pt corner radius, centred, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor(srgbRed: 0.09, green: 0.094, blue: 0.106, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // A gentle light from the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1).cgColor,
        NSColor(srgbRed: 0.075, green: 0.078, blue: 0.09, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    context.setLineWidth(6)
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    context.strokePath()
    context.restoreGState()

    // The waveform: seven rounded bars, the middle ones tallest.
    let heights: [CGFloat] = [150, 270, 420, 520, 380, 250, 140]
    let barWidth: CGFloat = 56
    let gap: CGFloat = 34
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    let accent = NSColor(srgbRed: 0.561, green: 0.588, blue: 0.949, alpha: 1)
    let accentLight = NSColor(srgbRed: 0.72, green: 0.74, blue: 1, alpha: 1)
    for (index, height) in heights.enumerated() {
        let rect = CGRect(x: x, y: 512 - height / 2, width: barWidth, height: height)
        let bar = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        context.saveGState()
        context.addPath(bar)
        context.clip()
        let barGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [accentLight.cgColor, accent.cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(barGradient, start: CGPoint(x: x, y: rect.maxY), end: CGPoint(x: x, y: rect.minY), options: [])
        context.restoreGState()
        if index == 3 {
            // A small red dot above the tallest bar: recording.
            context.setFillColor(NSColor(srgbRed: 0.92, green: 0.42, blue: 0.42, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: x + barWidth / 2 - 30, y: rect.maxY + 34, width: 60, height: 60))
        }
        x += barWidth + gap
    }

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: pixels).write(to: output.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icon sizes to \(output.path)")
