// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LinkDesk", platforms: [.macOS(.v14)],
    products: [.executable(name: "LinkDesk", targets: ["LinkDesk"])],
    targets: [
        .target(name: "LinkDeskCore", path: "macOS", exclude: ["AudioDriver"],
                sources: ["LDDesktopController.m", "LDColorEnhancement.m", "LDCursorBridge.m", "LDAudioBridge.m", "LDSystemVolume.m", "LDAudioSource.m", "LDMicrophoneBridge.m"],
                publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreImage"), .linkedFramework("Metal"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("Cocoa"),
                    .linkedFramework("CoreGraphics"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("VideoToolbox"),
                    .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("QuartzCore"), .linkedFramework("IOKit")]),
        .executableTarget(name: "LinkDesk", dependencies: ["LinkDeskCore"], path: "InkBridge/MacPDFAnnotator/Sources")
    ])
