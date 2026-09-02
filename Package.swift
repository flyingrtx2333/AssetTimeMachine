// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AssetTimeMachineBacktest",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AssetTimeMachineBacktestCore", targets: ["AssetTimeMachineBacktestCore"]),
        .executable(name: "AssetTimeMachineBacktestWorker", targets: ["AssetTimeMachineBacktestWorker"]),
        .executable(name: "AssetTimeMachineBacktestCompute", targets: ["AssetTimeMachineBacktestCompute"]),
        .executable(name: "RSRangeBreadthFreeze", targets: ["RSRangeBreadthFreeze"]),
        .executable(name: "RSRangeBreadthFormal", targets: ["RSRangeBreadthFormal"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.22.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "AssetTimeMachineBacktestCore",
            path: "AssetTimeMachine/Backtest",
            exclude: [
                "AdvancedBacktestDataSupport.swift",
                "AdvancedBacktestResultContent.swift",
                "AdvancedBacktestView.swift",
                "AssetAgnosticBacktestEngine.swift",
                "BacktestCharts.swift",
                "BacktestHistoryViews.swift",
                "BacktestSheets.swift",
                "BacktestSharePoster.swift",
                "BacktestView.swift",
                "StrategyAdviceProjectionStore.swift",
                "StrategyAdviceService.swift",
                "TodayPositionAdviceCard.swift"
            ],
            sources: [
                "PublicHistoryModels.swift",
                "BacktestModels.swift",
                "BacktestMetricsCalculator.swift",
                "BacktestSeriesAlignment.swift",
                "BacktestFXConverter.swift",
                "BacktestAdvancedSeriesPreparer.swift",
                "BacktestEngine.swift",
                "GNR5ReversalStrategy.swift",
                "GORQREG25263Strategy.swift",
                "MacroSahmCPIStrategy.swift",
                "RSRangeBreadthStrategy.swift",
                "RSRangeBreadthFreezeSupport.swift",
                "RSRangeBreadthFormalSupport.swift",
                "AssetTimeMachineServerSupport.swift",
                "PublicBacktestCore.swift"
            ],
            swiftSettings: [
                .define("ATM_SERVER")
            ]
        ),
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
            dependencies: ["AssetTimeMachineBacktestCore"],
            path: "Server/Sources/RSRangeBreadthFreeze"
        ),
        .executableTarget(
            name: "RSRangeBreadthFormal",
            dependencies: ["AssetTimeMachineBacktestCore"],
            path: "Server/Sources/RSRangeBreadthFormal"
        ),
        .testTarget(
            name: "AssetTimeMachineBacktestCoreTests",
            dependencies: ["AssetTimeMachineBacktestCore"],
            path: "Server/Tests/CoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
