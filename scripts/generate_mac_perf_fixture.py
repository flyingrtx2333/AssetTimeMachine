#!/usr/bin/env python3
"""Create deterministic synthetic daily histories for isolated Mac memory tests."""

import argparse
import json
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path


NAMESPACE = uuid.UUID("7332a452-9e5d-4aa7-84bf-2a798397c37b")
END_DATE = date(2026, 9, 29)


def identifier(label: str) -> str:
    return str(uuid.uuid5(NAMESPACE, label))


def timestamp(day: date) -> str:
    return day.isoformat() + "T00:00:00Z"


def generate(path: Path, years: int) -> tuple[int, int]:
    start = END_DATE.replace(year=END_DATE.year - years)
    days = (END_DATE - start).days + 1
    created_at = timestamp(start)
    categories = [
        {"id": identifier("category-financial"), "name": "测试金融资产", "group": "financial", "createdAt": created_at},
        {"id": identifier("category-physical"), "name": "测试实物资产", "group": "physical", "createdAt": created_at},
        {"id": identifier("category-liability"), "name": "测试负债", "group": "liability", "createdAt": created_at},
    ]
    items = []
    for number in range(30):
        category = categories[0 if number < 20 else 1 if number < 27 else 2]
        items.append({
            "id": identifier(f"item-{number}"),
            "name": f"测试账户 {number + 1:02d}",
            "note": "", "valuationMethod": "directAmount", "sortOrder": number,
            "isActive": True, "createdAt": created_at,
            "updatedAt": created_at, "categoryID": category["id"],
        })

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as output:
        output.write('{"exportedAt":"' + timestamp(END_DATE) + '","categories":')
        json.dump(categories, output, ensure_ascii=False, separators=(",", ":"))
        output.write(',"items":')
        json.dump(items, output, ensure_ascii=False, separators=(",", ":"))
        output.write(',"snapshots":[')
        for day_index in range(days):
            if day_index:
                output.write(",")
            current = start + timedelta(days=day_index)
            moment = timestamp(current)
            entries = []
            for number, item in enumerate(items):
                baseline = 1_500 + 120 * number + 2.5 * day_index
                amount = round(baseline + ((day_index * (number + 3)) % 37) * 1.17, 2)
                entries.append({
                    "id": identifier(f"entry-{day_index}-{number}"),
                    "amount": amount, "note": "", "createdAt": moment,
                    "updatedAt": moment, "itemID": item["id"],
                })
            snapshot = {
                "id": identifier(f"snapshot-{day_index}"), "date": moment,
                "note": "", "createdAt": moment, "updatedAt": moment,
                "entries": entries,
            }
            json.dump(snapshot, output, ensure_ascii=False, separators=(",", ":"))
        output.write("]}")
    return days, days * len(items)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--years", type=int, choices=(1, 5, 10), required=True)
    args = parser.parse_args()
    snapshots, entries = generate(args.output, args.years)
    print(f"{args.output}: {snapshots} snapshots, {entries} entries")
