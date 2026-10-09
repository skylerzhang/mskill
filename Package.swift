// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSkill",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MSkill", targets: ["MSkill"])],
    targets: [
        .executableTarget(
            name: "MSkill",
            path: "Sources/MSkill",
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(name: "MSkillTests", dependencies: ["MSkill"], path: "Tests/MSkillTests")
    ]
)
