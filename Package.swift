// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XiangqiAssistant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XiangqiAssistant",
            path: "Sources/XiangqiAssistant",
            exclude: [
                // Recommendation-only build: no executable mouse-control code
                // is compiled through either XcodeGen or Swift Package Manager.
                "UI/AutoPlayManager.swift"
            ],
            resources: [
                .copy("Resources/Engine"),
                .copy("Resources/OpeningBook")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
