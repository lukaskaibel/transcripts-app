// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscriptsKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "TranscriptsKit", targets: ["TranscriptsKit"]),
    ],
    dependencies: [
        // FluidAudio is vendored (see Packages/Vendor/FluidAudio) without its prebuilt text-normalization binary.
        .package(path: "../Vendor/FluidAudio"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TranscriptsKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // Resources: the app icon as a picture. AppIconPasses: the passes Settings › App-Icon colours, copied as they
            // are (Tools/AppIcon/make.sh renders both).
            resources: [.process("Resources"), .copy("AppIconPasses")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "transcripts-cli",
            dependencies: ["TranscriptsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscriptsKitTests",
            dependencies: ["TranscriptsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
