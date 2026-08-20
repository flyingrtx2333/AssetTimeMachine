import Foundation

@main
enum AssetEditorRecordDraftTest {
    static func main() {
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
