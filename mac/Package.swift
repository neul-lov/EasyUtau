// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EasyUtau",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "EasyUtau", path: "Sources/EasyUtau"),
        // 음 높이 계산 시험 (swift test)
        .testTarget(name: "EasyUtauTests", dependencies: ["EasyUtau"], path: "Tests/EasyUtauTests"),
    ]
)
