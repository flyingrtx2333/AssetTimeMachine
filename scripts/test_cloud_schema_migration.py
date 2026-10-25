"""Migrate a disposable real SwiftData store from the last shipped sync schema."""
from pathlib import Path
import subprocess
import tempfile


def test_cloud_schema_migration():
    root = Path(__file__).resolve().parents[1]
    old = subprocess.check_output(
        ["git", "show", "6e7eadc:AssetTimeMachine/Models.swift"], cwd=root, text=True
    )
    current = (root / "AssetTimeMachine/Models.swift").read_text()
    stubs = """import Foundation
    enum AppLocalization { static func string(_ value: String) -> String { value } }
    enum BacktestAssetSymbol { static func normalized(_ value: String) -> String { value.lowercased() } }
    """
    probe = r"""import Foundation
    import SwiftData

    @main struct SchemaMigrationProof {
        static func id(_ number: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        }
        static let firstDay = Date(timeIntervalSince1970: 1_700_000_000)
        static let secondDay = firstDay.addingTimeInterval(86_400)

        @MainActor static func seed(_ context: ModelContext) throws {
            let category = AssetCategory(id: id(1), name: "Synthetic", group: .financial, createdAt: firstDay)
            let item = AssetItem(id: id(2), name: "Synthetic cash", note: "retained item",
                createdAt: firstDay, updatedAt: firstDay, category: category)
            let first = AssetSnapshot(id: id(3), date: firstDay, note: "source day",
                createdAt: firstDay, updatedAt: firstDay)
            let second = AssetSnapshot(id: id(4), date: secondDay, note: "current day",
                createdAt: secondDay, updatedAt: secondDay)
            let a = AssetEntry(id: id(5), amount: 100.25, note: "source balance",
                createdAt: firstDay, updatedAt: firstDay, snapshot: first, item: item)
            let b = AssetEntry(id: id(6), amount: 200.75, note: "current balance",
                createdAt: secondDay, updatedAt: secondDay, snapshot: second, item: item)
            let deletion = SyncDeletionTombstone(id: id(7), entityID: id(8), entityKind: .entry,
                deletedAt: secondDay)
            let backtest = BacktestRecord(id: id(9), kindRawValue: "synthetic", title: "Synthetic replay",
                subtitle: "", configSummary: "", createdAt: firstDay, totalReturn: 0.1,
                maxDrawdown: 0.02, pointsJSON: Data([1, 2, 3]), configJSON: Data([4, 5]))
            context.insert(category); context.insert(item); context.insert(first); context.insert(second)
            context.insert(a); context.insert(b); context.insert(deletion); context.insert(backtest)
            try context.save()
        }

        @MainActor static func verify(_ context: ModelContext) throws {
            let categories = try context.fetch(FetchDescriptor<AssetCategory>())
            let items = try context.fetch(FetchDescriptor<AssetItem>())
            let days = try context.fetch(FetchDescriptor<AssetSnapshot>())
            let rows = try context.fetch(FetchDescriptor<AssetEntry>())
            let deletions = try context.fetch(FetchDescriptor<SyncDeletionTombstone>())
            let backtests = try context.fetch(FetchDescriptor<BacktestRecord>())
            precondition(categories.count == 1 && categories[0].id == id(1))
            precondition(items.count == 1 && items[0].id == id(2) && items[0].note == "retained item")
            precondition(items[0].category?.id == id(1) && items[0].entries.count == 2)
            precondition(days.count == 2 && Set(days.map(\.id)) == Set([id(3), id(4)]))
            precondition(days.first { $0.id == id(3) }?.date == firstDay)
            precondition(days.first { $0.id == id(4) }?.date == secondDay)
            precondition(rows.count == 2 && Set(rows.map(\.id)) == Set([id(5), id(6)]))
            let a = rows.first { $0.id == id(5) }!, b = rows.first { $0.id == id(6) }!
            precondition(a.amount == 100.25 && b.amount == 200.75)
            precondition(a.note == "source balance" && b.note == "current balance")
            precondition(a.createdAt == firstDay && a.updatedAt == firstDay)
            precondition(b.createdAt == secondDay && b.updatedAt == secondDay)
            precondition(a.snapshot?.id == id(3) && b.snapshot?.id == id(4))
            precondition(a.item?.id == id(2) && b.item?.id == id(2))
            precondition(deletions.count == 1 && deletions[0].id == id(7)
                && deletions[0].entityID == id(8) && deletions[0].deletedAt == secondDay)
            precondition(backtests.count == 1 && backtests[0].id == id(9)
                && backtests[0].totalReturn == 0.1 && backtests[0].maxDrawdown == 0.02
                && backtests[0].pointsJSON == Data([1, 2, 3]) && backtests[0].configJSON == Data([4, 5]))
        }

        @MainActor static func main() throws {
            let mode = CommandLine.arguments[1]
            let schema = Schema([AssetCategory.self, AssetItem.self, AssetSnapshot.self,
                AssetEntry.self, BacktestRecord.self, SyncDeletionTombstone.self])
            let config = ModelConfiguration("IsolatedMigrationProof", schema: schema,
                url: URL(fileURLWithPath: CommandLine.arguments[2]))
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container); context.autosaveEnabled = false
            if mode == "create" { try seed(context) }
            try verify(context)
            #if MIGRATED_SCHEMA
            let entries = try context.fetch(FetchDescriptor<AssetEntry>())
            let deletion = try context.fetch(FetchDescriptor<SyncDeletionTombstone>())[0]
            let inherited = entries.first { $0.id == id(6) }!
            if mode == "migrate" {
                precondition(entries.allSatisfy { $0.inheritedFromEntryID == nil })
                precondition(deletion.snapshotDate == nil && deletion.itemID == nil)
                inherited.inheritedFromEntryID = id(5)
                deletion.snapshotDate = secondDay; deletion.itemID = id(2)
                try context.save()
            } else if mode == "reopen" {
                precondition(inherited.inheritedFromEntryID == id(5))
                precondition(deletion.snapshotDate == secondDay && deletion.itemID == id(2))
            }
            #endif
        }
    }
    """
    with tempfile.TemporaryDirectory(prefix="atm-schema-migration-") as folder:
        directory = Path(folder)
        (directory / "Support.swift").write_text(stubs)
        (directory / "Proof.swift").write_text(probe)
        for name, models in [("old", old), ("new", current)]:
            model_file = directory / (name + "Models.swift")
            model_file.write_text(models)
            command = ["swiftc", "-module-name", "AssetTimeMachine", "-parse-as-library"]
            if name == "new":
                command += ["-D", "MIGRATED_SCHEMA"]
            command += [str(model_file), str(directory / "Support.swift"), str(directory / "Proof.swift"),
                        "-o", str(directory / name)]
            subprocess.run(command, cwd=root, check=True)
        store = str(directory / "migration.store")
        for binary, mode in [("old", "create"), ("new", "migrate"), ("new", "reopen")]:
            subprocess.run([str(directory / binary), mode, store], cwd=root, check=True)
    print("PASS: real SwiftData schema migration preserves existing records and new optional fields")


if __name__ == "__main__":
    test_cloud_schema_migration()
