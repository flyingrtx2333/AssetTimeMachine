// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AssetTimeMachineBacktest",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AssetTimeMachineBacktestCore", targets: ["AssetTimeMachineBacktestCore"]),
        .library(name: "AssetTimeMachineResearchSupport", targets: ["AssetTimeMachineResearchSupport"]),
        .executable(name: "AssetTimeMachineResearch", targets: ["AssetTimeMachineResearch"]),
        .executable(name: "AssetTimeMachineMetricDump", targets: ["AssetTimeMachineMetricDump"]),
        .executable(name: "AssetTimeMachineExecutionReassessment", targets: ["AssetTimeMachineExecutionReassessment"]),
        .executable(name: "AssetTimeMachineBacktestWorker", targets: ["AssetTimeMachineBacktestWorker"]),
        .executable(name: "AssetTimeMachineBacktestCompute", targets: ["AssetTimeMachineBacktestCompute"]),
        .executable(name: "RSRangeBreadthFreeze", targets: ["RSRangeBreadthFreeze"]),
        .executable(name: "RSRangeBreadthFormal", targets: ["RSRangeBreadthFormal"]),
        .executable(name: "IntradayDownsideBreadthFreeze", targets: ["IntradayDownsideBreadthFreeze"]),
        .executable(name: "IntradayDownsideBreadthFormal", targets: ["IntradayDownsideBreadthFormal"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.22.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(name: "AssetTimeMachineBacktestCore",
                path: "Sources/AssetTimeMachineBacktestCore",
                resources: [.copy("Resources/RecentWindow")]),
        .target(name: "AssetTimeMachineResearchSupport",
                dependencies: ["AssetTimeMachineBacktestCore", .product(name: "Crypto", package: "swift-crypto")],
                path: "Sources/AssetTimeMachineResearchSupport"),
        .executableTarget(name: "AssetTimeMachineResearch",
                          dependencies: ["AssetTimeMachineResearchSupport"],
                          path: "Server/Sources/ResearchCLI"),
        .executableTarget(name: "AssetTimeMachineMetricDump",
                          dependencies: ["AssetTimeMachineResearchSupport"],
                          path: "Server/Sources/MetricDump"),
        .executableTarget(name: "AssetTimeMachineExecutionReassessment",
                          dependencies: ["AssetTimeMachineResearchSupport"],
                          path: "Server/Sources/ExecutionReassessment"),
        .executableTarget(
            name: "AssetTimeMachineBacktestWorker",
            dependencies: [
                "AssetTimeMachineBacktestCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Server/Sources/Worker"
        ),
        .executableTarget(
            name: "AssetTimeMachineBacktestCompute",
            dependencies: ["AssetTimeMachineBacktestCore"],
            path: "Server/Sources/Compute"
        ),
        .executableTarget(
            name: "RSRangeBreadthFreeze",
            dependencies: ["AssetTimeMachineResearchSupport"],
            path: "Server/Sources/RSRangeBreadthFreeze"
        ),
        .executableTarget(
            name: "RSRangeBreadthFormal",
            dependencies: ["AssetTimeMachineResearchSupport"],
            path: "Server/Sources/RSRangeBreadthFormal"
        ),
        .executableTarget(
            name: "IntradayDownsideBreadthFreeze",
            dependencies: ["AssetTimeMachineResearchSupport"],
            path: "Server/Sources/IntradayDownsideBreadthFreeze"
        ),
        .executableTarget(
            name: "IntradayDownsideBreadthFormal",
            dependencies: ["AssetTimeMachineResearchSupport"],
            path: "Server/Sources/IntradayDownsideBreadthFormal"
        ),
        .testTarget(
            name: "AssetTimeMachineBacktestWorkerTests",
            dependencies: ["AssetTimeMachineBacktestWorker"],
            path: "Server/Tests/WorkerTests"
        ),
        .testTarget(
            name: "AssetTimeMachineBacktestCoreTests",
            dependencies: ["AssetTimeMachineBacktestCore", "AssetTimeMachineResearchSupport"],
            path: "Server/Tests/CoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
