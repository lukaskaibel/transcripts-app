import CoreGraphics
import Foundation
import Testing
@testable import TranscriptsKit

/// The dictaphone on the app icon: its shades match Tools/AppIcon/dictaphone.py, and adding up the passes gives the
/// icons Apple's ictool draws for Transcripts/AppIcon.icon and the presets.
@MainActor
struct AppIconTests {
    private func hex(_ value: UInt32) -> IconColor { IconColor(hex: value) }

    @Test func groundShadesMatchTheIconScript() {
        let look = AppIconLook.standard
        #expect(look.ground(dark: false).0 == hex(0xECE8E1))
        #expect(look.ground(dark: false).1 == hex(0xD0CCC5))
        #expect(look.ground(dark: true).0 == hex(0x474645), "dark mode stands on a warm dark grey, not black")
        #expect(look.ground(dark: true).1 == hex(0x272726))
        #expect(AppIconPreset.silver.look.ground(dark: true).0 == hex(0x464748))
        #expect(AppIconPreset.white.look.ground(dark: false).1 == hex(0xC7CBC3))
    }

    @Test func standardDictaphoneLooksLikeTheAppIcon() throws {
        // ictool's own render of Transcripts/AppIcon.icon at 512 px, in Display P3: the body, the grille's rim, the
        // record button and the ground.
        let light = try #require(AppIconRenderer.shared.image(.standard, dark: false))
        #expect(light.width == 512)
        expectPixel(light, 215, 300, near: [80, 80, 82])
        expectPixel(light, 193, 157, near: [194, 196, 200])
        expectPixel(light, 256, 361, near: [217, 102, 94])
        expectPixel(light, 60, 256, near: [222, 217, 213])
        #expect(pixel(light, 0, 0)[3] == 0, "outside the rounded square is clear")

        let dark = try #require(AppIconRenderer.shared.image(.standard, dark: true))
        expectPixel(dark, 215, 300, near: [80, 80, 83])
        expectPixel(dark, 256, 361, near: [216, 102, 94])
        expectPixel(dark, 60, 256, near: [54, 53, 54])
    }

    @Test func presetsLookLikeTheirIcons() throws {
        // ictool's renders of Transcripts/AppIcon-*.icon, the presets' icons on iPhone and iPad.
        let expected: [AppIconPreset: (body: [Int], grille: [Int], button: [Int], ground: [Int])] = [
            .silver: ([214, 216, 218], [63, 64, 69], [217, 102, 94], [215, 218, 226]),
            .titanium: ([183, 177, 168], [107, 103, 96], [238, 126, 92], [222, 217, 213]),
            .white: ([239, 239, 237], [194, 196, 200], [217, 102, 94], [213, 216, 209]),
            .midnight: ([78, 82, 93], [194, 196, 200], [217, 102, 94], [215, 218, 226]),
        ]
        for (preset, colours) in expected {
            let icon = try #require(AppIconRenderer.shared.image(preset.look, dark: false))
            expectPixel(icon, 215, 300, near: colours.body, "\(preset) body")
            expectPixel(icon, 193, 157, near: colours.grille, "\(preset) grille")
            expectPixel(icon, 256, 361, near: colours.button, "\(preset) button")
            expectPixel(icon, 60, 256, near: colours.ground, "\(preset) ground")
        }
        let titanium = try #require(AppIconRenderer.shared.image(AppIconPreset.titanium.look, dark: true))
        expectPixel(titanium, 256, 361, near: [237, 125, 92])
    }

    @Test func anyColours() throws {
        var look = AppIconLook.standard
        look.body = hex(0x2F7BF5)
        look.button = hex(0x34B35A)
        let icon = try #require(AppIconRenderer.shared.image(look, dark: false))
        let body = pixel(icon, 215, 300), button = pixel(icon, 256, 361)
        #expect(body[2] > body[0] + 60, "a blue body is blue")
        #expect(button[1] > button[0] + 40, "a green button is green")
        expectPixel(icon, 60, 256, near: [222, 217, 213], "the ground stays as it was")
    }

    @Test func dockImageSitsOnTheIconGrid() throws {
        let image = try #require(AppIconRenderer.shared.dockImage(.standard, dark: false))
        #expect(image.width == 636)
        #expect(pixel(image, 30, 318)[3] == 0, "a margin round the icon, as on Apple's grid")
        #expect(pixel(image, 318, 318)[3] == 255)
    }

    @Test func lookIsKept() throws {
        let defaults = UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.appIcon == .standard)
        let look = AppIconLook(body: hex(0x6B2128), grille: hex(0xD9C49B), button: hex(0xF4F4F2), ground: hex(0xE5EDF4))
        settings.appIcon = look
        #expect(AppSettings(defaults: defaults).appIcon == look)
        #expect(AppIconPreset(look) == nil)
        #expect(AppIconPreset(AppIconPreset.midnight.look) == .midnight)
    }

    @Test func everyPresetIsAnIconOfTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../..").standardizedFileURL
        let config = try String(contentsOf: root.appendingPathComponent("Config/Shared.xcconfig"), encoding: .utf8)
        for preset in AppIconPreset.allCases {
            guard let name = preset.alternateIconName else { continue }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Transcripts/\(name).icon/icon.json").path), "\(name)")
            #expect(config.contains(name), "\(name) is listed as an alternate icon")
        }
    }

    // MARK: - Pixels

    /// RGBA at a point, top-left origin, in Display P3.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(p[$0]) }
    }

    private func expectPixel(_ image: CGImage, _ x: Int, _ y: Int, near expected: [Int], _ message: String = "",
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let p = pixel(image, x, y)
        let close = (0..<3).allSatisfy { abs(p[$0] - expected[$0]) <= 4 }
        #expect(close, "pixel \(x),\(y) is \(Array(p.prefix(3))), expected about \(expected). \(message)", sourceLocation: sourceLocation)
    }
}
