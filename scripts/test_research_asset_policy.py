from __future__ import annotations

import pytest

from research_asset_policy import is_forbidden_asset_reference, validate_research_policy_snapshot


def test_forbidden_asset_reference_covers_crypto_pairs_and_leveraged_products():
    for value in (
        "BTC-USD",
        "ETH/USDT",
        "BNB",
        "SOL-USD",
        "XRP",
        "DOGE",
        "ADA-USDT",
        "bitcoin_close",
        "solana_price",
        "TQQQ",
        "SOXL",
        "SPXL",
    ):
        assert is_forbidden_asset_reference(value), value
    for value in ("gold_cny", "nasdaq", "sp500", "600519.SH", "daily_close", "volatility_signal"):
        assert not is_forbidden_asset_reference(value), value


def test_policy_snapshot_rejects_forbidden_universe_or_candidate_inputs():
    valid = {
        "research_policy_snapshot": {
            "universe": ["gold_cny", "nasdaq"],
            "candidate_inputs": {"CANDIDATE_A": ["daily_close", "vix_close"]},
            "digital_assets_allowed": False,
            "leveraged_products_allowed": False,
        }
    }
    validate_research_policy_snapshot(valid)

    bad_universe = {
        "research_policy_snapshot": {
            **valid["research_policy_snapshot"],
            "universe": ["gold_cny", "SOL-USDT"],
        }
    }
    with pytest.raises(ValueError, match="forbidden asset reference"):
        validate_research_policy_snapshot(bad_universe)

    bad_input = {
        "research_policy_snapshot": {
            **valid["research_policy_snapshot"],
            "candidate_inputs": {"CANDIDATE_A": ["daily_close", "bitcoin_close"]},
        }
    }
    with pytest.raises(ValueError, match="forbidden asset reference"):
        validate_research_policy_snapshot(bad_input)


def test_policy_snapshot_keeps_legacy_contract_compatibility():
    validate_research_policy_snapshot({"hard_constraints": {"digital_assets_allowed": False}})
