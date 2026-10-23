"""End-to-end research pipeline with audit-friendly outputs."""

from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path

from marketmind.data import frame_fingerprint, read_price_csv
from marketmind.mii import MarketMind, MarketMindConfig, MIIResult


def save_mii_result(
    result: MIIResult,
    directory: str | Path,
    *,
    input_hash: str | None = None,
    extra_metadata: dict[str, object] | None = None,
) -> Path:
    """Persist raw metrics, normalized metrics, components, regimes, and metadata."""
    output = Path(directory)
    output.mkdir(parents=True, exist_ok=True)
    result.raw_metrics.to_csv(output / "raw_metrics.csv")
    result.normalized_metrics.to_csv(output / "normalized_metrics.csv")
    result.to_frame().to_csv(output / "mii_regimes.csv")
    metadata = {"package": "marketmind", "version": "0.1.0", "config": result.metadata()}
    if input_hash is not None:
        metadata["input_sha256"] = input_hash
    if extra_metadata:
        metadata.update(extra_metadata)
    (output / "run_metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    return output


def run_mii_pipeline(
    prices_path: str | Path,
    output_directory: str | Path,
    *,
    config: MarketMindConfig | None = None,
    primary_columns: Sequence[str] | None = None,
    network_columns: Sequence[str] | None = None,
) -> MIIResult:
    """Read a canonical price CSV, estimate MII, and persist the full audit trail."""
    prices = read_price_csv(prices_path)
    default_primary = ["SPX", "NDX", "SX5E", "ES"]
    selected_primary = (
        list(primary_columns)
        if primary_columns is not None
        else (default_primary if set(default_primary).issubset(prices.columns) else list(prices.columns))
    )
    selected_network = list(network_columns) if network_columns is not None else list(prices.columns)
    missing = (set(selected_primary) | set(selected_network)) - set(prices.columns)
    if missing:
        raise ValueError(f"requested columns are missing from the price file: {sorted(missing)}")
    result = MarketMind(config).fit_transform(
        prices[selected_primary], network_data=prices[selected_network]
    )
    save_mii_result(
        result,
        output_directory,
        input_hash=frame_fingerprint(prices),
        extra_metadata={
            "primary_columns": selected_primary,
            "network_columns": selected_network,
        },
    )
    return result
