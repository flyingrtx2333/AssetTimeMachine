import AssetTimeMachineBacktestCore
import Foundation
import CryptoKit

/// Application-scoped strategy advice computation. The Quant home, Dashboard sheet and
/// notification scheduler share this actor so identical market inputs are evaluated once.
actor StrategyAdviceService {
    private let maximumCachedResults = 8
    private var cachedAdviceByToken: [String: StrategyRebalanceAdvice] = [:]
    private var cacheOrder: [String] = []
    private var cacheGeneration = 0
    private var inFlightTasks: [String: Task<StrategyRebalanceAdvice?, Never>] = [:]

    func advice(
        calculationToken: String,
        template: AdvancedBacktestStrategyTemplate,
        assetOptions: [BacktestAssetOption],
        historyBySymbol: [String: PublicHistorySeries],
        nfciAsOf: BacktestNFCIAsOfData?,
        force: Bool
    ) async -> StrategyRebalanceAdvice? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let definition = try? StrategyRegistry.definition(id: template.id),
              let parameters = try? definition.frozenParametersJSON,
              let history = try? encoder.encode(historyBySymbol),
              let macro = try? encoder.encode(nfciAsOf) else { return nil }
        var fingerprint = SHA256()
        for value in [Data(calculationToken.utf8), Data(BacktestEngine.defaultEngineVersion.utf8),
                      Data(definition.reference.version.utf8), parameters, history, macro] {
            fingerprint.update(data: value)
        }
        let calculationToken = fingerprint.finalize().map { String(format: "%02x", $0) }.joined()
        if !force, let cachedAdvice = cachedAdviceByToken[calculationToken] {
            noteCacheUse(calculationToken)
            return cachedAdvice
        }

        if let inFlightTask = inFlightTasks[calculationToken] {
            return await inFlightTask.value
        }

        let generation = cacheGeneration
        let task = Task.detached(priority: .utility) {
            do {
                return try await BackgroundTaskWork.runSynchronousOnLargeStack {
                    let assetInputs = assetOptions.map { option in
                        BacktestEngine.advancedAssetInput(for: option) { symbol in
                            historyBySymbol[symbol]
                        }
                    }
                    if template.mode.isRotation {
                        let settings = AdvancedBacktestRiskSettings(
                            feeRate: BacktestDefaults.advancedFeeRatePercent,
                            slippageRate: BacktestDefaults.advancedSlippageRatePercent,
                            maxPositionRatio: min(template.maxPositionRatio, 100),
                            cooldownDays: template.cooldownDays,
                            stopLossRatio: template.stopLossRatio,
                            takeProfitRatio: template.takeProfitRatio
                        )
                        return BacktestEngine.advancedRotationRebalanceAdvice(
                            assetInputs: assetInputs,
                            mode: template.mode,
                            settings: settings,
                            nfciAsOf: nfciAsOf
                        )
                    }
                    return BacktestEngine.advancedRuleBasedRebalanceAdvice(
                        assetInputs: assetInputs,
                        template: template
                    )
                }
            } catch {
                return nil
            }
        }
        inFlightTasks[calculationToken] = task

        let result = await task.value
        guard generation == cacheGeneration, !task.isCancelled else { return nil }
        inFlightTasks[calculationToken] = nil
        if let result {
            cachedAdviceByToken[calculationToken] = result
            noteCacheUse(calculationToken)
            trimCacheIfNeeded()
        }
        return result
    }

    func clearCache() {
        cacheGeneration += 1
        for task in inFlightTasks.values { task.cancel() }
        inFlightTasks.removeAll()
        cachedAdviceByToken.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    private func noteCacheUse(_ token: String) {
        cacheOrder.removeAll { $0 == token }
        cacheOrder.append(token)
    }

    private func trimCacheIfNeeded() {
        while cacheOrder.count > maximumCachedResults {
            let expiredToken = cacheOrder.removeFirst()
            cachedAdviceByToken[expiredToken] = nil
        }
    }
}
