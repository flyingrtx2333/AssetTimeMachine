#!/usr/bin/env python3
"""Synthetic, reproducible recording data for the iOS store screenshots.

These are example account balances, not a strategy backtest or a user's data.
"""
import argparse
import json
import math
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path


def fixture(language):
    def uid(key):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "atm-store-20261103/" + key))

    def iso(day):
        return datetime.combine(day, datetime.min.time(), timezone.utc).isoformat().replace("+00:00", "Z")

    end = date(2026, 11, 3)
    created = iso(end)
    english = language == "en-US"
    categories = [
        dict(id=uid("financial"), name="Financial assets" if english else "金融资产", group="financial", createdAt=created),
        dict(id=uid("liability"), name="Liabilities" if english else "负债", group="liability", createdAt=created),
    ]
    accounts = [
        ("bank", "银行活期", "Bank savings", "icon_bank_card", 76120.53),
        ("deposit", "定期存款", "Term deposit", "icon_bank_card", 128600.00),
        ("fund", "基金账户", "Funds", "icon_fund", 85320.75),
        ("stock", "股票账户", "Stocks", "icon_stock", 64780.32),
        ("gold", "黄金持仓", "Gold holdings", "icon_gold", 39820.16),
        ("cash", "应急储备", "Emergency fund", "icon_cash", 25600.00),
        ("card", "信用卡", "Credit card", "icon_credit_card", 4836.27),
        ("loan", "分期贷款", "Installment loan", "icon_mortgage", 12600.00),
    ]
    items = [dict(id=uid(key), name=en if english else zh, note="", iconName=icon,
                  valuationMethod="directAmount", autoPricedAssetKind=None,
                  sortOrder=i, isActive=True, createdAt=created, updatedAt=created,
                  categoryID=uid("liability" if i >= 6 else "financial"))
             for i, (key, zh, en, icon, _) in enumerate(accounts)]
    snapshots = []
    for d in range(365):
        day = end - timedelta(days=364-d)
        t = d / 364
        entries = []
        for i, (key, _, _, _, base) in enumerate(accounts):
            if i >= 6:
                amount = base + (11 - d // 31) * (260 if i == 6 else 420)
            elif i in (1, 5):
                amount = base * (0.87 + 0.13*t)
            else:
                amount = base * (0.72 + 0.28*t + 0.033*math.sin(d*.071+i)
                                 + 0.008*math.sin(d*.71+i) - 0.035*math.exp(-((d-221)/20)**2))
            entries.append(dict(id=uid(f"{day}/{key}"), itemID=uid(key), amount=round(amount, 2),
                                quantity=None, unitPrice=None, note="", createdAt=iso(day), updatedAt=iso(day)))
        snapshots.append(dict(id=uid(str(day)), date=iso(day), note="Sample data" if english else "示例数据",
                              createdAt=iso(day), updatedAt=iso(day), entries=entries))
    return dict(exportedAt=created, categories=categories, items=items, snapshots=snapshots)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for locale in ("zh-Hans", "en-US"):
        path = args.output / f"fixture-{locale}.json"
        path.write_text(json.dumps(fixture(locale), ensure_ascii=False), encoding="utf-8")
        print(path)
