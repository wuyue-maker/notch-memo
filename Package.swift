// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchMemo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NotchMemo", targets: ["NotchMemo"])],
    targets: [
        .target(name: "MemoCore"),
        .executableTarget(name: "NotchMemo", dependencies: ["MemoCore"]),
        .testTarget(name: "MemoCoreTests", dependencies: ["MemoCore"]),
        .testTarget(name: "MemoAppTests", dependencies: ["NotchMemo", "MemoCore"])
    ],
    swiftLanguageModes: [.v5]
)
