import AppKit
import AssetTimeMachineBacktestCore
import Foundation
import SwiftData
import SwiftUI

/// Explicit in-memory migration check, using the pinned public history fixture.
@MainActor
enum NativeQuantProbe {
    private struct Input: Decodable {
        let pinned: PublicHistoryResponse
        let live: PublicHistoryResponse?
    }
    static func run(store: NativeQuantStore, context: ModelContext, fixture: URL) async -> [String: Any] {
        precondition(AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macWorkspaceInMemory"))
        var checks: [String: Bool] = [:]
        var metrics: [[String: Any]] = []
        do {
            // A fixture-only stdin transport lets a sandboxed app consume explicitly supplied
            // public data without widening filesystem or account permissions.
            let arguments = ProcessInfo.processInfo.arguments
            let input = arguments.contains("-macQuantProbeStdin")
                ? try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile()) : nil
            let response = try input?.pinned ?? JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: fixture))
            let history = Dictionary(uniqueKeysWithValues: response.series.map { (BacktestAssetSymbol.normalized($0.symbol), $0) })
            store.market.historySeries = history
            var config = NativeQuantConfiguration()
            config.kind = .allocation
            store.config = config
            try await execute(store, context: context)
            guard let allocation = store.result else { throw NativeQuantError.invalid("配置回测未生成记录") }
            let gold = history["gold_cny"]!, nasdaq = history["nasdaq"]!
            let goldRows = Dictionary(uniqueKeysWithValues: zip(gold.dates, gold.prices))
            let nasdaqRows = Dictionary(uniqueKeysWithValues: zip(nasdaq.dates, nasdaq.prices))
            let common = Set(goldRows.keys).intersection(nasdaqRows.keys).sorted()
            let first = common.first!, last = common.last!
            let expectedValue = 0.5 + 0.25 * goldRows[last]! / goldRows[first]! + 0.25 * nasdaqRows[last]! / nasdaqRows[first]!
            checks["allocation_independent_buy_and_hold"] = abs((allocation.finalValue ?? 0) - expectedValue) < 1e-9
            metrics.append(["kind": "allocation", "return": allocation.totalReturn, "finalValue": allocation.finalValue ?? 0])

            config.kind = .dca; config.dcaSymbol = "gold_cny"
            store.config = config
            try await execute(store, context: context)
            guard let dca = store.result else { throw NativeQuantError.invalid("定投回测未生成记录") }
            var nextDate = Date.distantPast, units = 0.0, contributions = 0
            let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"; parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
            for (day, price) in zip(gold.dates, gold.prices) {
                guard let date = parser.date(from: day), date >= nextDate else { continue }
                units += config.contribution / price; contributions += 1
                nextDate = Calendar.current.date(byAdding: .day, value: config.intervalDays, to: date)!
            }
            checks["dca_independent_units_and_contributions"] = dca.tradeCount == contributions
                && abs((dca.finalValue ?? 0) - units * gold.prices.last!) < 1e-6
            metrics.append(["kind": "dca", "return": dca.totalReturn, "contributions": dca.tradeCount])

            config.kind = .advanced; config.applyTemplate("gold-nasdaq-dual-trend-barbell")
            config.startDate = parser.date(from: "2020-01-01"); config.endDate = parser.date(from: "2026-06-30")
            store.config = config
            try await execute(store, context: context)
            guard let advanced = store.result else { throw NativeQuantError.invalid("策略回测未生成记录") }
            let saved = BacktestRecordCodec.decodeConfig(from: advanced)
            checks["strategy_selected_window_and_trade_payload"] = advanced.startDate! >= config.startDate!
                && advanced.endDate! <= config.endDate! && !(saved?.advancedTrades?.isEmpty ?? true)
                && saved?.runtimeProvenance?.strategy?.id == config.templateID
            metrics.append(["kind": "advanced", "return": advanced.totalReturn, "drawdown": advanced.maxDrawdown, "trades": advanced.tradeCount])

            // A fresh context reads the same legacy schema, not the view's retained result.
            let reloaded = try ModelContext(context.container).fetch(FetchDescriptor<BacktestRecord>())
            checks["record_save_reload_restore_three_modes"] = reloaded.count == 3 && reloaded.allSatisfy { record in
                var restored = NativeQuantConfiguration()
                do {
                    try restored.restore(record)
                    return restored.kind.rawValue == record.kindRawValue && !BacktestRecordCodec.decodePoints(from: record).isEmpty
                } catch { return false }
            }
            var legacyConfig = try JSONSerialization.jsonObject(with: advanced.configJSON) as! [String: Any]
            legacyConfig.removeValue(forKey: "runtimeProvenance")
            let legacy = BacktestRecord(kindRawValue: "advanced", title: advanced.title, subtitle: advanced.subtitle,
                configSummary: advanced.configSummary, totalReturn: advanced.totalReturn, maxDrawdown: advanced.maxDrawdown,
                pointsJSON: advanced.pointsJSON, configJSON: try JSONSerialization.data(withJSONObject: legacyConfig))
            var legacyRestored = NativeQuantConfiguration(); try legacyRestored.restore(legacy)
            checks["legacy_record_without_provenance_restores"] = legacyRestored.mode == config.mode
                && legacyRestored.fee == config.fee && legacyRestored.selectedSymbols == config.selectedSymbols
            let template = StrategyRebalanceDefaults.template(for: "gold-nasdaq-dual-trend-barbell")!
            var snapshots = FetchDescriptor<AssetSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)]); snapshots.fetchLimit = 1
            let snapshot = try context.fetch(snapshots).first
            await store.advice.refresh(templateID: template.id, marketStore: store.market, snapshot: snapshot, force: false)
            checks["stale_history_does_not_emit_today_advice"] = store.advice.advice == nil && store.advice.statusMessage != nil
            let options = StrategyRebalanceDefaults.assetOptions(for: template)
            let service = StrategyAdviceService()
            let advice = await service.advice(calculationToken: "native-migration-pinned", template: template,
                assetOptions: options, historyBySymbol: history, nfciAsOf: nil, force: true)
            let actions = advice.map { StrategyRebalanceActionBuilder.actions(for: $0, snapshot: snapshot,
                selectedAssetOptions: options, allAssetOptions: BacktestDefaults.dcaAssetOptions) } ?? []
            checks["advice_real_engine_and_existing_holding_mapping"] = advice != nil && !actions.isEmpty
                && actions.allSatisfy { $0.targetWeight.isFinite && $0.targetWeight >= 0 }
                && (advice?.allocations.reduce(0) { $0 + $1.targetWeight } ?? 2) <= 1.000001

            if input?.live != nil || arguments.contains("-macQuantLiveHistory") {
                let live: PublicHistoryResponse
                if let supplied = input?.live { live = supplied }
                else if let i = arguments.firstIndex(of: "-macQuantLiveHistory"), arguments.indices.contains(i + 1) {
                    live = try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])))
                } else { throw NativeQuantError.invalid("缺少样例行情") }
                store.market.historySeries = Dictionary(uniqueKeysWithValues: live.series.map { (BacktestAssetSymbol.normalized($0.symbol), $0) })
                await store.advice.refresh(templateID: template.id, marketStore: store.market, snapshot: snapshot, force: false)
                checks["latest_public_history_to_native_advice"] = store.advice.advice != nil && !store.advice.actions.isEmpty
            }
            let before = store.records.count
            store.run(in: context); store.cancel()
            try await Task.sleep(for: .milliseconds(100))
            checks["cancel_does_not_save_late_result"] = store.records.count == before && !store.isWorking
            var invalid = config; invalid.startDate = config.endDate; invalid.endDate = config.startDate
            do { try invalid.validate(); checks["invalid_range_rejected"] = false }
            catch { checks["invalid_range_rejected"] = true }
            let poster = NativeQuantExport.posterData(record: advanced)
            checks["native_poster_image_renders"] = poster != nil
            if let poster, let data = try? JSONSerialization.data(withJSONObject: ["page": "quant-poster", "png": poster.base64EncodedString()]) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            }
            store.result = advanced; store.route = "overview"
            return ["quantMigrationChecks": checks, "metrics": metrics, "passed": checks.values.allSatisfy { $0 }]
        } catch {
            return ["quantMigrationChecks": checks, "metrics": metrics, "passed": false, "error": error.localizedDescription]
        }
    }

    private static func execute(_ store: NativeQuantStore, context: ModelContext) async throws {
        let before = store.records.count
        store.run(in: context)
        let deadline = Date().addingTimeInterval(180)
        while store.isWorking && Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        if store.isWorking { store.cancel(); throw NativeQuantError.invalid("回测超时") }
        guard store.records.count == before + 1, store.error == nil else { throw NativeQuantError.invalid(store.error ?? "回测没有保存记录") }
    }

    static func capture(window: NSWindow, store: NativeQuantStore) async {
        precondition(AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macWorkspaceInMemory"))
        if ProcessInfo.processInfo.arguments.contains("-macHomeSmallWindow") {
            window.setContentSize(NSSize(width: 900, height: 620))
        }
        for route in ["overview", "configure", "result", "records"] {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { store.route = route }
            try? await Task.sleep(for: .milliseconds(1200))
            emit(window: window, page: "quant-\(route)")
        }
        store.route = "overview"
        if ProcessInfo.processInfo.arguments.contains("-macQuantAppearanceTour") {
            let appearance = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(700))
            emit(window: window, page: "quant-dark")
            window.setContentSize(NSSize(width: 900, height: 620))
            try? await Task.sleep(for: .milliseconds(700))
            emit(window: window, page: "quant-compact")
            NSApp.appearance = appearance
            window.setContentSize(NSSize(width: 1040, height: 688))
        }
    }
    private static func emit(window: NSWindow, page: String) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]),
           let data = try? JSONSerialization.data(withJSONObject: ["page": page, "png": png.base64EncodedString()]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
}
