import Accelerate
import CoreGraphics
import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Draws the dictaphone in any colours. Apple's ictool rendered it once per part in grey with everything else black
/// (Tools/AppIcon/make.sh), so the shadows, the lighting and the materials are the real icon's; adding the passes up in
/// linear light, each scaled by its colour, gives the icon: base + Σ colour × (pass − base) / grey.
@MainActor
final class AppIconRenderer {
    static let shared = AppIconRenderer()

    /// The passes' size, in pixels: enough for the Dock at its largest.
    static let size = 512
    /// The albedo each part has in its pass (#B4B4B4), in linear light.
    private static let passGrey = Float(decode(Double(0xB4) / 255))

    private enum Part: String, CaseIterable { case ground, body, grille, button }

    /// Planar linear-light channels of one look's passes: the base, its alpha and each part's difference to the base.
    private struct Passes {
        var base: [[Float]]
        var alpha: [Float]
        var parts: [Part: [[Float]]]
    }

    private var passes: [Bool: Passes] = [:]
    /// Icons drawn recently, at Dock proportions: the Settings previews ask for the same ones again and again.
    private var drawn: [Key: CGImage] = [:]
    private var drawnOrder: [Key] = []

    private struct Key: Hashable {
        var look: AppIconLook
        var dark: Bool
    }

    /// The icon as the system draws a full-bleed icon: the rounded square filling the image. Linear Display P3 in
    /// floats; whatever draws it brings it to its own colour space.
    func image(_ look: AppIconLook, dark: Bool) -> CGImage? {
        guard let passes = loadPasses(dark: dark) else { return nil }
        let n = Self.size
        var channels = passes.base
        let ground = gradient(look.ground(dark: dark))
        for part in Part.allCases {
            guard let deltas = passes.parts[part] else { continue }
            let flat: SIMD3<Float>? = switch part {
            case .ground: nil
            case .body: Self.linearDisplayP3(look.body.components)
            case .grille: Self.linearDisplayP3(look.grille.components)
            case .button: Self.linearDisplayP3(look.button.components)
            }
            for channel in 0..<3 {
                deltas[channel].withUnsafeBufferPointer { delta in
                    channels[channel].withUnsafeMutableBufferPointer { out in
                        if var scale = flat?[channel] {
                            vDSP_vsma(delta.baseAddress!, 1, &scale, out.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(n * n))
                        } else {
                            // The ground runs from one shade at the top to another at the bottom, row by row.
                            for row in 0..<n {
                                var scale = ground[row][channel]
                                let at = row * n
                                vDSP_vsma(delta.baseAddress! + at, 1, &scale, out.baseAddress! + at, 1, out.baseAddress! + at, 1, vDSP_Length(n))
                            }
                        }
                    }
                }
            }
        }
        var low: Float = 0, high: Float = 1
        for channel in 0..<3 {
            channels[channel].withUnsafeMutableBufferPointer { v in
                vDSP_vclip(v.baseAddress!, 1, &low, &high, v.baseAddress!, 1, vDSP_Length(n * n))
            }
        }
        // Interleaved as RGBA floats with straight alpha.
        var rgba = [Float](repeating: 0, count: n * n * 4)
        var (red, green, blue, alpha) = (channels[0], channels[1], channels[2], passes.alpha)
        let converted: vImage_Error = rgba.withUnsafeMutableBytes { out in
            var dest = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 16)
            // Planes in, in byte order: R, G, B, A.
            return Self.planar(&red) { r in Self.planar(&green) { g in Self.planar(&blue) { b in Self.planar(&alpha) { a in
                vImageConvert_PlanarFtoARGBFFFF(&r, &g, &b, &a, &dest, vImage_Flags(kvImageNoFlags))
            } } } }
        }
        guard converted == kvImageNoError,
              let provider = CGDataProvider(data: rgba.withUnsafeBytes { Data($0) } as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearDisplayP3) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: n, height: n, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: n * 16, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The icon as the Dock shows it: on Apple's icon grid (824 of 1024), with the Dock's soft shadow.
    func dockImage(_ look: AppIconLook, dark: Bool) -> CGImage? {
        let key = Key(look: look, dark: dark)
        if let image = drawn[key] { return image }
        guard let icon = image(look, dark: dark) else { return nil }
        let content = CGFloat(Self.size), canvas = (content / 824 * 1024).rounded()
        let inset = ((canvas - content) / 2).rounded()
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = content / 824
        context.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.28))
        context.draw(icon, in: CGRect(x: inset, y: inset, width: content, height: content))
        guard let padded = context.makeImage() else { return nil }
        drawn[key] = padded
        drawnOrder.append(key)
        if drawnOrder.count > 24 { drawn[drawnOrder.removeFirst()] = nil }
        return padded
    }

    /// The Dock image as a picture for SwiftUI and AppKit, in points (two pixels each).
    func picture(_ look: AppIconLook, dark: Bool) -> PlatformImage? {
        guard let image = dockImage(look, dark: dark) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        #else
        return UIImage(cgImage: image, scale: 2, orientation: .up)
        #endif
    }

    // MARK: - Passes

    private func loadPasses(dark: Bool) -> Passes? {
        if let loaded = passes[dark] { return loaded }
        let look = dark ? "dark" : "light"
        guard let (base, alpha) = Self.load("\(look)-base") else { return nil }
        var parts: [Part: [[Float]]] = [:]
        var scale = 1 / Self.passGrey
        for part in Part.allCases {
            guard var (pass, _) = Self.load("\(look)-\(part.rawValue)") else { return nil }
            for channel in 0..<3 {
                pass[channel].withUnsafeMutableBufferPointer { p in
                    base[channel].withUnsafeBufferPointer { b in
                        let count = vDSP_Length(p.count)
                        vDSP_vsub(b.baseAddress!, 1, p.baseAddress!, 1, p.baseAddress!, 1, count)   // pass − base
                        vDSP_vsmul(p.baseAddress!, 1, &scale, p.baseAddress!, 1, count)
                    }
                }
            }
            parts[part] = pass
        }
        let loaded = Passes(base: base, alpha: alpha, parts: parts)
        passes[dark] = loaded
        return loaded
    }

    /// A pass as linear-light channels and its alpha. The passes are Display P3 with the sRGB curve; drawing them into
    /// a Display P3 context leaves their values as they are.
    private static func load(_ name: String) -> ([[Float]], [Float])? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "AppIconPasses"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let n = size * size
        var rgba = vImage_Buffer(data: data, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size * 4)
        var (r8, g8, b8, a8) = ([UInt8](repeating: 0, count: n), [UInt8](repeating: 0, count: n),
                                [UInt8](repeating: 0, count: n), [UInt8](repeating: 0, count: n))
        var error = vImageUnpremultiplyData_RGBA8888(&rgba, &rgba, vImage_Flags(kvImageNoFlags))
        if error == kvImageNoError {
            // Planes out, in byte order: R, G, B, A.
            error = planar(&r8) { r in planar(&g8) { g in planar(&b8) { b in planar(&a8) { a in
                vImageConvert_ARGB8888toPlanar8(&rgba, &r, &g, &b, &a, vImage_Flags(kvImageNoFlags))
            } } } }
        }
        let decoded = decodeTable, linear = (0...255).map { Float($0) / 255 }
        var channels: [[Float]] = []
        for (index, var plane) in [r8, g8, b8, a8].enumerated() where error == kvImageNoError {
            var out = [Float](repeating: 0, count: n)
            error = planar(&plane) { source in planar(&out) { dest in
                vImageLookupTable_Planar8toPlanarF(&source, &dest, index == 3 ? linear : decoded, vImage_Flags(kvImageNoFlags))
            } }
            channels.append(out)
        }
        guard error == kvImageNoError, channels.count == 4 else { return nil }
        return (Array(channels.prefix(3)), channels[3])
    }

    /// A vImage buffer over one plane of the icon.
    private static func planar<T, R>(_ plane: inout [T], _ body: (inout vImage_Buffer) -> R) -> R {
        plane.withUnsafeMutableBytes { bytes in
            var buffer = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(size), width: vImagePixelCount(size),
                                       rowBytes: size * MemoryLayout<T>.stride)
            return body(&buffer)
        }
    }

    // MARK: - Colour

    /// Rows of linear Display P3 colour for the ground's gradient from the top of the icon to its bottom, mixed in
    /// sRGB as Icon Composer mixes it.
    private func gradient(_ colours: (IconColor, IconColor)) -> [SIMD3<Float>] {
        let n = Self.size
        let top = colours.0.components, bottom = colours.1.components
        return (0..<n).map { row in
            let t = (Double(row) + 0.5) / Double(n)
            return Self.linearDisplayP3(top * (1 - t) + bottom * t)
        }
    }

    /// sRGB → linear sRGB → linear Display P3.
    private static func linearDisplayP3(_ srgb: SIMD3<Double>) -> SIMD3<Float> {
        let l = SIMD3(decode(srgb.x), decode(srgb.y), decode(srgb.z))
        return SIMD3(Float(0.8225 * l.x + 0.1774 * l.y),
                     Float(0.0332 * l.x + 0.9669 * l.y),
                     Float(0.0171 * l.x + 0.0724 * l.y + 0.9108 * l.z))
    }

    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static let decodeTable: [Float] = (0...255).map { Float(decode(Double($0) / 255)) }
}

#if os(macOS)
/// Your dictaphone in the Dock while the app runs, in light or dark with the system. The standard one is the app's own
/// icon, so the Dock keeps that one with its tinted and clear looks.
@MainActor
final class AppIconDock {
    static let shared = AppIconDock()

    private var look = AppIconLook.standard
    private var appearanceObservation: NSKeyValueObservation?
    private var pending: Task<Void, Never>?

    func show(_ look: AppIconLook) {
        self.look = look
        if appearanceObservation == nil {
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.apply() }
            }
        }
        // While a colour is dragged in the colour panel, the Dock follows a moment after it stops.
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    private func apply() {
        guard look != .standard else {
            NSApp.applicationIconImage = nil
            return
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = AppIconRenderer.shared.picture(look, dark: dark)
    }
}
#endif
