import Foundation

@main
enum AssetEditorRecordDraftTest {
    static func main() {
        for value in [1_234_567.89123, 0.0000123456789, 1.234567891234567] {
            precondition(AssetEditorRecordDraftBuilder.make(usesQuantityAndUnitPrice: false,
                amountText: value.recordInputString(), quantityText: "", unitPrice: nil,
                forcePositiveAmount: false) == .directAmount(value))
            precondition(AssetEditorRecordDraftBuilder.make(usesQuantityAndUnitPrice: true,
                amountText: "", quantityText: value.recordInputString(), unitPrice: value,
                forcePositiveAmount: false) == .quantityAndUnitPrice(quantity: value, unitPrice: value))
        }
        precondition(
            AssetEditorRecordDraftBuilder.make(
                usesQuantityAndUnitPrice: false,
                amountText: "12,345.67",
                quantityText: "",
                unitPrice: nil,
                forcePositiveAmount: false
            ) == .directAmount(12_345.67)
        )

        precondition(
            AssetEditorRecordDraftBuilder.make(
                usesQuantityAndUnitPrice: false,
                amountText: "-800",
                quantityText: "",
                unitPrice: nil,
                forcePositiveAmount: true
            ) == .directAmount(800)
        )

        precondition(
            AssetEditorRecordDraftBuilder.make(
                usesQuantityAndUnitPrice: true,
                amountText: "",
                quantityText: "25.5",
                unitPrice: 103.2,
                forcePositiveAmount: false
            ) == .quantityAndUnitPrice(quantity: 25.5, unitPrice: 103.2)
        )

        precondition(
            AssetEditorRecordDraftBuilder.make(
                usesQuantityAndUnitPrice: false,
                amountText: "",
                quantityText: "",
                unitPrice: nil,
                forcePositiveAmount: false
            ) == nil
        )

        print("Asset editor record draft tests: PASS")
    }
}
