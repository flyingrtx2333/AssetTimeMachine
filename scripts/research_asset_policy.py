#!/usr/bin/env python3
"""Independent Research Agent asset-policy guard used by isolated workers.

This module deliberately does not import Flyingrtx code. A frozen contract may declare
that digital assets and leveraged products are forbidden, but workers independently
scan the frozen universe and candidate inputs when a policy snapshot is present.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Iterable


CRYPTO_TOKENS = {
    "btc", "bitcoin", "eth", "ethereum", "bnb", "binancecoin", "sol", "solana", "xrp", "ripple",
    "doge", "dogecoin", "ada", "cardano", "avax", "avalanche", "dot", "polkadot", "link", "chainlink",
    "ltc", "litecoin", "bch", "bitcoincash", "trx", "tron", "ton", "toncoin", "shib", "shiba",
    "sui", "apt", "aptos", "near", "atom", "cosmos", "uni", "uniswap", "aave", "fil", "filecoin",
    "etc", "ethereumclassic", "xlm", "stellar", "hbar", "hedera", "icp", "internetcomputer", "matic",
    "polygon", "pol", "pepe", "arb", "arbitrum", "op", "optimism", "crypto", "cryptocurrency",
    "digitalasset", "usdt", "usdc",
}
LEVERAGED_PRODUCT_TOKENS = {
    "tqqq", "sqqq", "upro", "spxu", "spxl", "spxs", "qld", "qid", "qids", "sso", "sh", "tmf", "tmv",
    "tecl", "tecs", "soxl", "soxs", "fas", "faz", "labu", "labd", "nugt", "dust", "jnug", "jdust",
    "udow", "sdow", "midu", "mids", "tna", "tza", "fngu", "fngd", "boil", "kold",
}
CRYPTO_TEXT_TOKENS = {
    "btc", "bitcoin", "eth", "ethereum", "bnb", "binancecoin", "sol", "solana", "xrp", "ripple",
    "doge", "dogecoin", "ada", "cardano", "avax", "avalanche", "polkadot", "chainlink", "litecoin",
    "bitcoincash", "trx", "tron", "toncoin", "shib", "aptos", "cosmos", "uniswap", "aave", "filecoin",
    "ethereumclassic", "stellar", "hedera", "internetcomputer", "matic", "polygon", "pepe", "arbitrum",
    "optimism", "crypto", "cryptocurrency", "digitalasset", "usdt", "usdc",
}
CRYPTO_PAIR_QUOTES = {"usd", "usdt", "usdc", "cny", "eur", "jpy"}
TEXT_MARKERS = ("数字货币", "数字资产", "加密货币", "虚拟货币", "杠杆etf", "反向etf")


def is_forbidden_asset_reference(value: str) -> bool:
    normalized = str(value or "").strip().lower()
    compact = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "", normalized)
    if not compact:
        return False
    parts = set(re.findall(r"[a-z0-9]+|[\u4e00-\u9fff]+", normalized))
    forbidden = CRYPTO_TOKENS | LEVERAGED_PRODUCT_TOKENS
    if any(marker in normalized for marker in TEXT_MARKERS):
        return True
    if compact in forbidden:
        return True
    if parts.intersection(CRYPTO_TEXT_TOKENS):
        return True
    if parts.intersection(LEVERAGED_PRODUCT_TOKENS - {"sh"}):
        return True
    return any(compact == f"{base}{quote}" for base in CRYPTO_TOKENS for quote in CRYPTO_PAIR_QUOTES)


def _snapshot_strings(snapshot: Dict[str, Any]) -> Iterable[tuple[str, str]]:
    for value in snapshot.get("universe") or []:
        yield "universe", str(value)
    candidate_inputs = snapshot.get("candidate_inputs") or {}
    if isinstance(candidate_inputs, dict):
        for candidate_id, inputs in candidate_inputs.items():
            if not isinstance(inputs, list):
                continue
            for value in inputs:
                yield f"candidate:{candidate_id}", str(value)


def validate_research_policy_snapshot(contract: Dict[str, Any]) -> None:
    snapshot = contract.get("research_policy_snapshot")
    if snapshot is None:
        # Compatibility path for contracts frozen before the snapshot field existed.
        # Their hard_constraints are still checked by each worker.
        return
    if not isinstance(snapshot, dict):
        raise ValueError("Frozen research policy snapshot is not an object")
    if snapshot.get("digital_assets_allowed") is not False:
        raise ValueError("Frozen policy snapshot does not explicitly forbid digital assets")
    if snapshot.get("leveraged_products_allowed") is not False:
        raise ValueError("Frozen policy snapshot does not explicitly forbid leveraged products")
    universe = snapshot.get("universe")
    candidate_inputs = snapshot.get("candidate_inputs")
    if not isinstance(universe, list) or not universe:
        raise ValueError("Frozen policy snapshot is missing universe")
    if not isinstance(candidate_inputs, dict):
        raise ValueError("Frozen policy snapshot is missing candidate inputs")
    for coordinate, value in _snapshot_strings(snapshot):
        if is_forbidden_asset_reference(value):
            raise ValueError(f"Frozen policy snapshot contains forbidden asset reference at {coordinate}: {value}")
