import unittest

from scripts.factor_library_catalog import build_factor_catalog, parse_factor_definition


class FactorLibraryCatalogTests(unittest.TestCase):
    def test_current_inventory_is_exact_and_classified(self) -> None:
        catalog = build_factor_catalog()
        by_key = {row["factor_key"]: row for row in catalog}
        self.assertEqual(len(catalog), 184)
        self.assertEqual(len(by_key), 184)
        self.assertEqual(
            sum(row["research_role"] == "control" for row in catalog),
            8,
        )
        self.assertEqual(
            sum(row["lifecycle_status"] == "candidate" for row in catalog),
            2,
        )
        self.assertEqual(
            by_key["risk_adjusted_momentum_60_20"]["lifecycle_status"],
            "candidate",
        )
        self.assertEqual(
            by_key["risk_adjusted_momentum_252_60"]["lifecycle_status"],
            "candidate",
        )

    def test_catalog_formula_is_parameterized(self) -> None:
        by_key = {row["factor_key"]: row for row in build_factor_catalog()}
        self.assertEqual(
            by_key["mom_gold_60"]["parameters"],
            {"asset": "gold", "window": 60},
        )
        self.assertEqual(
            by_key["vol_sp500_20"]["formula_text"],
            "std(daily_return(sp500), 20)",
        )
        self.assertEqual(
            by_key["state_cash_ratio"]["research_role"],
            "control",
        )

    def test_unknown_factor_key_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "无法识别因子编号"):
            parse_factor_definition("not_a_real_factor", "mystery")

    def test_catalog_is_deterministic(self) -> None:
        first = build_factor_catalog()
        second = build_factor_catalog()
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
