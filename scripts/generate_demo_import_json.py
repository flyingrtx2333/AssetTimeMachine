#!/usr/bin/env python3
import argparse
import json
import math
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

NAMESPACE = uuid.UUID("0be6cda7-a8dd-4372-a5e3-f0e4f1f2d8d9")
UTC = timezone.utc


@dataclass(frozen=True)
class CategoryDef:
    key: str
    name: str
    group: str


@dataclass(frozen=True)
class ItemDef:
    key: str
    name: str
    category_key: str
    icon_name: str
    note: str


CATEGORIES = [
    CategoryDef("financial", "金融资产", "financial"),
    CategoryDef("physical", "实物资产", "physical"),
    CategoryDef("liability", "负债", "liability"),
]

ITEMS = [
    ItemDef("wechat", "微信", "financial", "icon_wechat", "演示资金项"),
    ItemDef("alipay", "支付宝", "financial", "icon_alipay", "演示资金项"),
    ItemDef("bank_card", "银行卡", "financial", "icon_bank_card", "演示资金项"),
    ItemDef("cash", "现金", "financial", "icon_cash", "演示资金项"),
    ItemDef("house", "房产", "physical", "icon_house", "演示实物项"),
    ItemDef("car", "车辆", "physical", "icon_car", "演示实物项"),
    ItemDef("parking", "车位", "physical", "icon_parking", "演示实物项"),
    ItemDef("huabei", "花呗", "liability", "icon_huabei", "演示负债项"),
    ItemDef("baitiao", "白条", "liability", "icon_credit_card", "演示负债项"),
    ItemDef("mortgage", "房贷", "liability", "icon_mortgage", "演示负债项"),
]


def stable_uuid(key: str) -> str:
    return str(uuid.uuid5(NAMESPACE, key))


def iso(dt: datetime) -> str:
    return dt.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def clamp(value: float, floor: float) -> float:
    return max(value, floor)


def amount_series(day_index: int, total_days: int) -> dict[str, float]:
    t = day_index / max(total_days - 1, 1)
    tau = math.tau

    wechat = 18_000 + 2_800 * math.sin(tau * 5.2 * t) + 1_500 * math.cos(tau * 2.1 * t + 0.4) + 1_200 * t
    alipay = 9_500 + 1_600 * math.sin(tau * 4.0 * t + 0.8) + 700 * math.cos(tau * 3.0 * t) + 400 * t
    bank_card = 165_000 + 26_000 * t + 12_000 * math.sin(tau * 2.4 * t + 1.1) + 7_000 * math.cos(tau * 6.0 * t + 0.2)
    cash = 5_800 + 900 * math.sin(tau * 7.0 * t + 0.3) + 500 * math.cos(tau * 3.7 * t)

    house = 1_820_000 + 62_000 * t + 36_000 * math.sin(tau * 1.2 * t + 0.25) + 18_000 * math.cos(tau * 4.1 * t)
    car = 198_000 - 24_000 * t + 5_000 * math.sin(tau * 2.8 * t + 1.0)
    parking = 118_000 + 5_000 * t + 6_500 * math.sin(tau * 1.7 * t + 0.7)

    huabei = 3_800 + 2_400 * (math.sin(tau * 6.2 * t + 0.5) + 1) / 2 + 300 * math.cos(tau * 2.1 * t)
    baitiao = 1_400 + 950 * (math.sin(tau * 4.6 * t + 1.1) + 1) / 2 + 180 * math.cos(tau * 3.4 * t)
    mortgage = 735_000 - 42_000 * t + 8_000 * math.sin(tau * 1.45 * t + 2.2)

    return {
        "wechat": round(clamp(wechat, 3_000), 2),
        "alipay": round(clamp(alipay, 2_000), 2),
        "bank_card": round(clamp(bank_card, 50_000), 2),
        "cash": round(clamp(cash, 1_000), 2),
        "house": round(clamp(house, 1_600_000), 2),
        "car": round(clamp(car, 80_000), 2),
        "parking": round(clamp(parking, 50_000), 2),
        "huabei": round(clamp(huabei, 0), 2),
        "baitiao": round(clamp(baitiao, 0), 2),
        "mortgage": round(clamp(mortgage, 500_000), 2),
    }


def anchor_series(day_index: int, total_days: int) -> dict[str, float]:
    t = day_index / max(total_days - 1, 1)
    tau = math.tau

    gold_cny = 640 + 52 * t + 28 * math.sin(tau * 1.7 * t) + 9 * math.cos(tau * 5.1 * t)
    btc_usd = 71_000 + 8_000 * t + 14_000 * math.sin(tau * 1.8 * t + 0.5) + 4_000 * math.cos(tau * 4.3 * t)
    nasdaq_usd = 17_200 + 1_500 * t + 1_050 * math.sin(tau * 1.2 * t + 0.3) + 320 * math.cos(tau * 3.6 * t)
    usd_per_cny = 0.1385 + 0.0016 * math.sin(tau * 1.9 * t + 1.0) - 0.0007 * t

    return {
        "goldAnchorPriceCNY": round(clamp(gold_cny, 500), 4),
        "btcAnchorPriceUSD": round(clamp(btc_usd, 20_000), 4),
        "nasdaqAnchorPriceUSD": round(clamp(nasdaq_usd, 5_000), 4),
        "usdPerCNY": round(clamp(usd_per_cny, 0.12), 6),
    }


def build_payload(days: int, end_date: datetime) -> dict:
    start_date = end_date - timedelta(days=days - 1)
    created_at = iso(datetime(2026, 5, 7, 6, 0, tzinfo=UTC))

    categories = [
        {
            "id": stable_uuid(f"category:{category.key}"),
            "name": category.name,
            "group": category.group,
            "createdAt": created_at,
        }
        for category in CATEGORIES
    ]

    category_id_by_key = {category.key: stable_uuid(f"category:{category.key}") for category in CATEGORIES}

    category_sort_order: dict[str, int] = {category.key: 0 for category in CATEGORIES}
    items = []
    for item in ITEMS:
        items.append(
            {
                "id": stable_uuid(f"item:{item.key}"),
                "name": item.name,
                "note": item.note,
                "iconName": item.icon_name,
                "valuationMethod": "directAmount",
                "autoPricedAssetKind": None,
                "sortOrder": category_sort_order[item.category_key],
                "isActive": True,
                "createdAt": created_at,
                "updatedAt": created_at,
                "categoryID": category_id_by_key[item.category_key],
            }
        )
        category_sort_order[item.category_key] += 1

    snapshots = []
    for index in range(days):
        day = start_date + timedelta(days=index)
        day = datetime(day.year, day.month, day.day, tzinfo=UTC)
        day_key = day.strftime("%Y-%m-%d")
        amounts = amount_series(index, days)
        anchors = anchor_series(index, days)

        entries = []
        for item in ITEMS:
            entries.append(
                {
                    "id": stable_uuid(f"entry:{day_key}:{item.key}"),
                    "amount": amounts[item.key],
                    "quantity": None,
                    "unitPrice": None,
                    "note": "",
                    "createdAt": iso(day),
                    "updatedAt": iso(day),
                    "itemID": stable_uuid(f"item:{item.key}"),
                }
            )

        snapshots.append(
            {
                "id": stable_uuid(f"snapshot:{day_key}"),
                "date": iso(day),
                "note": "演示数据",
                "createdAt": iso(day),
                "updatedAt": iso(day),
                "goldAnchorPriceCNY": anchors["goldAnchorPriceCNY"],
                "goldAnchorPriceDate": iso(day),
                "btcAnchorPriceUSD": anchors["btcAnchorPriceUSD"],
                "btcAnchorPriceDate": iso(day),
                "nasdaqAnchorPriceUSD": anchors["nasdaqAnchorPriceUSD"],
                "nasdaqAnchorPriceDate": iso(day),
                "usdPerCNY": anchors["usdPerCNY"],
                "usdPerCNYDate": iso(day),
                "marketAnchorsUpdatedAt": iso(day),
                "entries": entries,
            }
        )

    return {
        "exportedAt": created_at,
        "categories": categories,
        "items": items,
        "snapshots": snapshots,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate reusable demo import JSON for AssetTimeMachine.")
    parser.add_argument("--days", type=int, default=180, help="Number of daily snapshots to generate.")
    parser.add_argument("--end-date", default="2026-05-06", help="Inclusive end date in YYYY-MM-DD.")
    parser.add_argument("--out", default="demo/time-machine-demo.json", help="Output JSON path.")
    args = parser.parse_args()

    end_date = datetime.strptime(args.end_date, "%Y-%m-%d").replace(tzinfo=UTC)
    payload = build_payload(days=args.days, end_date=end_date)

    output_path = Path(args.out)
    if not output_path.is_absolute():
        output_path = Path(__file__).resolve().parent.parent / output_path
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False, indent=2)

    print(f"generated {len(payload['snapshots'])} snapshots -> {output_path}")


if __name__ == "__main__":
    main()
