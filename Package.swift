// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hangyeol",
    defaultLocalization: "ko",
    platforms: [
        .macOS(.v14)  // Sonoma or later
    ],
    products: [
        .executable(
            name: "Hangyeol",
            targets: ["Hangyeol"]),
        .library(
            name: "HangyeolCore",
            targets: ["HangyeolCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Meapri/libhangul-swift", branch: "main"),
    ],
    targets: [
        .target(
            name: "HangyeolCore",
            dependencies: [
                .product(name: "LibHangul", package: "libhangul-swift")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .executableTarget(
            name: "Hangyeol",
            dependencies: [
                "HangyeolCore",
                .product(name: "LibHangul", package: "libhangul-swift")
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .executableTarget(
            name: "HangyeolVerify",
            dependencies: ["HangyeolCore"]
        ),
        .testTarget(
            name: "HangyeolCoreTests",
            dependencies: ["HangyeolCore"]
        ),
        .executableTarget(
            name: "HangyeolBenchmark",
            dependencies: ["HangyeolCore"],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        )
    ]
)
