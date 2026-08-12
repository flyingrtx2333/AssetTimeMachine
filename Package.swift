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
        .executable(name: "AssetTimeMachineBacktestCompute", targets: ["AssetTimeMachineBacktestCompute"])
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
                "BacktestCharts.swift",
                "BacktestHistoryViews.swift",
                "BacktestSheets.swift",
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
        .testTarget(
            name: "AssetTimeMachineBacktestCoreTests",
            dependencies: ["AssetTimeMachineBacktestCore"],
            path: "Server/Tests/CoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
