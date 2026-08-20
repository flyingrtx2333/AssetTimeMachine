#!/usr/bin/env python3
from __future__ import annotations

import unittest

from build_g4_identity_reference_fixture import build_identity_reference_fixture


class G4IdentityReferenceFixtureTests(unittest.TestCase):
    @staticmethod
    def series(symbol: str, currency: str, unit: str) -> dict:
        return {
            'symbol': symbol,
            'currency': currency,
            'unit': unit,
            'category': 'test',
            'label': symbol,
            'source': 'exposed-base',
            'dates': ['2009-07-02', '2009-07-03', '2009-07-06', '2026-08-12', '2026-08-13'],
            'prices': [99.0, 100.0, 101.0, 200.0, 201.0],
            'open_prices': None, 'high_prices': None, 'low_prices': None, 'close_prices': None, 'volumes': None,
        }

    def test_aliases_exposed_base_roles_and_clips_window(self) -> None:
        base = {'series': [
            self.series('gold_cny', 'CNY', 'gram'),
            self.series('nasdaq_composite', 'USD', 'index'),
            self.series('sp500', 'USD', 'index'),
            self.series('csi300', 'CNY', 'index'),
            self.series('shanghai_composite', 'CNY', 'index'),
            self.series('usd_per_cny', 'USD', 'cny'),
        ]}
        manifest = {
            'holdout_id': 'TEST-G4', 'strategy_version': 'dualcore-v11-2026-08-15',
            'evaluation_window': {'start': '2009-07-03', 'end': '2026-08-12'},
            'role_slots': [
                {'role': 'gold_safe_haven'}, {'role': 'us_growth_equity'}, {'role': 'us_broad_equity'},
                {'role': 'china_large_equity'}, {'role': 'china_broad_equity'},
            ],
        }
        out = build_identity_reference_fixture(base, manifest)
        by_symbol = {row['symbol']: row for row in out['series']}
        self.assertEqual(by_symbol['atm_g4_gold_safe_haven']['prices'], [100.0, 101.0, 200.0])
        self.assertEqual(by_symbol['atm_g4_us_growth_equity']['identity_reference']['source_symbol'], 'nasdaq_composite')
        self.assertEqual(out['g4_normalization']['evaluation_window']['start'], '2009-07-03')
        self.assertEqual(len(out['g4_normalization']['role_symbols']), 5)

    def test_missing_base_role_is_rejected(self) -> None:
        base = {'series': [self.series('gold_cny', 'CNY', 'gram')]}
        manifest = {'holdout_id': 'TEST-G4', 'strategy_version': 'v', 'evaluation_window': {'start': '2009-07-03', 'end': '2026-08-12'}, 'role_slots': []}
        with self.assertRaises(SystemExit):
            build_identity_reference_fixture(base, manifest)


if __name__ == '__main__':
    unittest.main()
