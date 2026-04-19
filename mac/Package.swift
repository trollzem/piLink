// swift-tools-version: 5.9
import PackageDescription

let libusbPrefix = "/opt/homebrew/opt/libusb"

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
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: nil,
            providers: []
        ),
        .executableTarget(
            name: "PiDisplaySender",
            dependencies: ["PiDisplayBridge", "CLibUSB"],
            cSettings: [
                .unsafeFlags(["-I\(libusbPrefix)/include"])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(libusbPrefix)/include"])
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOSurface"),
                .unsafeFlags(["-L\(libusbPrefix)/lib"]),
                .linkedLibrary("usb-1.0")
            ]
        )
    ]
)
