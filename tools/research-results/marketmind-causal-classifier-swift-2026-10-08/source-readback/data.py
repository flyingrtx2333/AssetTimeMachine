"""Reproducible data ingestion, validation, and provenance manifests."""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd
import yaml

from marketmind._validation import validate_frame

PAPER_PUBLIC_TICKERS: dict[str, str] = {
    "SPX": "^GSPC",
    "NDX": "^NDX",
    "SX5E": "^STOXX50E",
    "ES": "ES=F",
    "VIX": "^VIX",
    "XLK": "XLK",
    "XLF": "XLF",
    "XLV": "XLV",
    "XLE": "XLE",
}


@dataclass(frozen=True)
class DataConfig:
    """Serializable description of a market-data extraction."""

    provider: str
    tickers: dict[str, str]
    start: str
    end: str
    price_field: str = "Close"
    forward_fill_limit: int | None = 5

    @classmethod
    def from_yaml(cls, path: str | Path) -> DataConfig:
        """Read a pipeline configuration from YAML."""
        payload = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
        return cls(**payload)


def frame_fingerprint(frame: pd.DataFrame) -> str:
    """Return a stable SHA-256 fingerprint of values, labels, and index."""
    canonical = frame.sort_index().sort_index(axis=1)
    hashed = pd.util.hash_pandas_object(canonical, index=True).to_numpy().tobytes()
    labels = json.dumps([str(column) for column in canonical.columns]).encode()
    return hashlib.sha256(labels + hashed).hexdigest()


def validate_prices(prices: pd.DataFrame, *, forward_fill_limit: int | None = 5) -> pd.DataFrame:
    """Validate a positive price panel and apply bounded forward filling."""
    frame = validate_frame(prices, minimum_columns=2)
    if isinstance(frame.index, pd.DatetimeIndex):
        frame.index = frame.index.tz_localize(None) if frame.index.tz is not None else frame.index
    frame = frame.ffill(limit=forward_fill_limit)
    if (frame.dropna(how="all") <= 0).any().any():
        raise ValueError("price observations must be strictly positive")
    return frame


def read_price_csv(path: str | Path, *, date_column: str = "date") -> pd.DataFrame:
    """Read the documented wide CSV schema: one date column and one column per asset."""
    frame = pd.read_csv(path)
    if date_column not in frame:
        raise ValueError(f"CSV must contain a '{date_column}' column")
    frame[date_column] = pd.to_datetime(frame[date_column], errors="raise")
    return validate_prices(frame.set_index(date_column))


def download_yfinance(config: DataConfig) -> pd.DataFrame:
    """Download public daily closes through the optional yfinance adapter."""
    if config.provider.lower() != "yfinance":
        raise ValueError("download_yfinance requires provider='yfinance'")
    try:
        import yfinance as yf
    except ImportError as error:  # pragma: no cover - exercised by minimal installs
        raise ImportError("Install the data extra: pip install 'marketmind[data]'") from error
    raw = yf.download(
        list(config.tickers.values()),
        start=config.start,
        end=config.end,
        auto_adjust=False,
        progress=False,
        group_by="column",
    )
    field = config.price_field
    if isinstance(raw.columns, pd.MultiIndex):
        if field not in raw.columns.get_level_values(0):
            raise ValueError(f"provider response did not contain field '{field}'")
        prices = raw[field].copy()
    else:
        prices = raw[[field]].copy()
        prices.columns = [next(iter(config.tickers.values()))]
    inverse = {ticker: name for name, ticker in config.tickers.items()}
    prices = prices.rename(columns=inverse).reindex(columns=config.tickers.keys())
    return validate_prices(prices, forward_fill_limit=config.forward_fill_limit)


def write_dataset(
    prices: pd.DataFrame,
    config: DataConfig,
    *,
    output_directory: str | Path,
) -> tuple[Path, Path]:
    """Write canonical CSV data and a machine-readable provenance manifest."""
    output = Path(output_directory)
    output.mkdir(parents=True, exist_ok=True)
    clean = validate_prices(prices, forward_fill_limit=config.forward_fill_limit)
    data_path = output / "prices.csv"
    clean.rename_axis("date").to_csv(data_path, date_format="%Y-%m-%d", float_format="%.17g")
    data_file_sha256 = hashlib.sha256(data_path.read_bytes()).hexdigest()
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "configuration": asdict(config),
        "rows": len(clean),
        "columns": list(clean.columns),
        "first_observation": str(clean.index.min()),
        "last_observation": str(clean.index.max()),
        "sha256": data_file_sha256,
        "frame_fingerprint": frame_fingerprint(clean),
        "missing_observations": {column: int(clean[column].isna().sum()) for column in clean},
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return data_path, manifest_path


def run_data_pipeline(config_path: str | Path, output_directory: str | Path) -> tuple[Path, Path]:
    """Execute the provider named in a YAML config and persist data plus provenance."""
    config = DataConfig.from_yaml(config_path)
    if config.provider.lower() == "yfinance":
        prices = download_yfinance(config)
    else:
        raise ValueError(
            f"unsupported provider '{config.provider}'; licensed Bloomberg/Refinitiv data must be supplied as CSV"
        )
    return write_dataset(prices, config, output_directory=output_directory)
