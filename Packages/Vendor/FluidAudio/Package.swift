// swift-tools-version: 6.0
import PackageDescription

// FluidAudio 0.17.5 (https://github.com/FluidInference/FluidAudio, Apache 2.0), vendored without the
// prebuilt NeMo text-normalization binary: the app only uses speech recognition, voice activity
// detection and diarization, which don't need it. The sources are unchanged; see UPSTREAM_COMMIT.
let package = Package(
    name: "FluidAudio",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "FluidAudio", targets: ["FluidAudio"]),
    ],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: [
                "FastClusterWrapper",
                "MachTaskSelfWrapper",
            ],
            path: "Sources/FluidAudio",
            exclude: ["ASR/Parakeet/Unified/benchmark.md"],
            resources: [
                .process("TTS/LuxTts/G2p/Resources"),
            ]
        ),
        .target(
            name: "FastClusterWrapper",
            path: "Sources/FastClusterWrapper",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MachTaskSelfWrapper",
            path: "Sources/MachTaskSelfWrapper",
            publicHeadersPath: "include"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
