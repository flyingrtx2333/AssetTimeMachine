import Foundation

@main
enum AssetRecordingOnboardingTest {
    static func main() {
        expect(
            AssetRecordingQuickChoice.bankCard.categoryGroupRawValue == "financial",
            "Bank cards should be recorded as financial assets"
        )
        expect(
            AssetRecordingQuickChoice.home.categoryGroupRawValue == "physical",
            "Homes should be recorded as physical assets"
        )
        expect(
            AssetRecordingQuickChoice.liability.categoryGroupRawValue == "liability",
            "Liabilities must not be recorded as assets"
        )
        expect(
            AssetRecordingQuickChoice.bankCard.preferredExistingItemName == "银行卡",
            "The seeded bank-card item should be reused instead of duplicated"
        )
        expect(
            AssetRecordingQuickChoice.home.preferredExistingItemName == "房产",
            "The seeded home item should be reused instead of duplicated"
        )
        expect(
            AssetRecordingQuickChoice.investment.preferredExistingItemName == nil,
            "A generic investment should create its own user-editable item"
        )

        expect(
            AssetRecordingOnboardingGate.shouldShowRecordItem(
                showsZeroBalanceAssets: false,
                resolvedAmount: 0,
                isHighlighted: true
            ),
            "The saved onboarding row must stay visible while its zero-value success highlight is active"
        )
        expect(
            !AssetRecordingOnboardingGate.shouldShowRecordItem(
                showsZeroBalanceAssets: false,
                resolvedAmount: 0,
                isHighlighted: false
            ),
            "Unrelated zero-value rows should still respect the user's hidden-zero preference"
        )
        expect(
            AssetRecordingOnboardingGate.shouldShowRecordItem(
                showsZeroBalanceAssets: false,
                resolvedAmount: 1,
                isHighlighted: false
            ),
            "Non-zero rows should remain visible when zero-value rows are hidden"
        )

        expect(
            AssetRecordingOnboardingGate.canReuseSeededItem(
                candidateName: "银行卡",
                preferredName: "银行卡",
                isInSelectedCategory: true,
                hasRecordedEntries: false,
                usesDirectAmount: true,
                hasMarketSymbol: false
            ),
            "A seeded bank-card item with only blank snapshot placeholders should be reused"
        )
        expect(
            !AssetRecordingOnboardingGate.canReuseSeededItem(
                candidateName: "银行卡",
                preferredName: "银行卡",
                isInSelectedCategory: true,
                hasRecordedEntries: true,
                usesDirectAmount: true,
                hasMarketSymbol: false
            ),
            "A same-name item with real history must not be treated as a seed placeholder"
        )
        expect(
            !AssetRecordingOnboardingGate.canReuseSeededItem(
                candidateName: "银行卡",
                preferredName: "银行卡",
                isInSelectedCategory: true,
                hasRecordedEntries: false,
                usesDirectAmount: false,
                hasMarketSymbol: true
            ),
            "A configured same-name item must not be overwritten by seed reuse"
        )
        expect(
            AssetRecordingOnboardingGate.isBlankRecord(
                amount: nil,
                quantity: nil,
                unitPrice: nil,
                note: ""
            ),
            "A generated placeholder entry should remain eligible for seeded-item reuse"
        )
        expect(
            !AssetRecordingOnboardingGate.isBlankRecord(
                amount: 0,
                quantity: nil,
                unitPrice: nil,
                note: ""
            ),
            "An explicitly saved zero amount is a real record, not a blank placeholder"
        )
        expect(
            !AssetRecordingOnboardingGate.isBlankRecord(
                amount: nil,
                quantity: 0,
                unitPrice: nil,
                note: ""
            ),
            "An explicitly saved zero quantity is a real record, not a blank placeholder"
        )

        var didMutate = false
        var didAttemptSave = false
        var didRollback = false
        do {
            _ = try AssetRecordingOnboardingTransaction.perform(
                mutation: {
                    didMutate = true
                    return "created-item"
                },
                save: {
                    didAttemptSave = true
                    throw TransactionTestError.saveFailed
                },
                rollback: {
                    didRollback = true
                }
            )
            expect(false, "A failed final save must be surfaced")
        } catch TransactionTestError.saveFailed {
            // Expected.
        } catch {
            expect(false, "The transaction should preserve the original save error")
        }
        expect(didMutate && didAttemptSave && didRollback, "A failed atomic write must roll back all staged mutations")

        didRollback = false
        do {
            let result = try AssetRecordingOnboardingTransaction.perform(
                mutation: { "saved-item" },
                save: {},
                rollback: { didRollback = true }
            )
            expect(result == "saved-item", "A successful atomic write should return its mutation result")
            expect(!didRollback, "A successful atomic write must not roll back")
        } catch {
            expect(false, "A successful atomic write should not throw")
        }

        let zeroAmountDraft = AssetEditorRecordDraftBuilder.make(
            usesQuantityAndUnitPrice: false,
            amountText: "0",
            quantityText: "",
            unitPrice: nil,
            forcePositiveAmount: false
        )
        expect(
            AssetRecordingOnboardingGate.canSave(
                resolvedName: "银行卡",
                hasCategory: true,
                hasSnapshot: true,
                recordDraft: zeroAmountDraft
            ),
            "A real zero-amount record should complete onboarding"
        )

        let zeroQuantityDraft = AssetEditorRecordDraftBuilder.make(
            usesQuantityAndUnitPrice: true,
            amountText: "",
            quantityText: "0",
            unitPrice: nil,
            forcePositiveAmount: false
        )
        expect(
            AssetRecordingOnboardingGate.canSave(
                resolvedName: "标普 500",
                hasCategory: true,
                hasSnapshot: true,
                recordDraft: zeroQuantityDraft
            ),
            "A real zero-quantity record should complete onboarding"
        )

        expect(
            !AssetRecordingOnboardingGate.canSave(
                resolvedName: "银行卡",
                hasCategory: true,
                hasSnapshot: true,
                recordDraft: nil
            ),
            "An empty amount must not complete onboarding"
        )
        expect(
            !AssetRecordingOnboardingGate.canSave(
                resolvedName: "   ",
                hasCategory: true,
                hasSnapshot: true,
                recordDraft: zeroAmountDraft
            ),
            "A blank asset name must not complete onboarding"
        )
        expect(
            !AssetRecordingOnboardingGate.canSave(
                resolvedName: "银行卡",
                hasCategory: false,
                hasSnapshot: true,
                recordDraft: zeroAmountDraft
            ),
            "A category is required before onboarding can complete"
        )
        expect(
            !AssetRecordingOnboardingGate.canSave(
                resolvedName: "银行卡",
                hasCategory: true,
                hasSnapshot: false,
                recordDraft: zeroAmountDraft
            ),
            "A persisted daily snapshot is required before onboarding can complete"
        )

        print("Asset recording onboarding tests: PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}

private enum TransactionTestError: Error {
    case saveFailed
}
