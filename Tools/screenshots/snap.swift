import AppKit
import ScreenCaptureKit

// Captures one window of a process with ScreenCaptureKit, independent of what covers it.
//   snap <pid> <out.png> [index]   (index: which window, largest first; default 0)
_ = NSApplication.shared
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    print("usage: snap <pid> <out.png> [index]")
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
let index = args.count > 3 ? Int(args[3]) ?? 0 : 0

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = content.windows
            .filter { $0.owningApplication?.processID == pid && $0.frame.width > 60 && $0.frame.height > 40 && $0.windowLayer == 0 || ($0.owningApplication?.processID == pid && $0.windowLayer > 0 && $0.frame.width > 200) }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        guard windows.indices.contains(index) else {
            print("no window \(index) of \(pid); found \(windows.count)")
            exit(1)
        }
        let window = windows[index]
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesShadowsOnly = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out)
        print("ok \(Int(window.frame.width))x\(Int(window.frame.height))")
        exit(0)
    } catch {
        print("snap: \(error.localizedDescription)")
        exit(1)
    }
}
RunLoop.main.run()
