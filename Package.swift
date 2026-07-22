// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XiangqiAssistant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XiangqiAssistant",
            path: "Sources/XiangqiAssistant",
            resources: [
                .copy("Resources/Engine")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
