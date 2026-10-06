// Puts a full-bleed icon render on the macOS icon grid (an 824 px body on a 1024 px canvas), with the shadow the
// Dock draws, for the README.
//   swift Tools/pad-icon.swift <in.png> <out.png>
import AppKit

let canvas: CGFloat = 1024
let arguments = Array(CommandLine.arguments.dropFirst())
let icon = NSImage(contentsOfFile: arguments[0])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
context.draw(icon, in: CGRect(x: 100, y: 100, width: 824, height: 824))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[1]))
