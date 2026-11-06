// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MLKEMNative",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        .library(
            name: "MLKEMNative",
            targets: ["MLKEMNative"]
        ),
    ],
    targets: [
        // Vendored mlkem-native, built as one compilation unit (aw_mlkem.c);
        // vendor/ itself is excluded so its files are only reached via #include.
        .target(
            name: "CMLKEMNative",
            exclude: ["vendor"],
            sources: ["aw_mlkem.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "MLKEMNative",
            dependencies: ["CMLKEMNative"]
        ),
        .testTarget(
            name: "MLKEMNativeTests",
            dependencies: ["MLKEMNative"]
        ),
    ]
)
