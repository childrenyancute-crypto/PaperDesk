// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PaperDesk", targets: ["PaperDeskApp"]),
        .executable(name: "paperdesk-mcp", targets: ["PaperDeskMCP"]),
        .executable(name: "paperdesk-check", targets: ["PaperDeskCheck"])
    ],
    targets: [
        .target(name: "PaperDeskCore"),
        // SwiftMath 1.7.3 is vendored under Sources/SwiftMath so builds remain
        // offline and reproducible. Only Latin Modern Math and its licenses
        // are included in the resource bundle.
        .target(name: "SwiftMath", resources: [.copy("mathFonts.bundle")]),
        .target(name: "PaperDeskStorage", dependencies: ["PaperDeskCore"]),
        .target(name: "PaperDeskBridge", dependencies: ["PaperDeskCore"]),
        .executableTarget(name: "PaperDeskApp", dependencies: ["PaperDeskCore", "PaperDeskStorage", "PaperDeskBridge", "SwiftMath"]),
        .executableTarget(name: "PaperDeskMCP", dependencies: ["PaperDeskCore", "PaperDeskBridge"]),
        .executableTarget(name: "PaperDeskCheck", dependencies: ["PaperDeskCore", "PaperDeskStorage", "PaperDeskBridge"]),
        .testTarget(name: "PaperDeskTests", dependencies: ["PaperDeskCore", "PaperDeskStorage", "PaperDeskBridge", "SwiftMath"])
    ],
    swiftLanguageModes: [.v5]
)
