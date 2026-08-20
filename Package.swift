// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Localfox",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LocalfoxKit", targets: ["LocalfoxKit"]),
        .executable(name: "localfox-run", targets: ["localfox-run"])
    ],
    targets: [
        .target(
            name: "LocalfoxKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "localfox-run",
            dependencies: ["LocalfoxKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalfoxKitTests",
            dependencies: ["LocalfoxKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
