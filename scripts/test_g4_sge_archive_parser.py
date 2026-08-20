#!/usr/bin/env python3
from __future__ import annotations

import unittest

from fetch_g4_holdout_raw import ArchiveListParser, DailyRow, dedupe_identical_daily_rows


class G4SGEArchiveParserTests(unittest.TestCase):
    def test_uses_trading_date_from_title_instead_of_publication_date(self) -> None:
        html = '''
        <ul>
          <li><a href="/sjzx/mrhqsj/510159" class="title">
            <span class="txt">上海黄金交易所2010年8月5日交易行情</span>
            <span class="fr">2010-08-06</span>
          </a></li>
          <li><a href="/sjzx/mrhqsj/510160" class="title">
            <span class="txt">上海黄金交易所2010年8月6日交易行情</span>
            <span class="fr">2010-08-06</span>
          </a></li>
        </ul>
        '''
        parser = ArchiveListParser()
        parser.feed(html)
        self.assertEqual(
            parser.links,
            [
                ("/sjzx/mrhqsj/510159", "2010-08-05"),
                ("/sjzx/mrhqsj/510160", "2010-08-06"),
            ],
        )

    def test_falls_back_to_iso_date_when_title_has_no_chinese_trading_date(self) -> None:
        html = '''
        <a href="/sjzx/mrhqsj/999999" class="title">
          <span class="txt">每日行情</span>
          <span class="fr">2018-01-03</span>
        </a>
        '''
        parser = ArchiveListParser()
        parser.feed(html)
        self.assertEqual(parser.links, [("/sjzx/mrhqsj/999999", "2018-01-03")])

    def test_identical_official_duplicate_rows_are_deduplicated(self) -> None:
        row = DailyRow(day="2010-07-30", close=256.15, open=255.1, high=257.0, low=255.08)
        self.assertEqual(dedupe_identical_daily_rows([row, row], "SGE:Au100g"), [row])

    def test_conflicting_official_duplicate_rows_are_rejected(self) -> None:
        left = DailyRow(day="2010-07-30", close=256.15, open=255.1, high=257.0, low=255.08)
        right = DailyRow(day="2010-07-30", close=256.16, open=255.1, high=257.0, low=255.08)
        with self.assertRaises(RuntimeError):
            dedupe_identical_daily_rows([left, right], "SGE:Au100g")


if __name__ == "__main__":
    unittest.main()
