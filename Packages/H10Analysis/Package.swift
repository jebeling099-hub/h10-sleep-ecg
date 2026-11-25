// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "H10Analysis",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "H10Analysis",
            targets: ["H10Analysis"]
        )
    ],
    targets: [
        .target(
            name: "H10Analysis"
        ),
        .testTarget(
            name: "H10AnalysisTests",
            dependencies: ["H10Analysis"]
        )
    ]
)
