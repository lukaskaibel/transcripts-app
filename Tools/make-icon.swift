// Draws the app icon as an Icon Composer document: a speech bubble with two lines of transcript, each with its
// speaker's colour, in front of the waveform of a voice. Violet in the light appearance, dark in the dark one;
// the system adds the glass, and makes the tinted and clear versions from the same layers.
//   swift Tools/make-icon.swift
// Then Tools/render-icons.sh renders it into the PNGs the README uses.
import AppKit
import SwiftUI

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The colour as Icon Composer writes it.
func iconColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> String {
    let parts = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { String(format: "%.5f", CGFloat($0) / 255) }
    return "srgb:" + parts.joined(separator: ",") + String(format: ",%.5f", alpha)
}

func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath
}

func fill(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ fill: CGColor) {
    context.addPath(squircle(rect, radius))
    context.setFillColor(fill)
    context.fillPath()
}

/// A transparent 1024 px layer. Origin is top-left.
func layer(_ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The voice behind the bubble: a spoken phrase, loudest in the middle, fading out towards the edges.
func waveform(_ tint: CGColor) -> Data {
    let heights: [CGFloat] = [0.16, 0.30, 0.22, 0.48, 0.70, 0.42, 0.86, 1.00, 0.64, 0.80, 0.52, 0.34, 0.58, 0.26, 0.14]
    let width: CGFloat = 38
    let gap: CGFloat = 26
    let tallest: CGFloat = 780
    return layer { context in
        let middle = CGFloat(heights.count - 1) / 2
        var x = (canvas - CGFloat(heights.count) * width - CGFloat(heights.count - 1) * gap) / 2
        for (index, height) in heights.enumerated() {
            let bar = max(width, height * tallest)
            let distance = abs(CGFloat(index) - middle) / middle
            fill(context, CGRect(x: x, y: 512 - bar / 2, width: width, height: bar), radius: width / 2,
                 tint.copy(alpha: tint.alpha * (1 - 0.5 * distance * distance))!)
            x += width + gap
        }
    }
}

/// The transcript: a bubble turned a little, its tail growing out of the lower left corner, with two lines,
/// each after the dot of the person who said it.
func bubble() -> Data {
    layer { context in
        context.translateBy(x: 524, y: 470)
        context.rotate(by: -8 * .pi / 180)
        let rect = CGRect(x: -300, y: -200, width: 600, height: 400)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: rect.minX, y: rect.maxY - 150))
        tail.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 30))
        tail.addCurve(to: CGPoint(x: rect.minX - 12, y: rect.maxY + 80),
                      control1: CGPoint(x: rect.minX, y: rect.maxY + 18), control2: CGPoint(x: rect.minX - 3, y: rect.maxY + 58))
        tail.addCurve(to: CGPoint(x: rect.minX + 146, y: rect.maxY),
                      control1: CGPoint(x: rect.minX + 38, y: rect.maxY + 64), control2: CGPoint(x: rect.minX + 92, y: rect.maxY + 10))
        tail.addLine(to: CGPoint(x: rect.minX + 146, y: rect.maxY - 150))
        tail.closeSubpath()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF), color(0xEEF0FF)] as CFArray, locations: nil)!
        for shape in [squircle(rect, 92), tail] {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY + 80), options: [])
            context.restoreGState()
        }

        let lines: [(speaker: UInt32, width: CGFloat, ink: CGFloat)] = [(0x5AB0D8, 330, 0.88), (0xE5A84B, 220, 0.40)]
        let dot: CGFloat = 42
        for (index, line) in lines.enumerated() {
            let y = rect.minY + 128 + CGFloat(index) * 144
            context.setFillColor(color(line.speaker))
            context.fillEllipse(in: CGRect(x: rect.minX + 70, y: y - dot, width: dot * 2, height: dot * 2))
            fill(context, CGRect(x: rect.minX + 70 + dot * 2 + 34, y: y - 20, width: line.width, height: 40), radius: 20, color(0x3A41B0, line.ink))
        }
    }
}

func gradientFill(_ top: UInt32, _ bottom: UInt32) -> [String: Any] {
    [
        "linear-gradient": [iconColor(top), iconColor(bottom)],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ]
}

let icon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Transcripts/AppIcon.icon")
let json: [String: Any] = [
    "fill-specializations": [
        ["value": gradientFill(0x9198F6, 0x4C54C6)],
        ["appearance": "dark", "value": gradientFill(0x2A2D35, 0x0F1013)],
    ],
    "groups": [
        [
            "name": "Bubble",
            "layers": [["name": "bubble", "image-name": "bubble.png", "glass": true]],
            "shadow": ["kind": "layer-color", "opacity": 0.6],
            "translucency": ["enabled": false, "value": 0.4],
        ],
        [
            "name": "Voice",
            "layers": [[
                "name": "waveform",
                "image-name-specializations": [["value": "waveform-light.png"], ["appearance": "dark", "value": "waveform-dark.png"]],
                "glass": false,
            ]],
            "shadow": ["kind": "none", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5],
        ],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
try FileManager.default.createDirectory(at: icon.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: icon.appendingPathComponent("icon.json"))
try bubble().write(to: icon.appendingPathComponent("Assets/bubble.png"))
try waveform(color(0xFFFFFF, 0.30)).write(to: icon.appendingPathComponent("Assets/waveform-light.png"))
try waveform(color(0x8F96F2, 0.30)).write(to: icon.appendingPathComponent("Assets/waveform-dark.png"))
print("Wrote \(icon.lastPathComponent)")
