// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceCodex",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoiceCodex", targets: ["VoiceCodex"])],
    targets: [
        .target(name: "VoiceCodexCore"),
        .executableTarget(name: "VoiceCodex", dependencies: ["VoiceCodexCore"]),
        .testTarget(name: "VoiceCodexCoreTests", dependencies: ["VoiceCodexCore"]),
        .testTarget(name: "VoiceCodexSTTTests", dependencies: ["VoiceCodex"])
    ]
)
