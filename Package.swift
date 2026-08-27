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
        .executable(
            name: "HangyeolE2E",
            targets: ["HangyeolE2E"]),
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
        .target(
            name: "HangyeolE2ESupport",
            dependencies: ["HangyeolCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "HangyeolE2E",
            dependencies: ["HangyeolE2ESupport"]
        ),
        .testTarget(
            name: "HangyeolCoreTests",
            dependencies: ["HangyeolCore", "HangyeolE2ESupport"]
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
