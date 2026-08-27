// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FileDrawer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FileDrawer",
            path: "Sources/FileDrawer"
        ),
        .testTarget(
            name: "FileDrawerTests",
            dependencies: ["FileDrawer"],
            path: "Tests/FileDrawerTests"
        )
    ]
)
