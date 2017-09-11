# b2swift


<img src="https://img.shields.io/badge/swift-4-red.svg" />

To use this project in your repository, add the following line to your dependencies:

`.package(url: "https://github.com/ezfe/b2swift", .branch("master"))`

Also remember to add `b2Swift` to the target dependencies.

Example Package.swift file:

```swift
import PackageDescription

let package = Package(
    name: "ProjectName",
    products: [
        .library(
            name: "ProjectName",
            targets: ["ProjectName"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ezfe/b2swift", .branch("master"))
    ],
    targets: [
        .target(
            name: "ProjectName",
            dependencies: ["b2swift"]),
        .testTarget(
            name: "ProjectNameTests",
            dependencies: ["ProjectName"]),
    ]
)
```
