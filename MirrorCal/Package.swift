// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MirrorCal",
    platforms: [
        .macOS(.v14)  // Minimum macOS 14 for requestFullAccessToEvents()
    ],
    products: [
        .executable(name: "MirrorCal", targets: ["MirrorCal"])
    ],
    targets: [
        .executableTarget(
            name: "MirrorCal",
            path: "MirrorCal",
            resources: [
                .process("Info.plist")
            ]
        )
    ]
)
