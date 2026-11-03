// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PersonalAISchool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AISchool", targets: ["AISchool"])
    ],
    targets: [
        // Foundation-only logic: models, store, tools, marking, spaced repetition, planner.
        .target(name: "StudyCore"),
        // SwiftUI app: classroom UI, Claude client, notifications, menu bar.
        .executableTarget(name: "AISchool", dependencies: ["StudyCore"]),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"])
    ]
)
