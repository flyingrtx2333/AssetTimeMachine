#!/usr/bin/env python3
import argparse
import json
import math
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

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
    icon_name: Optional[str]
    note: str
    valuation_method: str = "directAmount"
    market_symbol: Optional[str] = None


CATEGORIES = [
    CategoryDef("financial", "金融资产", "financial"),
    CategoryDef("physical", "实物资产", "physical"),
    CategoryDef("liability", "负债", "liability"),
]

ITEMS = [
    ItemDef("wechat", "微信", "financial", "icon_wechat", "演示资金项"),
    ItemDef("alipay", "支付宝", "financial", "icon_alipay", "演示资金项"),
    ItemDef("bank_demand", "银行活期", "financial", "icon_bank_card", "演示资金项"),
    ItemDef("cash", "现金", "financial", "icon_cash", "演示资金项"),
    ItemDef("usd_cash", "美元 USD", "financial", None, "演示外币项", "quantityAndUnitPrice", "usd"),
    ItemDef("gold", "黄金", "financial", None, "演示贵金属项", "quantityAndUnitPrice", "gold_cny"),
    ItemDef(
        "gold_etf",
        "黄金ETF",
        "financial",
        None,
        "演示ETF项",
        "quantityAndUnitPrice",
        "record_etf:159937.sz",
    ),
    ItemDef(
        "nasdaq_etf",
        "纳指ETF",
        "financial",
        None,
        "演示ETF项",
        "quantityAndUnitPrice",
        "record_etf:513100.sh",
    ),
    ItemDef(
        "csi300_etf",
        "沪深300ETF",
        "financial",
        None,
        "演示ETF项",
        "quantityAndUnitPrice",
        "record_etf:510300.sh",
    ),
    ItemDef(
        "moutai",
        "贵州茅台",
        "financial",
        None,
        "演示A股项",
        "quantityAndUnitPrice",
        "record_a_share:600519.sh",
    ),
    ItemDef(
        "cmb",
        "招商银行",
        "financial",
        None,
        "演示A股项",
        "quantityAndUnitPrice",
        "record_a_share:600036.sh",
    ),
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


def gaussian(t: float, center: float, width: float) -> float:
    return math.exp(-0.5 * ((t - center) / width) ** 2)


def market_cycle(t: float, phase: float = 0.0) -> float:
    tau = math.tau
    return (
        0.055 * math.sin(tau * 3.2 * t + phase)
        + 0.032 * math.sin(tau * 10.7 * t + phase * 0.7)
        + 0.018 * math.cos(tau * 31.0 * t + phase * 1.3)
    )


def drawdown_cycle(t: float) -> float:
    return (
        -0.18 * gaussian(t, 0.26, 0.035)
        -0.23 * gaussian(t, 0.56, 0.045)
        -0.16 * gaussian(t, 0.80, 0.030)
    )


def amount_series(day_index: int, total_days: int) -> dict[str, float]:
    t = day_index / max(total_days - 1, 1)
    tau = math.tau
    broad_drawdown = drawdown_cycle(t)

    wechat = 16_000 + 5_000 * t + 3_600 * math.sin(tau * 7.2 * t) + 1_700 * math.cos(tau * 19.1 * t + 0.4)
    alipay = 8_500 + 3_500 * t + 2_300 * math.sin(tau * 8.0 * t + 0.8) + 900 * math.cos(tau * 23.0 * t)
    bank_demand = 115_000 + 72_000 * t + 24_000 * math.sin(tau * 4.4 * t + 1.1) + 11_000 * math.cos(tau * 15.0 * t + 0.2)
    cash = 5_200 + 1_000 * t + 1_300 * math.sin(tau * 12.0 * t + 0.3) + 600 * math.cos(tau * 29.7 * t)

    house = 1_620_000 * (
        1 + 0.42 * t + 0.045 * math.sin(tau * 2.2 * t + 0.25) + broad_drawdown * 0.72
    )
    car = 188_000 * (1 - 0.28 * t + 0.035 * math.sin(tau * 4.8 * t + 1.0))
    parking = 116_000 * (
        1 + 0.24 * t + 0.055 * math.sin(tau * 3.7 * t + 0.7) + broad_drawdown * 0.45
    )

    huabei = 3_500 + 6_500 * (math.sin(tau * 9.2 * t + 0.5) + 1) / 2 + 900 * math.cos(tau * 25.1 * t)
    baitiao = 1_600 + 4_200 * (math.sin(tau * 6.6 * t + 1.1) + 1) / 2 + 500 * math.cos(tau * 17.4 * t)
    mortgage = 820_000 - 205_000 * t + 9_000 * math.sin(tau * 1.45 * t + 2.2)

    return {
        "wechat": round(clamp(wechat, 3_000), 2),
        "alipay": round(clamp(alipay, 2_000), 2),
        "bank_demand": round(clamp(bank_demand, 50_000), 2),
        "cash": round(clamp(cash, 1_000), 2),
        "house": round(clamp(house, 1_000_000), 2),
        "car": round(clamp(car, 80_000), 2),
        "parking": round(clamp(parking, 50_000), 2),
        "huabei": round(clamp(huabei, 0), 2),
        "baitiao": round(clamp(baitiao, 0), 2),
        "mortgage": round(clamp(mortgage, 500_000), 2),
    }


def market_position_series(day_index: int, total_days: int) -> dict[str, tuple[float, float]]:
    t = day_index / max(total_days - 1, 1)
    tau = math.tau
    broad_drawdown = drawdown_cycle(t)

    usd_per_cny = 0.1405 + 0.0024 * math.sin(tau * 2.1 * t + 0.9) - 0.0012 * t
    cny_per_usd = 1 / usd_per_cny
    gold_price = 470 * (1 + 0.66 * t + market_cycle(t, 0.5) * 0.65 + broad_drawdown * 0.45)
    gold_etf_price = 4.05 * (1 + 0.58 * t + market_cycle(t, 1.0) * 0.85 + broad_drawdown * 0.60)
    nasdaq_etf_price = 1.12 * (1 + 1.05 * t + market_cycle(t, 2.1) * 1.25 + broad_drawdown * 1.15)
    csi300_etf_price = 3.62 * (1 + 0.34 * t + market_cycle(t, 3.0) * 1.10 + broad_drawdown * 1.00)
    moutai_price = 1_520 * (1 + 0.42 * t + market_cycle(t, 4.0) * 1.35 + broad_drawdown * 1.20)
    cmb_price = 31.5 * (1 + 0.72 * t + market_cycle(t, 5.1) * 1.20 + broad_drawdown * 1.05)

    return {
        "usd_cash": (22_000.0, round(clamp(cny_per_usd, 6.0), 4)),
        "gold": (360.0, round(clamp(gold_price, 300), 4)),
        "gold_etf": (32_000.0, round(clamp(gold_etf_price, 2.0), 4)),
        "nasdaq_etf": (120_000.0, round(clamp(nasdaq_etf_price, 0.45), 4)),
        "csi300_etf": (58_000.0, round(clamp(csi300_etf_price, 1.8), 4)),
        "moutai": (120.0, round(clamp(moutai_price, 700), 4)),
        "cmb": (6_000.0, round(clamp(cmb_price, 14), 4)),
    }


def anchor_series(day_index: int, total_days: int) -> dict[str, float]:
    t = day_index / max(total_days - 1, 1)
    tau = math.tau
    market_positions = market_position_series(day_index, total_days)

    gold_cny = market_positions["gold"][1]
    btc_usd = 44_000 + 52_000 * t + 18_000 * math.sin(tau * 1.8 * t + 0.5) + 6_000 * math.cos(tau * 4.3 * t)
    nasdaq_usd = 13_500 + 8_000 * t + 1_850 * math.sin(tau * 1.2 * t + 0.3) + 620 * math.cos(tau * 3.6 * t)
    usd_per_cny = 0.1385 + 0.0016 * math.sin(tau * 1.9 * t + 1.0) - 0.0007 * t

    return {
        "goldAnchorPriceCNY": round(clamp(gold_cny, 500), 4),
        "btcAnchorPriceUSD": round(clamp(btc_usd, 20_000), 4),
        "nasdaqAnchorPriceUSD": round(clamp(nasdaq_usd, 5_000), 4),
        "usdPerCNY": round(clamp(usd_per_cny, 0.12), 6),
    }


def build_payload(days: int, end_date: datetime) -> dict:
    start_date = end_date - timedelta(days=days - 1)
    created_at = iso(end_date.replace(hour=12, minute=0, second=0, microsecond=0))

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
                "valuationMethod": item.valuation_method,
                "autoPricedAssetKind": item.market_symbol,
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
        market_positions = market_position_series(index, days)
        anchors = anchor_series(index, days)

        entries = []
        for item in ITEMS:
            if item.valuation_method == "quantityAndUnitPrice":
                quantity, unit_price = market_positions[item.key]
                amount = None
            else:
                amount = amounts[item.key]
                quantity = None
                unit_price = None
            entries.append(
                {
                    "id": stable_uuid(f"entry:{day_key}:{item.key}"),
                    "amount": amount,
                    "quantity": quantity,
                    "unitPrice": unit_price,
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
    parser.add_argument("--days", type=int, default=1096, help="Number of daily snapshots to generate.")
    parser.add_argument("--end-date", default="2026-08-20", help="Inclusive end date in YYYY-MM-DD.")
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
