// Helpers for Tools/render-icons.sh.
//   swift Tools/pad-icon.swift <in> <out>              puts a full-bleed icon render on the macOS icon grid (an
//                                                      824 px body on a 1024 px canvas) with the Dock's shadow
//   swift Tools/pad-icon.swift --split <a> <b> <out>   light and dark halves, for the "Automatisch" choice
import AppKit

let canvas: CGFloat = 1024
let arguments = Array(CommandLine.arguments.dropFirst())

func write(_ draw: (CGContext) -> Void, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func image(_ path: String) -> CGImage {
    NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

if arguments.first == "--split" {
    let light = image(arguments[1])
    let dark = image(arguments[2])
    write({ context in
        let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
        context.draw(light, in: full)
        // The right half in dark, as System Settings shows its automatic appearance.
        context.clip(to: CGRect(x: canvas / 2, y: 0, width: canvas / 2, height: canvas))
        context.draw(dark, in: full)
    }, to: arguments[3])
} else {
    let icon = image(arguments[0])
    write({ context in
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
        context.draw(icon, in: CGRect(x: 100, y: 100, width: 824, height: 824))
    }, to: arguments[1])
}
