// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiDisplaySender",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PiDisplayBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-Wno-objc-property-no-attribute"])
            ]
        ),
        .executableTarget(
            name: "PiDisplaySender",
            dependencies: ["PiDisplayBridge"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOSurface")
            ]
        )
    ]
)
