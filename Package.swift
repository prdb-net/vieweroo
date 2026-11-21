// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Vieweroo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Vieweroo", targets: ["ViewerooApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
    targets: [
        .target(name: "ViewerooCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ViewerooApp", dependencies: ["ViewerooCore"]),
        .testTarget(name: "ViewerooCoreTests", dependencies: ["ViewerooCore", "ViewerooApp"]),
    ]
)
