import Foundation

/// Application-scoped strategy advice computation. The Quant home, Dashboard sheet and
/// notification scheduler share this actor so identical market inputs are evaluated once.
actor StrategyAdviceService {
    private let maximumCachedResults = 8
    private var cachedAdviceByToken: [String: StrategyRebalanceAdvice] = [:]
    private var cacheOrder: [String] = []
    private var inFlightTasks: [String: Task<StrategyRebalanceAdvice?, Never>] = [:]

    func advice(
        calculationToken: String,
        mode: AdvancedBacktestStrategyMode,
        assetOptions: [BacktestAssetOption],
        historyBySymbol: [String: PublicHistorySeries],
        force: Bool
    ) async -> StrategyRebalanceAdvice? {
        if !force, let cachedAdvice = cachedAdviceByToken[calculationToken] {
            noteCacheUse(calculationToken)
            return cachedAdvice
        }

        if let inFlightTask = inFlightTasks[calculationToken] {
            return await inFlightTask.value
        }

        let task = Task.detached(priority: .utility) {
            do {
                return try await BackgroundTaskWork.runSynchronousOnLargeStack {
                    let assetInputs = assetOptions.map { option in
                        BacktestEngine.advancedAssetInput(for: option) { symbol in
                            historyBySymbol[symbol]
                        }
                    }
                    return BacktestEngine.advancedRotationRebalanceAdvice(
                        assetInputs: assetInputs,
                        mode: mode
                    )
                }
            } catch {
                return nil
            }
        }
        inFlightTasks[calculationToken] = task

        let result = await task.value
        inFlightTasks[calculationToken] = nil
        if let result {
            cachedAdviceByToken[calculationToken] = result
            noteCacheUse(calculationToken)
            trimCacheIfNeeded()
        }
        return result
    }

    func clearCache() {
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
