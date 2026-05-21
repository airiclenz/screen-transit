// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "screen-transit",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "screen-transit",
            path: "Sources/screen-transit",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
