// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnywhereRules",
    products: [
        .library(name: "AnywhereRules", targets: ["AnywhereRules"])
    ],
    targets: [
        .target(
            name: "AnywhereRules",
            resources: [.copy("Resources/Rules.db")]
        )
    ]
)
