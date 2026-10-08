"""Command-line interface for reproducible MarketMind runs."""

from __future__ import annotations

import argparse
from pathlib import Path

from marketmind.data import DataConfig, run_data_pipeline, write_dataset
from marketmind.mii import MarketMind, MarketMindConfig
from marketmind.pipeline import run_mii_pipeline, save_mii_result
from marketmind.synthetic import synthetic_market


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="marketmind", description="MarketMind research toolkit")
    parser.add_argument("--version", action="version", version="marketmind 0.1.0")
    commands = parser.add_subparsers(dest="command", required=True)

    demo = commands.add_parser("demo", help="run the full pipeline on deterministic synthetic data")
    demo.add_argument("--output", default="artifacts/demo")
    demo.add_argument("--periods", type=int, default=1500)
    demo.add_argument("--seed", type=int, default=42)
    demo.add_argument("--window", type=int, default=252)
    demo.add_argument("--step", type=int, default=21)

    fetch = commands.add_parser("fetch", help="download and fingerprint public data")
    fetch.add_argument("--config", default="config/paper-public.yml")
    fetch.add_argument("--output", default="data/raw/paper-public")

    run = commands.add_parser("run", help="estimate MII from a wide price CSV")
    run.add_argument("prices")
    run.add_argument("--output", default="artifacts/run")
    run.add_argument("--window", type=int, default=252)
    run.add_argument("--step", type=int, default=21)
    run.add_argument("--development-end")
    run.add_argument("--primary", help="comma-separated primary columns; defaults to paper four when present")
    run.add_argument("--network", help="comma-separated network columns; defaults to all columns")

    commands.add_parser("dashboard", help="launch the interactive Streamlit dashboard")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Execute the command-line interface."""
    args = _parser().parse_args(argv)
    if args.command == "fetch":
        data_path, manifest_path = run_data_pipeline(args.config, args.output)
        print(f"data: {data_path}\nmanifest: {manifest_path}")
        return 0
    if args.command == "dashboard":
        from marketmind.dashboard import launch

        return launch()
    if args.command == "run":
        normalization = "development" if args.development_end else "expanding"
        config = MarketMindConfig(
            window=args.window,
            step=args.step,
            development_end=args.development_end,
            normalization=normalization,
        )
        primary = args.primary.split(",") if args.primary else None
        network = args.network.split(",") if args.network else None
        result = run_mii_pipeline(
            args.prices,
            args.output,
            config=config,
            primary_columns=primary,
            network_columns=network,
        )
        print(f"wrote {len(result.mii)} MII observations to {Path(args.output).resolve()}")
        return 0
    if args.command == "demo":
        prices = synthetic_market(periods=args.periods, seed=args.seed)
        data_directory = Path(args.output) / "data"
        config = DataConfig(
            provider="synthetic",
            tickers={column: column for column in prices.columns},
            start=str(prices.index.min().date()),
            end=str(prices.index.max().date()),
        )
        write_dataset(prices, config, output_directory=data_directory)
        estimator = MarketMind(MarketMindConfig(window=args.window, step=args.step))
        result = estimator.fit_transform(prices)
        output = save_mii_result(result, Path(args.output) / "results")
        print(f"wrote deterministic demo to {output.resolve()}")
        return 0
    return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
