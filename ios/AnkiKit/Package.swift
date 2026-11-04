// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AnkiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnkiKit", targets: ["AnkiKit"]),
    ],
    dependencies: [
        // Keep in sync with SWIFT_PROTOBUF_VERSION in scripts/gen-swift.sh, which
        // builds protoc-gen-swift from the same tag.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        // Built by scripts/build-rust.sh (iOS device, iOS simulator, macOS slices).
        .binaryTarget(name: "AnkiBridgeFFI", path: "Frameworks/AnkiBridgeFFI.xcframework"),
        .target(
            name: "AnkiKit",
            dependencies: [
                "AnkiBridgeFFI",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "AnkiKitTests", dependencies: ["AnkiKit"]),
    ]
)
