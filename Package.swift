// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "syscap",
    platforms: [.macOS("14.4")],
    targets: [
        // L'Info.plist doit être embarqué dans le binaire : sans NSAudioCaptureUsageDescription,
        // TCC ne demande jamais la permission et le tap ne renvoie que du silence.
        .executableTarget(
            name: "syscap",
            path: "Sources/syscap",
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/syscap/Info.plist",
            ])]
        )
    ]
)
