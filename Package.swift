// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DLQMonitor",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The only dependency. The first `swift package resolve` downloads about 1 GB and takes minutes.
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.8.10"),
    ],
    targets: [
        // Everything that talks to AWS or shapes data. No AppKit/SwiftUI, so it is unit-testable.
        .target(name: "DLQMonitorCore", dependencies: [
            .product(name: "AWSSQS", package: "aws-sdk-swift"),
            .product(name: "AWSCloudWatch", package: "aws-sdk-swift"),
            .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
        ]),
        // The menu bar app itself, plus the `--once` CLI mode.
        .executableTarget(name: "DLQMonitor", dependencies: ["DLQMonitorCore"]),
        .testTarget(name: "DLQMonitorCoreTests", dependencies: [
            "DLQMonitorCore",
            .product(name: "AWSSQS", package: "aws-sdk-swift"),
            .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
        ]),
    ]
)
