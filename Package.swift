// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "SophonClientv3",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SophonClientv3", type: .dynamic, targets: ["SophonClientv3"]),
    .library(name: "HYPAPIClient", targets: ["HYPAPIClient"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "SophonClientv3",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        "HYPAPIClient",
      ]),
    .target(name: "HYPAPIClient"),
    .executableTarget(
      name: "SophonCLI",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        "HYPAPIClient",
        "SophonClientv3",
      ]
    ),
    .testTarget(
      name: "HYPAPIClientTests",
      dependencies: ["HYPAPIClient"]
    ),
    //        .testTarget(
    //            name: "SophonClientv3Tests",
    //            dependencies: ["SophonClientv3"]
    //        ),
  ],
  swiftLanguageModes: [.v6]
)
