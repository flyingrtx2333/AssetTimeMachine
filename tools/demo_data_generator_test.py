#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT / "scripts" / "generate_demo_import_json.py"


def load_generator_module():
    spec = importlib.util.spec_from_file_location("generate_demo_import_json", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def entry_value(entry: dict) -> float:
    amount = entry.get("amount")
    if amount is not None:
        return float(amount)
    return float(entry.get("quantity") or 0) * float(entry.get("unitPrice") or 0)


class DemoDataGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.generator = load_generator_module()

    def test_cli_defaults_generate_three_year_daily_timeline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "demo.json"
            subprocess.run(
                [sys.executable, str(SCRIPT_PATH), "--out", str(output_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(output_path.read_text(encoding="utf-8"))

        snapshots = payload["snapshots"]
        self.assertEqual(len(snapshots), 1096)
        self.assertEqual(snapshots[0]["date"][:10], "2023-08-21")
        self.assertEqual(snapshots[-1]["date"][:10], "2026-08-20")

    def test_financial_assets_cover_accounts_currency_metal_etf_and_a_share(self) -> None:
        payload = self.generator.build_payload(
            days=1096,
            end_date=datetime(2026, 8, 20, tzinfo=timezone.utc),
        )
        financial_category_id = next(
            category["id"] for category in payload["categories"] if category["group"] == "financial"
        )
        financial_items = [
            item for item in payload["items"] if item["categoryID"] == financial_category_id
        ]
        names = {item["name"] for item in financial_items}
        symbols = {item["autoPricedAssetKind"] for item in financial_items}

        self.assertTrue({"微信", "支付宝", "银行活期", "现金"}.issubset(names))
        self.assertTrue({"美元 USD", "黄金", "黄金ETF", "纳指ETF", "沪深300ETF"}.issubset(names))
        self.assertTrue({"贵州茅台", "招商银行"}.issubset(names))
        self.assertIn("usd", symbols)
        self.assertIn("gold_cny", symbols)
        self.assertTrue(any(symbol and symbol.startswith("record_etf:") for symbol in symbols))
        self.assertTrue(any(symbol and symbol.startswith("record_a_share:") for symbol in symbols))

    def test_net_assets_rise_while_retaining_a_visible_drawdown(self) -> None:
        payload = self.generator.build_payload(
            days=1096,
            end_date=datetime(2026, 8, 20, tzinfo=timezone.utc),
        )
        group_by_item_id = {
            item["id"]: next(
                category["group"]
                for category in payload["categories"]
                if category["id"] == item["categoryID"]
            )
            for item in payload["items"]
        }
        net_assets = []
        for snapshot in payload["snapshots"]:
            assets = 0.0
            liabilities = 0.0
            for entry in snapshot["entries"]:
                value = entry_value(entry)
                if group_by_item_id[entry["itemID"]] == "liability":
                    liabilities += value
                else:
                    assets += value
            net_assets.append(assets - liabilities)

        running_peak = net_assets[0]
        max_drawdown = 0.0
        for value in net_assets:
            running_peak = max(running_peak, value)
            max_drawdown = max(max_drawdown, (running_peak - value) / running_peak)

        self.assertGreater(net_assets[-1], net_assets[0] * 1.40)
        self.assertGreaterEqual(max_drawdown, 0.10)
        self.assertLess(max_drawdown, 0.25)


if __name__ == "__main__":
    unittest.main()
