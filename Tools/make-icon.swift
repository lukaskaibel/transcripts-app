// Draws the app icons as Icon Composer documents, in the manner of Apple's own: one upright glyph, a speech
// bubble with a voice in it, on a plain ground.
//   Transcripts/AppIcon.icon      the app's icon: an indigo bubble on white, or on black in the dark appearance;
//                                 the system makes the tinted and clear versions from the same layers
//   Design/AppIcon-Indigo.icon    a white bubble on indigo, offered in Settings
//   swift Tools/make-icon.swift
// Then Tools/render-icons.sh renders them into the pictures the app and the README use.
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

/// A top-to-bottom gradient between two colours.
struct Shade {
    var top: UInt32
    var bottom: UInt32

    var gradient: CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray, locations: nil)!
    }

    var iconFill: [String: Any] {
        [
            "linear-gradient": [iconColor(top), iconColor(bottom)],
            "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
        ]
    }
}

/// Fills each shape with the same gradient, running from `top` to `bottom` (in canvas points).
func fill(_ context: CGContext, _ shapes: [CGPath], _ shade: Shade, from top: CGFloat, to bottom: CGFloat) {
    for shape in shapes {
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.drawLinearGradient(shade.gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
        context.restoreGState()
    }
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

let body = CGRect(x: 172, y: 220, width: 680, height: 500)

/// The bubble. Its left edge runs on into the tail, which flares out at the lower left and curves back into the
/// lower edge. Body and tail are filled one after the other: as one path, their windings would cut a hole.
func bubble(_ shade: Shade) -> Data {
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: body.minX + 4, y: body.maxY - 170))
    tail.addCurve(to: CGPoint(x: body.minX - 34, y: body.maxY + 54),
                  control1: CGPoint(x: body.minX + 2, y: body.maxY - 60), control2: CGPoint(x: body.minX - 6, y: body.maxY + 16))
    tail.addCurve(to: CGPoint(x: body.minX + 200, y: body.maxY - 2),
                  control1: CGPoint(x: body.minX + 42, y: body.maxY + 62), control2: CGPoint(x: body.minX + 128, y: body.maxY + 30))
    tail.addLine(to: CGPoint(x: body.minX + 200, y: body.maxY - 170))
    tail.closeSubpath()
    return layer { context in
        fill(context, [squircle(body, 190), tail], shade, from: body.minY, to: body.maxY + 54)
    }
}

/// The voice in the bubble: seven rounded bars, loudest in the middle.
func voice(_ shade: Shade) -> Data {
    let heights: [CGFloat] = [0.32, 0.62, 1.00, 0.72, 0.90, 0.50, 0.28]
    let width: CGFloat = 48
    let gap: CGFloat = 30
    let tallest: CGFloat = 300
    var x = body.midX - (CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap) / 2
    var bars: [CGPath] = []
    for height in heights {
        bars.append(squircle(CGRect(x: x, y: body.midY - height * tallest / 2, width: width, height: height * tallest), width / 2))
        x += width + gap
    }
    return layer { context in
        fill(context, bars, shade, from: body.midY - tallest / 2, to: body.midY + tallest / 2)
    }
}

/// An image, or one per appearance.
enum LayerImage {
    case one(String)
    case lightAndDark(String, String)

    var json: [String: Any] {
        switch self {
        case .one(let name): ["image-name": name]
        case .lightAndDark(let light, let dark): ["image-name-specializations": [["value": light], ["appearance": "dark", "value": dark]]]
        }
    }
}

/// Writes a document: the voice in front (crisp, only lightly shadowed), the glass bubble behind it.
func document(at url: URL, ground: Shade, darkGround: Shade?, bubble bubbleImage: LayerImage, bubbleTranslucency: Double?, voice voiceImage: LayerImage, images: [String: Data]) throws {
    var fills: [[String: Any]] = [["value": ground.iconFill]]
    if let darkGround { fills.append(["appearance": "dark", "value": darkGround.iconFill]) }
    let json: [String: Any] = [
        "fill-specializations": fills,
        "groups": [
            [
                "name": "Voice",
                "layers": [["name": "voice", "glass": false].merging(voiceImage.json) { $1 }],
                "shadow": ["kind": "layer-color", "opacity": 0.35],
                "translucency": ["enabled": false, "value": 0.5],
            ],
            [
                "name": "Bubble",
                "layers": [["name": "bubble", "glass": true].merging(bubbleImage.json) { $1 }],
                "shadow": ["kind": "layer-color", "opacity": 0.5],
                "translucency": ["enabled": bubbleTranslucency != nil, "value": bubbleTranslucency ?? 0.5],
            ],
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    // Start from an empty document, so images of an earlier design don't linger.
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url.appendingPathComponent("icon.json"))
    for (name, data) in images {
        try data.write(to: url.appendingPathComponent("Assets/\(name)"))
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let indigo = Shade(top: 0x7C83FF, bottom: 0x4338CA)
let white = Shade(top: 0xFFFFFF, bottom: 0xE9EAFB)

try document(
    at: root.appendingPathComponent("Transcripts/AppIcon.icon"),
    ground: Shade(top: 0xFFFFFF, bottom: 0xECEDF2), darkGround: Shade(top: 0x2C2C30, bottom: 0x0B0B0D),
    bubble: .lightAndDark("bubble-light.png", "bubble-dark.png"), bubbleTranslucency: nil,
    voice: .one("voice.png"),
    images: [
        "bubble-light.png": bubble(indigo),
        // A touch brighter on black, so the bubble doesn't sink into the dark ground.
        "bubble-dark.png": bubble(Shade(top: 0x8A90FF, bottom: 0x4C42D6)),
        "voice.png": voice(Shade(top: 0xFFFFFF, bottom: 0xE4E5FF)),
    ]
)
try document(
    at: root.appendingPathComponent("Design/AppIcon-Indigo.icon"),
    ground: indigo, darkGround: nil,
    bubble: .one("bubble.png"), bubbleTranslucency: 0.25,
    voice: .one("voice.png"),
    images: ["bubble.png": bubble(white), "voice.png": voice(indigo)]
)
print("Wrote AppIcon.icon and AppIcon-Indigo.icon")
