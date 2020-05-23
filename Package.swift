// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "b2swift",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "b2swift",
            targets: ["b2swift"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/JohnSundell/Files", from: "2.2.1"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", from: "0.10.0"),

        .package(name: "Core", url: "https://github.com/vapor/core.git", from: "3.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "b2swift",
            dependencies: [
                "Files", "CryptoSwift",
                .product(name: "Async", package: "Core")
        ]),
    ]
)
