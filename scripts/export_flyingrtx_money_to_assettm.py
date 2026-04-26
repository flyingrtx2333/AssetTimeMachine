#!/usr/bin/env python3
import argparse
import json
import uuid
from datetime import datetime, time, timezone
from decimal import Decimal

import pymysql

NAMESPACE = uuid.UUID("7d8021d4-2f0f-4c0d-a469-f27c57cb0b55")

CATEGORY_DEFS = {
    "financial": {"name": "金融资产", "group": "financial"},
    "physical": {"name": "实物资产", "group": "physical"},
    "liability": {"name": "负债", "group": "liability"},
}

FIELD_DEFS = {
    "ccb_current": {"name": "建行活期", "category": "financial", "valuation": "directAmount"},
    "ccb_financial_rmb": {"name": "建行理财 RMB", "category": "financial", "valuation": "directAmount"},
    "ccb_financial_usd": {"name": "建行理财 USD", "category": "financial", "valuation": "quantityAndUnitPrice", "price_field": "usd_exchange_rate"},
    "cmb_current": {"name": "招行活期", "category": "financial", "valuation": "directAmount"},
    "cmb_financial_rmb": {"name": "招行理财 RMB", "category": "financial", "valuation": "directAmount"},
    "cmb_financial_usd": {"name": "招行理财 USD", "category": "financial", "valuation": "quantityAndUnitPrice", "price_field": "usd_exchange_rate"},
    "boc_current": {"name": "中行活期", "category": "financial", "valuation": "directAmount"},
    "pysteam": {"name": "PySteam", "category": "financial", "valuation": "directAmount"},
    "wechat": {"name": "微信", "category": "financial", "valuation": "directAmount"},
    "alipay": {"name": "支付宝", "category": "financial", "valuation": "directAmount"},
    "stocks": {"name": "股票", "category": "financial", "valuation": "directAmount"},
    "crypto": {"name": "加密货币", "category": "financial", "valuation": "directAmount"},
    "gold": {"name": "黄金", "category": "financial", "valuation": "quantityAndUnitPrice", "price_field": "gold_price"},
    "secondary_assets_total": {"name": "其他资产", "category": "physical", "valuation": "directAmount"},
    "huabei": {"name": "花呗", "category": "liability", "valuation": "directAmount"},
    "baitiao": {"name": "白条", "category": "liability", "valuation": "directAmount"},
    "loan": {"name": "贷款", "category": "liability", "valuation": "directAmount"},
    "meituan": {"name": "美团月付", "category": "liability", "valuation": "directAmount"},
}

SKIP_FIELDS = {
    "id",
    "tenant_id",
    "created_by_user_id",
    "record_date",
    "main_assets_total_gold_equivalent",
    "main_assets_total",
    "liabilities_total",
    "gold_price",
    "usd_exchange_rate",
    "cmb_gold_profit",
    "created_at",
    "updated_at",
}


def stable_uuid(key: str) -> str:
    return str(uuid.uuid5(NAMESPACE, key))


def to_float(value):
    if value is None:
        return None
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    return float(value)


def to_iso_utc(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def as_iso(dt):
    if dt is None:
        return to_iso_utc(datetime.now(timezone.utc))
    if isinstance(dt, str):
        if dt.endswith("Z") or "+" in dt[10:]:
            return dt
        return f"{dt}Z" if "T" in dt else f"{dt}T00:00:00Z"
    return to_iso_utc(dt)


def snapshot_date_iso(record_date):
    if hasattr(record_date, "year"):
        return to_iso_utc(datetime.combine(record_date, time.min, tzinfo=timezone.utc))
    return f"{str(record_date)[:10]}T00:00:00Z"


def is_nonzero(value):
    number = to_float(value)
    return number is not None and abs(number) > 1e-9


def build_payload(rows: list[dict]) -> dict:
    active_fields = []
    for field in FIELD_DEFS:
        if any(is_nonzero(row.get(field)) for row in rows):
            active_fields.append(field)

    used_categories = []
    for category_key in CATEGORY_DEFS:
        if any(FIELD_DEFS[field]["category"] == category_key for field in active_fields):
            used_categories.append(category_key)

    now_iso = to_iso_utc(datetime.now(timezone.utc))

    categories = []
    for category_key in used_categories:
        category = CATEGORY_DEFS[category_key]
        categories.append(
            {
                "id": stable_uuid(f"category:{category_key}"),
                "name": category["name"],
                "group": category["group"],
                "createdAt": now_iso,
            }
        )

    items = []
    for sort_order, field in enumerate(active_fields):
        definition = FIELD_DEFS[field]
        items.append(
            {
                "id": stable_uuid(f"item:{field}"),
                "name": definition["name"],
                "note": "",
                "valuationMethod": definition["valuation"],
                "sortOrder": sort_order,
                "isActive": True,
                "createdAt": now_iso,
                "updatedAt": now_iso,
                "categoryID": stable_uuid(f"category:{definition['category']}"),
            }
        )

    snapshots = []
    for row in rows:
        record_date = row["record_date"]
        snapshot_key = str(record_date)
        snapshot_created = as_iso(row.get("created_at"))
        snapshot_updated = as_iso(row.get("updated_at"))
        entries = []

        for field in active_fields:
            definition = FIELD_DEFS[field]
            raw_value = to_float(row.get(field))
            if raw_value is None:
                raw_value = 0.0

            entry = {
                "id": stable_uuid(f"entry:{snapshot_key}:{field}"),
                "amount": None,
                "quantity": None,
                "unitPrice": None,
                "note": "",
                "createdAt": snapshot_created,
                "updatedAt": snapshot_updated,
                "itemID": stable_uuid(f"item:{field}"),
            }

            if definition["category"] == "liability":
                entry["amount"] = abs(raw_value)
            elif definition["valuation"] == "quantityAndUnitPrice":
                entry["quantity"] = raw_value
                price_field = definition.get("price_field")
                entry["unitPrice"] = to_float(row.get(price_field)) or 0.0
            else:
                entry["amount"] = raw_value

            entries.append(entry)

        snapshots.append(
            {
                "id": stable_uuid(f"snapshot:{snapshot_key}"),
                "date": snapshot_date_iso(record_date),
                "note": "",
                "createdAt": snapshot_created,
                "updatedAt": snapshot_updated,
                "entries": entries,
            }
        )

    return {
        "exportedAt": now_iso,
        "categories": categories,
        "items": items,
        "snapshots": snapshots,
    }


def fetch_rows(args) -> list[dict]:
    connection = pymysql.connect(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        database=args.database,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT * FROM money_count WHERE tenant_id=%s ORDER BY record_date ASC, id ASC",
                (args.tenant_id,),
            )
            return list(cursor.fetchall())
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description="Export Flyingrtx money_count rows to AssetTimeMachine import JSON.")
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--tenant-id", type=int, default=1)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    rows = fetch_rows(args)
    payload = build_payload(rows)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print(f"exported {len(rows)} records to {args.out}")


if __name__ == "__main__":
    main()
