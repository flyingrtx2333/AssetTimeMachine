import Foundation

extension Double {
    /// Editable values must round-trip; display formatting may round for readability.
    nonisolated func recordInputString() -> String {
        let text = String(self)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

nonisolated enum AssetEditorRecordDraft: Equatable, Sendable {
    case directAmount(Double)
    case quantityAndUnitPrice(quantity: Double, unitPrice: Double?)
}

nonisolated enum AssetEditorRecordDraftBuilder {
    static func make(
        usesQuantityAndUnitPrice: Bool,
        amountText: String,
        quantityText: String,
        unitPrice: Double?,
        forcePositiveAmount: Bool
    ) -> AssetEditorRecordDraft? {
        if usesQuantityAndUnitPrice {
            guard let quantity = normalizedNumber(from: quantityText) else { return nil }
            return .quantityAndUnitPrice(quantity: quantity, unitPrice: unitPrice)
        }

        guard let amount = normalizedNumber(from: amountText) else { return nil }
        return .directAmount(forcePositiveAmount ? abs(amount) : amount)
    }

    private static func normalizedNumber(from text: String) -> Double? {
        let raw = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let value = Double(raw),
              value.isFinite else { return nil }
        return value
    }
}
