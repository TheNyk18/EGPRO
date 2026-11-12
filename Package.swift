// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EGPRO",
    platforms: [.macOS(.v14)],
    targets: [
        // Motorul audio (Objective-C): ia sunetul Mac-ului, il egalizeaza si il trimite la boxe/casti.
        .target(
            name: "EGAudio",
            path: "Sources/EGAudio",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Aplicatia (SwiftUI): iconita din bara de sus si fereastra cu egalizatorul.
        .executableTarget(
            name: "EGPRO",
            dependencies: ["EGAudio"],
            path: "Sources/EGPRO"
        ),
    ]
)
