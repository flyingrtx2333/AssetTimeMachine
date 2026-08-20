import Foundation

nonisolated enum AssetRecordingQuickChoice: String, CaseIterable, Identifiable, Sendable {
    case bankCard
    case home
    case investment
    case liability
    case other

    var id: String { rawValue }

    var titleLocalizationKey: String {
        switch self {
        case .bankCard: "银行卡"
        case .home: "房产"
        case .investment: "投资"
        case .liability: "负债"
        case .other: "其他"
        }
    }

    var defaultNameLocalizationKey: String {
        switch self {
        case .bankCard: "银行卡"
        case .home: "房产"
        case .investment: "投资"
        case .liability: "负债"
        case .other: "其他资产"
        }
    }

    var categoryGroupRawValue: String {
        switch self {
        case .home:
            "physical"
        case .liability:
            "liability"
        case .bankCard, .investment, .other:
            "financial"
        }
    }

    var preferredExistingItemName: String? {
        switch self {
        case .bankCard: "银行卡"
        case .home: "房产"
        case .investment, .liability, .other: nil
        }
    }

    var systemImageName: String {
        switch self {
        case .bankCard: "creditcard"
        case .home: "house"
        case .investment: "chart.line.uptrend.xyaxis"
        case .liability: "building.columns"
        case .other: "ellipsis"
        }
    }
}

nonisolated enum AssetRecordingOnboardingGate {
    static func shouldShowRecordItem(
        showsZeroBalanceAssets: Bool,
        resolvedAmount: Double,
        isHighlighted: Bool
    ) -> Bool {
        showsZeroBalanceAssets || isHighlighted || abs(resolvedAmount) > 0.000_001
    }

    static func canReuseSeededItem(
        candidateName: String,
        preferredName: String?,
        isInSelectedCategory: Bool,
        hasRecordedEntries: Bool,
        usesDirectAmount: Bool,
        hasMarketSymbol: Bool
    ) -> Bool {
        guard let preferredName else { return false }
        return candidateName == preferredName
            && isInSelectedCategory
            && !hasRecordedEntries
            && usesDirectAmount
            && !hasMarketSymbol
    }

    static func isBlankRecord(
        amount: Double?,
        quantity: Double?,
        unitPrice: Double?,
        note: String
    ) -> Bool {
        amount == nil
            && quantity == nil
            && unitPrice == nil
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func canSave(
        resolvedName: String,
        hasCategory: Bool,
        hasSnapshot: Bool,
        recordDraft: AssetEditorRecordDraft?
    ) -> Bool {
        !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCategory
            && hasSnapshot
            && recordDraft != nil
    }
}

nonisolated enum AssetRecordingOnboardingTransaction {
    static func perform<Result>(
        mutation: () throws -> Result,
        save: () throws -> Void,
        rollback: () -> Void
    ) throws -> Result {
        do {
            let result = try mutation()
            try save()
            return result
        } catch {
            rollback()
            throw error
        }
    }
}
