// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RagBio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RagBio", targets: ["RagBio"])
    ],
    targets: [
        .executableTarget(
            name: "RagBio",
            path: "Sources/RagBio"
        )
    ],
    swiftLanguageModes: [.v5]
)
